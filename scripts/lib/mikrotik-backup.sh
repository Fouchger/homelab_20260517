#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/mikrotik-backup.sh
# Purpose:
#   Create sensitive RouterOS 7 backups for MikroTik inventory hosts and store
#   them under the homelab state backup directory.
# Notes:
#   - Uses key-based SSH for the steady-state automation user.
#   - Creates both a sensitive text export and an encrypted binary backup.
#   - The binary backup password is read from MIKROTIK_BACKUP_PASSWORD in SOPS.
# ==============================================================================
set -euo pipefail

usage() {
  cat <<'EOUSAGE'
Usage: mikrotik-backup.sh --inventory-file FILE --password-file FILE --age-key-file FILE --recipients-file FILE --inventory-manager FILE --ssh-key-file FILE --backup-dir DIR [--group mikrotik] [--backup-password-var MIKROTIK_BACKUP_PASSWORD]
EOUSAGE
}

inventory_file=""
password_file=""
age_key_file=""
recipients_file=""
inventory_manager=""
ssh_key_file=""
backup_dir=""
group="mikrotik"
backup_password_var="MIKROTIK_BACKUP_PASSWORD"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory-file) inventory_file="$2"; shift 2 ;;
    --password-file) password_file="$2"; shift 2 ;;
    --age-key-file) age_key_file="$2"; shift 2 ;;
    --recipients-file) recipients_file="$2"; shift 2 ;;
    --inventory-manager) inventory_manager="$2"; shift 2 ;;
    --ssh-key-file) ssh_key_file="$2"; shift 2 ;;
    --backup-dir) backup_dir="$2"; shift 2 ;;
    --group) group="$2"; shift 2 ;;
    --backup-password-var) backup_password_var="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$inventory_file" ]] || { echo "ERROR: --inventory-file is required" >&2; exit 1; }
[[ -n "$password_file" ]] || { echo "ERROR: --password-file is required" >&2; exit 1; }
[[ -n "$age_key_file" ]] || { echo "ERROR: --age-key-file is required" >&2; exit 1; }
[[ -n "$recipients_file" ]] || { echo "ERROR: --recipients-file is required" >&2; exit 1; }
[[ -n "$inventory_manager" ]] || { echo "ERROR: --inventory-manager is required" >&2; exit 1; }
[[ -n "$ssh_key_file" ]] || { echo "ERROR: --ssh-key-file is required" >&2; exit 1; }
[[ -n "$backup_dir" ]] || { echo "ERROR: --backup-dir is required" >&2; exit 1; }

[[ -f "$inventory_file" ]] || { echo "ERROR: Missing inventory file: $inventory_file" >&2; exit 1; }
[[ -f "$inventory_manager" ]] || { echo "ERROR: Missing inventory manager: $inventory_manager" >&2; exit 1; }
[[ -f "$ssh_key_file" ]] || { echo "ERROR: Missing SSH key file: $ssh_key_file" >&2; exit 1; }
[[ -f "${ssh_key_file}.pub" ]] || { echo "ERROR: Missing SSH public key file: ${ssh_key_file}.pub" >&2; exit 1; }

command -v ssh >/dev/null 2>&1 || { echo "ERROR: ssh is required" >&2; exit 1; }
command -v scp >/dev/null 2>&1 || { echo "ERROR: scp is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum is required" >&2; exit 1; }
command -v date >/dev/null 2>&1 || { echo "ERROR: date is required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${script_dir}/secrets-dotenv.sh"
export PASSWORDS_ENCRYPTED_FILE="$password_file"
export SOPS_AGE_KEY_FILE="$age_key_file"
export SOPS_AGE_RECIPIENTS_FILE="$recipients_file"

password_runtime_file="$(mktemp)"
cleanup() {
  rm -f "$password_runtime_file"
}
trap cleanup EXIT
secrets_dotenv_decrypt_to_file "$password_runtime_file"

read_password_value() {
  local key="$1"
  [[ -n "$key" ]] || return 0
  secrets_dotenv_read_value_from_file "$password_runtime_file" "$key" || true
}

generate_backup_password() {
  openssl rand -base64 36 | tr -d '\n'
}
save_password_value() {
  local key="$1"
  local value="$2"
  [[ -n "$key" && -n "$value" ]] || return 1
  secrets_dotenv_upsert_file "$password_runtime_file" "$key" "$value"
  secrets_dotenv_encrypt_from_file "$password_runtime_file"
}

routeros_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

safe_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_.-]+/-/g; s/^-+//; s/-+$//'
}

