#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/mikrotik-validate.sh
# Purpose:
#   Validate MikroTik automation access and core RouterOS settings.
# Notes:
#   - Uses the dedicated automation account after setup.
# ===============================================================================

set -euo pipefail

ROOT_DIR="${ROOT_DIR:?ROOT_DIR is required}"
PASSWORDS_ENCRYPTED_FILE="${PASSWORDS_ENCRYPTED_FILE:?PASSWORDS_ENCRYPTED_FILE is required}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/lib/mikrotik-common.sh"

ensure_sshpass

plain_file="$(mktemp)"
trap 'rm -f "$plain_file"' EXIT

decrypt_password_file "$plain_file"
mikrotik_read_connection "$plain_file"

if [[ -z "${MIKROTIK_AUTOMATION_PASSWORD}" ]]; then
  echo 'ERROR: MIKROTIK_AUTOMATION_PASSWORD is missing. Run: task mikrotik:credentials' >&2
  exit 1
fi

routeros_cmd() {
  sshpass -p "${MIKROTIK_AUTOMATION_PASSWORD}" ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=20 \
    "${MIKROTIK_AUTOMATION_USER}@${MIKROTIK_HOST}" "$@"
}

identity="$(routeros_cmd '/system identity print value-list' | awk -F: '/name:/ {gsub(/^ +/, "", $2); print $2; exit}')"
if [[ "$identity" != "RTR-MAIN" ]]; then
  echo "ERROR: Unexpected MikroTik identity: ${identity}" >&2
  exit 1
fi

routeros_cmd ':if ([/ip dns get servers] != "192.168.30.2,192.168.30.3") do={ :error "Unexpected DNS servers" }'
routeros_cmd ':if ([/ip service get ssh disabled] = true) do={ :error "SSH service is disabled" }'
routeros_cmd ':if ([/ip service get api disabled] = true) do={ :error "API service is disabled" }'
routeros_cmd ':if ([:len [/user find name="'"${MIKROTIK_AUTOMATION_USER}"'"]] = 0) do={ :error "Automation user missing" }'
routeros_cmd ':if ([:len [/ip firewall filter find comment="HOMELAB MGMT automation SSH/API"]] = 0) do={ :error "Automation firewall rule missing" }'

echo "MikroTik validation completed successfully for ${MIKROTIK_HOST}."
