#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/proxmox-ensure-community-lxc.sh
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

cleanup_remote_config() {
  if [[ -n "${REMOTE_CONFIG_FILE}" && -n "${remote_target:-}" ]]; then
    ssh "${ssh_options[@]}" "$remote_target" "rm -f '${REMOTE_CONFIG_FILE}'" >/dev/null 2>&1 || true
  fi
}

require_command ssh
require_command scp

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

remote_target="${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}"
REMOTE_CONFIG_FILE="/tmp/homelab-proxmox-community-lxc-$RANDOM-$$.yml"
trap cleanup_remote_config EXIT

echo "Copying LXC config to ${remote_target}..."
scp "${ssh_options[@]}" "$LXC_CONFIG_FILE" "${remote_target}:${REMOTE_CONFIG_FILE}" >/dev/null

echo "Ensuring Proxmox community-script LXC containers on ${remote_target}..."

ssh "${ssh_options[@]}" "$remote_target" \
  "LXC_CONFIG_FILE='${REMOTE_CONFIG_FILE}' LXC_SCRIPT_FILTER='${LXC_SCRIPT_FILTER}' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

COMMUNITY_SCRIPT_BASE_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct"
LXC_CONFIG_FILE="${LXC_CONFIG_FILE:?LXC_CONFIG_FILE is required}"
LXC_SCRIPT_FILTER="${LXC_SCRIPT_FILTER:-}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found on Proxmox host: $1" >&2
    exit 1
  }
}

find_lxc_authorized_key() {
  local candidate key_line
  shopt -s nullglob
  local candidates=(
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

  echo "ERROR: No usable SSH public key found in /root/.ssh on the Proxmox host." >&2
  echo "Create or copy a public key there first, for example /root/.ssh/id_ed25519.pub." >&2
  return 1
}

ct_exists() {
  local ctid="$1"
  pct status "$ctid" >/dev/null 2>&1 && return 0

  if command -v pvesh >/dev/null 2>&1; then
    pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | grep -Eq '"vmid"[[:space:]]*:[[:space:]]*'"$ctid"'([^0-9]|$)' && return 0
  fi

  [[ -f "/etc/pve/lxc/${ctid}.conf" || -f "/etc/pve/qemu-server/${ctid}.conf" ]]
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
  local env_cmd=(env)
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
    created_ctids+=("${current_vars[var_ctid]:-}")
    current_vars=()
  fi

  current_key="$next_key"
  current_vars["$var_key"]="$var_value"
done < <(parse_lxc_config)

if [[ -n "$current_key" ]]; then
  run_instance "${current_key%%/*}" "${current_key#*/}" current_vars
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
