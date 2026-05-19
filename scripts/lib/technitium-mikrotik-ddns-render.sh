#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/technitium-mikrotik-ddns-render.sh
# Purpose:
#   Render the MikroTik DHCP-to-Technitium DDNS RouterOS script from encrypted
#   SOPS secrets without writing secrets into tracked repository files.
# Notes:
#   - Generated output contains a Technitium API token and must remain under state/.
#   - The token should belong to a dedicated low-privilege Technitium user.
# ===============================================================================

set -euo pipefail

ROOT_DIR="${ROOT_DIR:?ROOT_DIR is required}"
PASSWORDS_ENCRYPTED_FILE="${PASSWORDS_ENCRYPTED_FILE:?PASSWORDS_ENCRYPTED_FILE is required}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
TEMPLATE_FILE="${ROOT_DIR}/scripts/templates/routeros/technitium-dhcp-ddns.rsc.template"
OUTPUT_DIR="${ROOT_DIR}/state/generated/routeros"
OUTPUT_FILE="${OUTPUT_DIR}/technitium-dhcp-ddns.rsc"

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

escape_sed_replacement() {
  sed -e 's/[\\&]/\\&/g'
}

require_command sops
require_command awk
require_command sed

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "ERROR: Missing RouterOS template: ${TEMPLATE_FILE}" >&2
  exit 1
fi

if [[ ! -f "$PASSWORDS_ENCRYPTED_FILE" ]]; then
  echo "ERROR: Missing encrypted password file: ${PASSWORDS_ENCRYPTED_FILE}" >&2
  echo "Run: task passwords:setup" >&2
  exit 1
fi

plain_file="$(mktemp)"
trap 'rm -f "$plain_file"' EXIT

SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops --decrypt --input-type dotenv --output-type dotenv "$PASSWORDS_ENCRYPTED_FILE" > "$plain_file"
chmod 600 "$plain_file"

sync_token="$(extract_dotenv_value TECHNITIUM_DHCP_SYNC_TOKEN || true)"

if [[ -z "$sync_token" ]]; then
  echo 'ERROR: Missing TECHNITIUM_DHCP_SYNC_TOKEN in encrypted password file.' >&2
  echo 'Run: task technitium:dhcp-sync:token' >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

escaped_token="$(printf '%s' "$sync_token" | escape_sed_replacement)"
sed "s/__TECHNITIUM_DHCP_SYNC_TOKEN__/${escaped_token}/g" "$TEMPLATE_FILE" > "$OUTPUT_FILE"
chmod 600 "$OUTPUT_FILE"

cat <<EOFOUT
Rendered MikroTik Technitium DHCP DDNS script:
${OUTPUT_FILE}

Apply it on the MikroTik router from WinBox terminal or SSH with:
/import file-name=technitium-dhcp-ddns.rsc
EOFOUT
