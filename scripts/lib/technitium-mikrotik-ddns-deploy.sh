#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/technitium-mikrotik-ddns-deploy.sh
# Purpose:
#   Deploy the generated MikroTik DHCP DDNS RouterOS script without user prompts.
# Notes:
#   - Uses key-based SSH by default.
#   - If MIKROTIK_SSH_PASSWORD exists in SOPS, sshpass is used non-interactively.
#   - Secrets are never printed.
# ===============================================================================

set -euo pipefail

ROOT_DIR="${ROOT_DIR:?ROOT_DIR is required}"
PASSWORDS_ENCRYPTED_FILE="${PASSWORDS_ENCRYPTED_FILE:?PASSWORDS_ENCRYPTED_FILE is required}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:?SOPS_AGE_KEY_FILE is required}"
ROUTEROS_SCRIPT_FILE="${ROOT_DIR}/state/generated/routeros/technitium-dhcp-ddns.rsc"
MIKROTIK_DEFAULT_HOST="${MIKROTIK_DEFAULT_HOST:-192.168.20.1}"
MIKROTIK_DEFAULT_USER="${MIKROTIK_DEFAULT_USER:-admin}"
MIKROTIK_REMOTE_FILE="${MIKROTIK_REMOTE_FILE:-technitium-dhcp-ddns.rsc}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: $1" >&2
    exit 1
  }
}

extract_dotenv_value() {
  local key="$1"
  awk -F= -v key="$key" '
    $1 == key {
      sub(/^[^=]*=/, "")
      gsub(/^"|"$/, "")
      gsub(/\\"/, "\"")
      gsub(/\\\\/, "\\")
      print
      exit
    }
  ' "$plain_file"
}

require_command sops
require_command awk
require_command scp
require_command ssh

if [[ ! -f "$ROUTEROS_SCRIPT_FILE" ]]; then
  echo "ERROR: Rendered RouterOS script not found: ${ROUTEROS_SCRIPT_FILE}" >&2
  echo 'Run: task technitium:dhcp-sync:render' >&2
  exit 1
fi

plain_file="$(mktemp)"
trap 'rm -f "$plain_file"' EXIT
SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops --decrypt --input-type dotenv --output-type dotenv "$PASSWORDS_ENCRYPTED_FILE" > "$plain_file"
chmod 600 "$plain_file"

mikrotik_host="$(extract_dotenv_value MIKROTIK_HOST || true)"
mikrotik_user="$(extract_dotenv_value MIKROTIK_SSH_USER || true)"
mikrotik_password="$(extract_dotenv_value MIKROTIK_SSH_PASSWORD || true)"

mikrotik_host="${mikrotik_host:-$MIKROTIK_DEFAULT_HOST}"
mikrotik_user="${mikrotik_user:-$MIKROTIK_DEFAULT_USER}"

ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

if [[ -n "$mikrotik_password" ]]; then
  require_command sshpass
  ssh_options=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=15
  )
  sshpass -p "$mikrotik_password" scp "${ssh_options[@]}" "$ROUTEROS_SCRIPT_FILE" "${mikrotik_user}@${mikrotik_host}:${MIKROTIK_REMOTE_FILE}"
  sshpass -p "$mikrotik_password" ssh "${ssh_options[@]}" "${mikrotik_user}@${mikrotik_host}" "/import file-name=${MIKROTIK_REMOTE_FILE}"
else
  scp "${ssh_options[@]}" "$ROUTEROS_SCRIPT_FILE" "${mikrotik_user}@${mikrotik_host}:${MIKROTIK_REMOTE_FILE}"
  ssh "${ssh_options[@]}" "${mikrotik_user}@${mikrotik_host}" "/import file-name=${MIKROTIK_REMOTE_FILE}"
fi

echo "Technitium MikroTik DHCP DDNS script deployed and imported on ${mikrotik_host}."
