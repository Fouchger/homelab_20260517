#!/usr/bin/env bash
# ==============================================================================
# File: services/proxmox_helper_scripts/proxmox-ensure-community-lxc.sh
# Purpose:
#   From the admin server, connect to the Proxmox host and ensure one or more LXC
#   containers exist by running Proxmox community scripts on the Proxmox host.
# Notes:
#   - The repository is expected to run from the admin server.
#   - The actual pct/community-script work is executed on the Proxmox server.
#   - Container definitions are read from config/proxmox-community-lxc.yml.
#   - The YAML parser intentionally supports only the simple repo config shape:
#       script-name.sh:
#         instance-name:
#           var_name: "value"
#   - No root password is stored here. SSH key access is used for the containers.
# ==============================================================================

set -euo pipefail

CONFIG_ENV_FILE="${CONFIG_ENV_FILE:-state/config/.env}"
LXC_CONFIG_FILE="${LXC_CONFIG_FILE:-config/proxmox-community-lxc.yml}"
LXC_SCRIPT_FILTER="${LXC_SCRIPT_FILTER:-${1:-}}"
DEFAULT_SSH_PORT="22"
DEFAULT_SSH_USER="root"
DEFAULT_SSH_KEY_FILE="${HOME}/.ssh/homelab_ed25519"
REMOTE_CONFIG_FILE=""
REMOTE_SCRIPT_FILE=""
REMOTE_AUTHORIZED_KEY_FILE=""
INVENTORY_MANAGER_SCRIPT="${INVENTORY_MANAGER_SCRIPT:-scripts/lib/inventory-manager.py}"
ANSIBLE_INVENTORY_FILE="${ANSIBLE_INVENTORY_FILE:-state/ansible/inventory.yml}"
PASSWORDS_ENCRYPTED_FILE="${PASSWORDS_ENCRYPTED_FILE:-state/secrets/passwords/passwords.enc.env}"
SOPS_AGE_RECIPIENTS_FILE="${SOPS_AGE_RECIPIENTS_FILE:-state/secrets/sops/recipients.txt}"
HOMELAB_LXC_INVENTORY_GROUP="${HOMELAB_LXC_INVENTORY_GROUP:-lxc}"

get_env_value() {
  local env_key="$1"
  if [[ -f "$CONFIG_ENV_FILE" ]]; then
    awk -F= -v key="$env_key" '$1 == key { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit }' "$CONFIG_ENV_FILE"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found on admin server: $1" >&2
    exit 1
  }
}

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "ERROR: Missing required value: ${name}" >&2
    echo "Set ${name} in ${CONFIG_ENV_FILE} or export it before running this task." >&2
    exit 1
  fi
}

cleanup_remote_files() {
  if [[ -n "${remote_target:-}" ]]; then
    if [[ -n "${REMOTE_CONFIG_FILE}" || -n "${REMOTE_SCRIPT_FILE}" || -n "${REMOTE_AUTHORIZED_KEY_FILE}" ]]; then
      ssh "${ssh_options[@]}" "$remote_target" "rm -f '${REMOTE_CONFIG_FILE}' '${REMOTE_SCRIPT_FILE}' '${REMOTE_AUTHORIZED_KEY_FILE}'" >/dev/null 2>&1 || true
    fi
  fi
}

require_command ssh
require_command scp
require_command python3

PROXMOX_SSH_HOST="${PROXMOX_SSH_HOST:-$(get_env_value PROXMOX_SSH_HOST)}"
PROXMOX_SSH_PORT="${PROXMOX_SSH_PORT:-$(get_env_value PROXMOX_SSH_PORT)}"
PROXMOX_SSH_USER="${PROXMOX_SSH_USER:-$(get_env_value PROXMOX_SSH_USER)}"
HOMELAB_SSH_KEY_FILE="${HOMELAB_SSH_KEY_FILE:-$(get_env_value HOMELAB_SSH_KEY_FILE)}"

PROXMOX_SSH_PORT="${PROXMOX_SSH_PORT:-$DEFAULT_SSH_PORT}"
PROXMOX_SSH_USER="${PROXMOX_SSH_USER:-$DEFAULT_SSH_USER}"
HOMELAB_SSH_KEY_FILE="${HOMELAB_SSH_KEY_FILE:-$DEFAULT_SSH_KEY_FILE}"

require_value PROXMOX_SSH_HOST "$PROXMOX_SSH_HOST"

if [[ ! -f "$HOMELAB_SSH_KEY_FILE" ]]; then
  echo "ERROR: Admin-server SSH key was not found: ${HOMELAB_SSH_KEY_FILE}" >&2
  echo "Run: task ssh:key:ensure" >&2
  exit 1
