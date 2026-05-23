#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/mikrotik-bootstrap.sh
# Purpose:
#   Bootstrap a RouterOS automation user using SSH, install the homelab public key,
#   test key-only SSH access, and switch inventory to the automation user.
# Notes:
#   - Uses the same homelab SSH key as other SSH automation tasks.
#   - Uses the initial RouterOS SSH user/password only for bootstrap.
#   - RouterOS stores SSH keys under /user ssh-keys rather than ~/.ssh/authorized_keys.
#   - RouterOS 7 key bootstrap uses SCP to upload the public key, then imports it.
# ==============================================================================
set -euo pipefail

usage() {
  cat <<'EOUSAGE'
Usage: mikrotik-bootstrap.sh --inventory-file FILE --password-file FILE --age-key-file FILE --recipients-file FILE --inventory-manager FILE --ssh-key-file FILE [--group mikrotik] [--automation-user homelab]
EOUSAGE
}

inventory_file=""
password_file=""
age_key_file=""
recipients_file=""
inventory_manager=""
ssh_key_file=""
group="mikrotik"
automation_user="homelab"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory-file) inventory_file="$2"; shift 2 ;;
    --password-file) password_file="$2"; shift 2 ;;
    --age-key-file) age_key_file="$2"; shift 2 ;;
    --recipients-file) recipients_file="$2"; shift 2 ;;
    --inventory-manager) inventory_manager="$2"; shift 2 ;;
    --ssh-key-file) ssh_key_file="$2"; shift 2 ;;
    --group) group="$2"; shift 2 ;;
    --automation-user) automation_user="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -f "$inventory_file" ]] || { echo "ERROR: Missing inventory file: $inventory_file" >&2; exit 1; }
[[ -f "$inventory_manager" ]] || { echo "ERROR: Missing inventory manager: $inventory_manager" >&2; exit 1; }
[[ -f "$recipients_file" ]] || { echo "ERROR: Missing SOPS recipients file: $recipients_file. Run: task passwords:setup" >&2; exit 1; }
[[ -f "$ssh_key_file" && -f "${ssh_key_file}.pub" ]] || { echo "ERROR: Missing SSH key or public key. Run: task ssh:key:ensure" >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "ERROR: ssh is required." >&2; exit 1; }
command -v scp >/dev/null 2>&1 || { echo "ERROR: scp is required." >&2; exit 1; }
command -v sshpass >/dev/null 2>&1 || { echo "ERROR: sshpass is required. Run: task ssh:install" >&2; exit 1; }

password_runtime_file=""
cleanup() {
  if [[ -n "$password_runtime_file" && -f "$password_runtime_file" ]]; then
    rm -f "$password_runtime_file"
  fi
}
trap cleanup EXIT