backup_password="$(read_password_value "$backup_password_var")"
if [[ -z "$backup_password" ]]; then
  echo "No saved MikroTik backup password found for ${backup_password_var}. Generating and saving one in SOPS."
  backup_password="$(generate_backup_password)"
  save_password_value "$backup_password_var" "$backup_password"
  echo "Saved generated MikroTik backup password to SOPS variable ${backup_password_var}."
fi

if [[ -z "$backup_password" ]]; then
  echo "ERROR: ${backup_password_var} is required for encrypted RouterOS binary backups." >&2
  exit 1
fi

run_timestamp="$(date +%Y%m%d-%H%M%S)"
run_dir="${backup_dir}/${run_timestamp}"
mkdir -p "$run_dir"
chmod 700 "$backup_dir" "$run_dir" 2>/dev/null || true

failures=0
checked=0
completed=0

while IFS='|' read -r name host_group host user connection port keyfile password_var; do
  [[ -n "$name" ]] || continue
  [[ "$host_group" == "$group" ]] || continue
  [[ "$connection" != "local" ]] || continue
  checked=$((checked + 1))

  if [[ -z "$host" || -z "$user" ]]; then
    echo "ERROR: ${name}: inventory host and SSH user are required." >&2
    failures=$((failures + 1))
    continue
  fi
  if [[ -z "$port" || "$port" == "None" ]]; then
    port="22"
  fi

  target="${user}@${host}"
  router_slug="$(safe_name "$name")"
  backup_name="${router_slug}-sensitive-${run_timestamp}"
  export_remote="${backup_name}.rsc"
  binary_remote="${backup_name}.backup"
  router_dir="${run_dir}/${router_slug}"
  mkdir -p "$router_dir"
  chmod 700 "$router_dir" 2>/dev/null || true

  backup_name_q="$(routeros_quote "$backup_name")"
  backup_password_q="$(routeros_quote "$backup_password")"

  echo "${name}: creating sensitive RouterOS text export and encrypted binary backup."
  if ! ssh -n -i "$ssh_key_file" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$target" \
      "/export show-sensitive file=${backup_name_q}; /system backup save name=${backup_name_q} password=${backup_password_q}" >/dev/null; then
    echo "ERROR: ${name}: RouterOS backup commands failed for ${target}." >&2
    failures=$((failures + 1))
    continue
  fi

  echo "${name}: downloading backup artefacts."
  if ! scp -P "$port" -i "$ssh_key_file" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      "${target}:${export_remote}" "${router_dir}/${export_remote}" >/dev/null; then
    echo "ERROR: ${name}: failed to download ${export_remote}." >&2
    failures=$((failures + 1))
    continue
  fi

  if ! scp -P "$port" -i "$ssh_key_file" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      "${target}:${binary_remote}" "${router_dir}/${binary_remote}" >/dev/null; then
    echo "ERROR: ${name}: failed to download ${binary_remote}." >&2
    failures=$((failures + 1))
    continue
  fi

  ssh -n -i "$ssh_key_file" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$target" \
    "/file remove [find where name=$(routeros_quote "$export_remote")]; /file remove [find where name=$(routeros_quote "$binary_remote")]" >/dev/null 2>&1 || true

  (
    cd "$router_dir"
    sha256sum "$export_remote" "$binary_remote" > SHA256SUMS
  )

  cat > "${router_dir}/README.txt" <<EOFREADME
MikroTik sensitive backup
Created: $(date --iso-8601=seconds)
Router: ${host}
Connection: ${user}@${host}
Files:
- ${export_remote}: text export with sensitive values
- ${binary_remote}: RouterOS binary backup encrypted with ${backup_password_var} from SOPS
- SHA256SUMS: integrity checksums
EOFREADME

  chmod 600 "${router_dir}/${export_remote}" "${router_dir}/${binary_remote}" "${router_dir}/SHA256SUMS" "${router_dir}/README.txt" 2>/dev/null || true
  echo "${name}: backup saved to ${router_dir}."
  completed=$((completed + 1))
done < <(python3 -S "$inventory_manager" list-ssh-hosts --inventory-file "$inventory_file")

if (( checked == 0 )); then
  echo "No MikroTik routers found in inventory group ${group}."
  exit 0
fi

if (( failures > 0 )); then
  echo "ERROR: MikroTik backup failed for ${failures} router(s)." >&2
  exit 1
fi

echo "MikroTik backup completed for ${completed} router(s)."
echo "Backup root: ${run_dir}"