fi

if [[ ! -f "${HOMELAB_SSH_KEY_FILE}.pub" ]]; then
  echo "ERROR: Admin-server SSH public key was not found: ${HOMELAB_SSH_KEY_FILE}.pub" >&2
  echo "Run: task ssh:key:ensure" >&2
  exit 1
fi

if [[ ! -f "$LXC_CONFIG_FILE" ]]; then
  echo "ERROR: LXC config file was not found: ${LXC_CONFIG_FILE}" >&2
  exit 1
fi

ssh_options=(
  -p "$PROXMOX_SSH_PORT"
  -i "$HOMELAB_SSH_KEY_FILE"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
)

scp_options=(
  -P "$PROXMOX_SSH_PORT"
  -i "$HOMELAB_SSH_KEY_FILE"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
)

remote_target="${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}"
REMOTE_CONFIG_FILE="/tmp/homelab-proxmox-community-lxc-$RANDOM-$$.yml"
REMOTE_SCRIPT_FILE="/tmp/homelab-proxmox-community-lxc-$RANDOM-$$.sh"
REMOTE_AUTHORIZED_KEY_FILE="/tmp/homelab-proxmox-community-lxc-$RANDOM-$$.pub"
local_remote_script="$(mktemp)"
trap 'rm -f "$local_remote_script"; cleanup_remote_files' EXIT

cat >"$local_remote_script" <<'REMOTE_SCRIPT'
set -euo pipefail
export TERM="${TERM:-xterm}"

COMMUNITY_SCRIPT_BASE_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct"
LXC_CONFIG_FILE="${LXC_CONFIG_FILE:?LXC_CONFIG_FILE is required}"
LXC_SCRIPT_FILTER="${LXC_SCRIPT_FILTER:-}"
HOMELAB_LXC_AUTHORIZED_KEY_FILE="${HOMELAB_LXC_AUTHORIZED_KEY_FILE:-}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found on Proxmox host: $1" >&2
    exit 1
  }
}

find_lxc_authorized_key() {
  local candidate key_line
  local candidates=()

  if [[ -n "$HOMELAB_LXC_AUTHORIZED_KEY_FILE" ]]; then
    candidates+=("$HOMELAB_LXC_AUTHORIZED_KEY_FILE")
  fi

  shopt -s nullglob
  candidates+=(
    /root/.ssh/homelab_ed25519.pub
    /root/.ssh/id_ed25519.pub
    /root/.ssh/id_rsa.pub
    /root/.ssh/*.pub
    /root/.ssh/authorized_keys
  )
  shopt -u nullglob

  for candidate in "${candidates[@]}"; do
    [[ -r "$candidate" ]] || continue
    key_line="$(awk '/^(ssh-rsa|ssh-ed25519|ecdsa-sha2-)/ { print; exit }' "$candidate")"
    if [[ -n "$key_line" ]]; then
      printf '%s' "$key_line"
      return 0
    fi
  done

  echo "ERROR: No usable SSH public key found for LXC root access." >&2
  echo "Expected the admin-server public key to be copied to the Proxmox host first." >&2
  return 1
}

ensure_lxc_authorized_key() {
  local ctid="$1"
  local hostname="$2"
  local key_line

  [[ -n "$ctid" ]] || return 0
  key_line="$(find_lxc_authorized_key)"

  if pct exec "$ctid" -- grep -qxF "$key_line" /root/.ssh/authorized_keys >/dev/null 2>&1; then
    echo "INFO: SSH public key already present in CT ${ctid} (${hostname})."
    return 0
  fi

  echo "INFO: Installing SSH public key in CT ${ctid} (${hostname})."
  pct exec "$ctid" -- mkdir -p /root/.ssh
  pct exec "$ctid" -- chmod 700 /root/.ssh
  printf '%s
' "$key_line" | pct exec "$ctid" -- sh -c 'cat >> /root/.ssh/authorized_keys'
  pct exec "$ctid" -- chmod 600 /root/.ssh/authorized_keys
}

ct_exists() {
  local ctid="$1"
  pct status "$ctid" >/dev/null 2>&1 && return 0

  if command -v pvesh >/dev/null 2>&1; then
    pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | grep -Eq '"vmid"[[:space:]]*:[[:space:]]*'"$ctid"'([^0-9]|$)' && return 0
  fi

  [[ -f "/etc/pve/lxc/${ctid}.conf" || -f "/etc/pve/qemu-server/${ctid}.conf" ]]
}

strip_cidr() {
  local value="$1"
  printf '%s' "${value%%/*}"
}

normalise_inventory_group() {
  local script_name="$1"
  script_name="${script_name%.sh}"
  script_name="${script_name//[^A-Za-z0-9_.-]/_}"
  printf '%s' "${script_name:-lxc}"
}

collect_lxc_manifest() {
  local script_name="$1"
  local instance_name="$2"
  local -n instance_vars_ref="$3"
  local ctid="${instance_vars_ref[var_ctid]:-}"
  local hostname="${instance_vars_ref[var_hostname]:-$instance_name}"
  local ansible_host="${instance_vars_ref[var_net]:-}"
  local mac_address="${instance_vars_ref[var_mac]:-}"
  local group_name

  group_name="$(normalise_inventory_group "$script_name")"
  ansible_host="$(strip_cidr "$ansible_host")"

  if [[ -z "$ansible_host" && -n "$ctid" ]]; then
    ansible_host="$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  if [[ -z "$ansible_host" ]]; then
    echo "WARNING: Unable to determine IP address for CT ${ctid} (${hostname}); inventory was not emitted for this container." >&2
    return 0
  fi

  printf 'HOMELAB_LXC_INVENTORY\t%s\t%s\t%s\t%s\t%s\t%s\n' "$group_name" "$hostname" "$ansible_host" "root" "$ctid" "$mac_address"
}

parse_lxc_config() {
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[A-Za-z0-9_.-]+:[[:space:]]*$/ {
      script=$1
      sub(/:$/, "", script)
      instance=""
      next
    }
    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      instance=$1
      sub(/:$/, "", instance)
      next
    }
    /^    var_[A-Za-z0-9_]+:[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      key=line
      sub(/:.*/, "", key)
      value=line
      sub(/^[^:]*:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/^'"'"'|'"'"'$/, "", value)
      if (script != "" && instance != "") {
        print script "\t" instance "\t" key "\t" value
      }
      next
    }
  ' "$LXC_CONFIG_FILE"
}