if [[ -f "$password_file" && -f "$age_key_file" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/scripts/lib/secrets-dotenv.sh"
  export PASSWORDS_ENCRYPTED_FILE="$password_file"
  export SOPS_AGE_KEY_FILE="$age_key_file"
  export SOPS_AGE_RECIPIENTS_FILE="$recipients_file"
  password_runtime_file="$(mktemp)"
  secrets_dotenv_decrypt_to_file "$password_runtime_file" 2>/dev/null || true
fi

read_password_value() {
  local key="$1"
  [[ -n "$key" ]] || return 0
  [[ -n "$password_runtime_file" && -f "$password_runtime_file" ]] || return 0
  secrets_dotenv_read_value_from_file "$password_runtime_file" "$key" || true
}

prompt_secret_from_tty() {
  local label="$1"
  local value=""
  if [[ ! -r /dev/tty ]]; then
    return 1
  fi
  printf '%s: ' "$label" > /dev/tty
  stty -echo < /dev/tty || true
  IFS= read -r value < /dev/tty || true
  stty echo < /dev/tty || true
  printf '\n' > /dev/tty
  printf '%s' "$value"
}
save_password_value() {
  local key="$1"
  local value="$2"
  [[ -n "$key" && -n "$value" ]] || return 1
  [[ -n "$password_runtime_file" ]] || password_runtime_file="$(mktemp)"
  if [[ ! -f "$password_runtime_file" ]]; then
    : > "$password_runtime_file"
    chmod 600 "$password_runtime_file"
  fi
  secrets_dotenv_upsert_file "$password_runtime_file" "$key" "$value"
  secrets_dotenv_encrypt_from_file "$password_runtime_file"
}

routeros_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

automation_user_q="$(routeros_quote "$automation_user")"
comment_q="$(routeros_quote "homelab automation user")"
random_password="$(LC_ALL=C tr -dc 'A-Za-z0-9_=-' </dev/urandom | head -c 32 || true)"
random_password="${random_password:-homelab-temporary-password}"
random_password_q="$(routeros_quote "$random_password")"

failures=0
changed=0

while IFS='|' read -r name host_group host user connection port keyfile password_var; do
  [[ -n "$name" ]] || continue
  [[ "$host_group" == "$group" ]] || continue

  if [[ "$connection" == "local" ]]; then
    echo "${name}: skipped local connection."
    continue
  fi

  if [[ -z "$host" || -z "$user" ]]; then
    echo "ERROR: ${name}: inventory host and SSH user are required." >&2
    failures=$((failures + 1))
    continue
  fi

  automation_target="${automation_user}@${host}"

  if ssh -n -i "$ssh_key_file" -p "$port" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$automation_target" '/system identity print' >/dev/null 2>&1; then
    echo "${name}: key-based SSH already works for ${automation_target}."
    python3 -S "$inventory_manager" add-server \
      --inventory-file "$inventory_file" \
      --password-file "$password_file" \
      --recipients-file "$recipients_file" \
      --age-key-file "$age_key_file" \
      --group "$group" \
      --hostname "$name" \
      --ansible-host "$host" \
      --ssh-user "$automation_user" \
      --no-password-var \
      --device-type mikrotik \
      --automation-user "$automation_user" \
      --python-interpreter auto_silent \
      --ssh-port "$port" >/dev/null
    changed=$((changed + 1))
    continue
  fi

  password_value="$(read_password_value "$password_var")"
  if [[ -z "$password_value" ]]; then
    if [[ -n "$password_var" ]]; then
      echo "${name}: no saved bootstrap password found for ${password_var}."
      password_value="$(prompt_secret_from_tty "Bootstrap SSH password for ${user}@${host}")" || true
      if [[ -n "$password_value" ]]; then
        save_password_value "$password_var" "$password_value"
        echo "${name}: saved bootstrap password to SOPS variable ${password_var}."
      fi
    fi
  fi

  if [[ -z "$password_value" ]]; then
    echo "ERROR: ${name}: no bootstrap password available for variable ${password_var}. Run task mikrotik:inventory:add and save the password, or edit SOPS secrets." >&2
    failures=$((failures + 1))
    continue
  fi

  bootstrap_target="${user}@${host}"
  remote_key_file="homelab-${automation_user}.pub"
  remote_key_file_q="$(routeros_quote "$remote_key_file")"
  routeros_command=":if ([:len [/user find where name=${automation_user_q}]] = 0) do={/user add name=${automation_user_q} group=full password=${random_password_q} disabled=no comment=${comment_q}} else={/user set [find where name=${automation_user_q}] group=full disabled=no comment=${comment_q}}; /user ssh-keys remove [find where user=${automation_user_q}]; /user ssh-keys import user=${automation_user_q} public-key-file=${remote_key_file_q}; /file remove [find where name=${remote_key_file_q}]"

  echo "${name}: uploading homelab public SSH key to RouterOS 7."
  if ! SSHPASS="$password_value" sshpass -e scp \
      -P "$port" \
      -o StrictHostKeyChecking=accept-new \
      -o NumberOfPasswordPrompts=1 \
      "${ssh_key_file}.pub" \
      "${bootstrap_target}:${remote_key_file}" >/dev/null; then
    echo "ERROR: ${name}: failed to copy SSH public key to ${bootstrap_target}." >&2
    failures=$((failures + 1))
    continue
  fi

  echo "${name}: creating/updating RouterOS automation user ${automation_user} and importing SSH key."
  if ! SSHPASS="$password_value" sshpass -e ssh \
      -n \
      -p "$port" \
      -o StrictHostKeyChecking=accept-new \
      -o NumberOfPasswordPrompts=1 \
      "$bootstrap_target" \
      "$routeros_command" >/dev/null; then
    echo "ERROR: ${name}: failed to bootstrap ${automation_user} through ${bootstrap_target}." >&2
    SSHPASS="$password_value" sshpass -e ssh -n -p "$port" -o StrictHostKeyChecking=accept-new -o NumberOfPasswordPrompts=1 "$bootstrap_target" "/file remove [find where name=${remote_key_file_q}]" >/dev/null 2>&1 || true
    failures=$((failures + 1))
    continue
  fi

  echo "${name}: testing key-based SSH as ${automation_user}."
  if ! ssh -n -i "$ssh_key_file" -p "$port" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$automation_target" '/system identity print' >/dev/null; then
    echo "ERROR: ${name}: key-based SSH test failed for ${automation_target}." >&2
    failures=$((failures + 1))
    continue
  fi

  python3 -S "$inventory_manager" add-server \
    --inventory-file "$inventory_file" \
    --password-file "$password_file" \
    --recipients-file "$recipients_file" \
    --age-key-file "$age_key_file" \
    --group "$group" \
    --hostname "$name" \
    --ansible-host "$host" \
    --ssh-user "$automation_user" \
    --no-password-var \
    --device-type mikrotik \
    --automation-user "$automation_user" \
    --python-interpreter auto_silent \
    --ssh-port "$port" >/dev/null

  echo "${name}: inventory switched to ${automation_user} with key-based SSH."
  changed=$((changed + 1))
done < <(python3 -S "$inventory_manager" list-ssh-hosts --inventory-file "$inventory_file")

if (( failures > 0 )); then
  echo "ERROR: MikroTik bootstrap failed for ${failures} router(s)." >&2
  exit 1
fi

if (( changed == 0 )); then
  echo "No MikroTik routers found in inventory group ${group}."
else
  echo "MikroTik bootstrap completed for ${changed} router(s)."
fi
