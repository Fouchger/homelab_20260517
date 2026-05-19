#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/mikrotik-backup.sh
# Purpose:
#   Create and download a MikroTik sensitive export and encrypted binary backup.
# Notes:
#   - Backups contain secrets and are stored under state/backups/mikrotik.
# ===============================================================================

set -euo pipefail

ROOT_DIR="${ROOT_DIR:?ROOT_DIR is required}"
PASSWORDS_ENCRYPTED_FILE="${PASSWORDS_ENCRYPTED_FILE:?PASSWORDS_ENCRYPTED_FILE is required}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/lib/mikrotik-common.sh"

require_command sops
require_command sha256sum
ensure_sshpass

plain_file="$(mktemp)"
trap 'rm -f "$plain_file"' EXIT

decrypt_password_file "$plain_file"
mikrotik_read_connection "$plain_file"

if [[ -z "${MIKROTIK_ADMIN_PASSWORD}" ]]; then
  echo 'ERROR: MIKROTIK_ADMIN_PASSWORD is missing. Run: task mikrotik:credentials' >&2
  exit 1
fi

backup_dir="${ROOT_DIR}/state/backups/mikrotik/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"

base_name="rtr-main-sensitive-$(date +%Y%m%d-%H%M%S)"
backup_password_escaped="$(routeros_escape "${MIKROTIK_BACKUP_PASSWORD}")"

mikrotik_ssh_admin "/export show-sensitive file=${base_name}; /system backup save name=${base_name} password=\"${backup_password_escaped}\""

mikrotik_scp_admin_from_router "${base_name}.rsc" "${backup_dir}/${base_name}.rsc"
mikrotik_scp_admin_from_router "${base_name}.backup" "${backup_dir}/${base_name}.backup"

sha256sum "${backup_dir}/${base_name}.rsc" "${backup_dir}/${base_name}.backup" > "${backup_dir}/SHA256SUMS"
chmod 600 "${backup_dir}"/*

cat > "${backup_dir}/README.txt" <<EONOTE
MikroTik sensitive backup
Created: $(date -Iseconds)
Router: ${MIKROTIK_HOST}
Files:
- ${base_name}.rsc: text export with sensitive values
- ${base_name}.backup: RouterOS binary backup encrypted with MIKROTIK_BACKUP_PASSWORD from SOPS
- SHA256SUMS: integrity checksums
EONOTE
chmod 600 "${backup_dir}/README.txt"

echo "MikroTik sensitive backup completed: ${backup_dir}"