run_instance() {
  local script_name="$1"
  local instance_name="$2"
  local -n instance_vars_ref="$3"
  local ctid="${instance_vars_ref[var_ctid]:-}"
  local hostname="${instance_vars_ref[var_hostname]:-$instance_name}"
  local script_url="${COMMUNITY_SCRIPT_BASE_URL}/${script_name}"
  local env_cmd=(env "TERM=${TERM:-xterm}")
  local key value

  if [[ -z "$ctid" ]]; then
    echo "ERROR: ${script_name}/${instance_name} is missing var_ctid." >&2
    exit 1
  fi

  if ct_exists "$ctid"; then
    echo "INFO: CT ${ctid} (${hostname}) already exists. Skipping ${script_name}/${instance_name}."
    return 0
  fi

  echo "INFO: Creating CT ${ctid} (${hostname}) using ${script_name}."

  env_cmd+=("mode=generated")
  for key in "${!instance_vars_ref[@]}"; do
    value="${instance_vars_ref[$key]}"
    if [[ "$key" == "var_ssh_authorized_key" && "$value" == "auto" ]]; then
      value="$(find_lxc_authorized_key)"
    fi
    env_cmd+=("${key}=${value}")
  done

  "${env_cmd[@]}" bash -c "$(curl -fsSL "$script_url")"

  if ! ct_exists "$ctid"; then
    echo "ERROR: CT ${ctid} was not found after ${script_name}/${instance_name} completed." >&2
    exit 1
  fi

  echo "OK: CT ${ctid} (${hostname}) is present."
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: This remote script must run as root on the Proxmox host." >&2
  exit 1
fi

require_command awk
require_command bash
require_command curl
require_command pct

if [[ ! -f "$LXC_CONFIG_FILE" ]]; then
  echo "ERROR: Remote LXC config file was not found: ${LXC_CONFIG_FILE}" >&2
  exit 1
fi

declare -A current_vars=()
current_key=""
created_ctids=()

while IFS=$'\t' read -r script_name instance_name var_key var_value; do
  if [[ -n "$LXC_SCRIPT_FILTER" && "$script_name" != "$LXC_SCRIPT_FILTER" ]]; then
    continue
  fi

  next_key="${script_name}/${instance_name}"
  if [[ -n "$current_key" && "$next_key" != "$current_key" ]]; then
    run_instance "${current_key%%/*}" "${current_key#*/}" current_vars
    ensure_lxc_authorized_key "${current_vars[var_ctid]:-}" "${current_vars[var_hostname]:-${current_key#*/}}"
    collect_lxc_manifest "${current_key%%/*}" "${current_key#*/}" current_vars
    created_ctids+=("${current_vars[var_ctid]:-}")
    current_vars=()
  fi

  current_key="$next_key"
  current_vars["$var_key"]="$var_value"
done < <(parse_lxc_config)

if [[ -n "$current_key" ]]; then
  run_instance "${current_key%%/*}" "${current_key#*/}" current_vars
  ensure_lxc_authorized_key "${current_vars[var_ctid]:-}" "${current_vars[var_hostname]:-${current_key#*/}}"
  collect_lxc_manifest "${current_key%%/*}" "${current_key#*/}" current_vars
  created_ctids+=("${current_vars[var_ctid]:-}")
fi

if [[ ${#created_ctids[@]} -eq 0 ]]; then
  if [[ -n "$LXC_SCRIPT_FILTER" ]]; then
    echo "ERROR: No matching LXC definitions found for script: ${LXC_SCRIPT_FILTER}" >&2
    exit 1
  fi
  echo "ERROR: No LXC definitions found in ${LXC_CONFIG_FILE}" >&2
  exit 1
fi

printf '\nCurrent matching CTs:\n'
pct list | awk -v ids=" ${created_ctids[*]} " 'NR == 1 || index(ids, " " $1 " ") > 0'
REMOTE_SCRIPT

sync_lxc_inventory() {
  local output_file="$1"
  local changed=0
  local group hostname ansible_host ssh_user ctid mac_address

  if [[ ! -f "$INVENTORY_MANAGER_SCRIPT" ]]; then
    echo "WARNING: Inventory manager script was not found: ${INVENTORY_MANAGER_SCRIPT}" >&2
    echo "         LXC containers were ensured, but inventory was not updated." >&2
    return 0
  fi

  mkdir -p "$(dirname "$ANSIBLE_INVENTORY_FILE")"

  while IFS=$'\t' read -r marker group hostname ansible_host ssh_user ctid mac_address; do
    [[ "$marker" == "HOMELAB_LXC_INVENTORY" ]] || continue
    group="${group:-lxc}"
    ssh_user="${ssh_user:-root}"

    echo "Updating Ansible inventory for ${hostname} (${ansible_host})..."
    ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "$ansible_host" >/dev/null 2>&1 || true
    python3 -S "$INVENTORY_MANAGER_SCRIPT" add-server \
      --inventory-file "$ANSIBLE_INVENTORY_FILE" \
      --password-file "$PASSWORDS_ENCRYPTED_FILE" \
      --recipients-file "$SOPS_AGE_RECIPIENTS_FILE" \
      --group "$group" \
      --hostname "$hostname" \
      --ansible-host "$ansible_host" \
      --ssh-user "$ssh_user" \
      --vm-lxc-id "$ctid" \
      --mac-address "$mac_address" \
      --ssh-port "22" \
      --python-interpreter "auto_silent" \
      --no-password-var
    changed=$((changed + 1))
  done < <(tr -d '\r' < "$output_file" | grep '^HOMELAB_LXC_INVENTORY' || true)

  if [[ "$changed" -eq 0 ]]; then
    echo "WARNING: No LXC inventory manifest lines were returned by the Proxmox run." >&2
    echo "         LXC containers were ensured, but inventory was not updated." >&2
    return 0
  fi

  echo "Updated Ansible inventory for ${changed} LXC container(s): ${ANSIBLE_INVENTORY_FILE}"
}

chmod 700 "$local_remote_script"

echo "Copying LXC config to ${remote_target}..."
scp "${scp_options[@]}" "$LXC_CONFIG_FILE" "${remote_target}:${REMOTE_CONFIG_FILE}" >/dev/null
scp "${scp_options[@]}" "$local_remote_script" "${remote_target}:${REMOTE_SCRIPT_FILE}" >/dev/null
scp "${scp_options[@]}" "${HOMELAB_SSH_KEY_FILE}.pub" "${remote_target}:${REMOTE_AUTHORIZED_KEY_FILE}" >/dev/null

echo "Ensuring Proxmox community-script LXC containers on ${remote_target}..."

local_ssh_output="$(mktemp)"
trap 'rm -f "$local_remote_script" "$local_ssh_output"; cleanup_remote_files' EXIT

ssh -tt "${ssh_options[@]}" "$remote_target" \
  "export TERM=\"${TERM:-xterm}\"; LXC_CONFIG_FILE='${REMOTE_CONFIG_FILE}' LXC_SCRIPT_FILTER='${LXC_SCRIPT_FILTER}' HOMELAB_LXC_AUTHORIZED_KEY_FILE='${REMOTE_AUTHORIZED_KEY_FILE}' bash '${REMOTE_SCRIPT_FILE}'" | tee "$local_ssh_output"

sync_lxc_inventory "$local_ssh_output"
