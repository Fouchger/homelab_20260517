#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/mikrotik-apply-baseline.sh
# Purpose:
#   Upload and import the staged MikroTik RouterOS baseline, then update stored
#   admin credentials after the scripted admin password rotation.
# Notes:
#   - Uses the current admin password for the import.
#   - After a successful import, MIKROTIK_ADMIN_PASSWORD is replaced with the
#     generated MIKROTIK_ADMIN_NEW_PASSWORD:-${MIKROTIK_ADMIN_PASSWORD} in SOPS.
# ===============================================================================

set -euo pipefail

ROOT_DIR="${ROOT_DIR:?ROOT_DIR is required}"
PASSWORDS_ENCRYPTED_FILE="${PASSWORDS_ENCRYPTED_FILE:?PASSWORDS_ENCRYPTED_FILE is required}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
SOPS_AGE_RECIPIENTS_FILE="${SOPS_AGE_RECIPIENTS_FILE:-${ROOT_DIR}/state/secrets/sops/recipients.txt}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/lib/mikrotik-common.sh"

ensure_sshpass
require_command sops

baseline_file="${ROOT_DIR}/state/generated/routeros/rtr-main-staged-baseline.rsc"
remote_baseline_file="rtr-main-staged-baseline.rsc"

if [[ ! -f "$baseline_file" ]]; then
  echo "ERROR: Rendered baseline not found: ${baseline_file}" >&2
  echo 'Run: task mikrotik:render' >&2
  exit 1
fi

plain_file="$(mktemp)"
trap 'rm -f "$plain_file"' EXIT

decrypt_password_file "$plain_file"
mikrotik_read_connection "$plain_file"

if [[ -z "${MIKROTIK_ADMIN_PASSWORD}" || -z "${MIKROTIK_ADMIN_NEW_PASSWORD:-${MIKROTIK_ADMIN_PASSWORD}}" ]]; then
  echo 'ERROR: MikroTik admin credentials are incomplete. Run: task mikrotik:credentials' >&2
  exit 1
fi

public_key_file="${HOME}/.ssh/homelab_ed25519.pub"
if [[ -f "$public_key_file" ]]; then
  mikrotik_scp_admin_to_router "$public_key_file" "homelab_ed25519.pub"
else
  echo "WARNING: SSH public key not found: ${public_key_file}; password auth will still work." >&2
fi

mikrotik_scp_admin_to_router "$baseline_file" "$remote_baseline_file"
mikrotik_ssh_admin "/import file-name=${remote_baseline_file}"

# The import rotated the admin password. Persist that as the current admin password.
admin_effective_password="${MIKROTIK_ADMIN_NEW_PASSWORD:-${MIKROTIK_ADMIN_PASSWORD}}"
set_or_append_dotenv_value "$plain_file" MIKROTIK_ADMIN_PASSWORD "$admin_effective_password"
SOPS_AGE_RECIPIENTS_FILE="$SOPS_AGE_RECIPIENTS_FILE" encrypt_password_file "$plain_file"

echo 'MikroTik staged baseline imported successfully and SOPS admin password was updated.'
