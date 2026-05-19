#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/mikrotik-credentials.sh
# Purpose:
#   Capture MikroTik bootstrap credentials once and store generated automation
#   credentials in the encrypted SOPS password file.
# Notes:
#   - Username for the initial router login is admin by default.
#   - This script prompts only when required values are missing, or when
#     MIKROTIK_CREDENTIALS_FORCE=1 is set.
# ===============================================================================

set -euo pipefail

ROOT_DIR="${ROOT_DIR:?ROOT_DIR is required}"
PASSWORDS_ENCRYPTED_FILE="${PASSWORDS_ENCRYPTED_FILE:?PASSWORDS_ENCRYPTED_FILE is required}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:?SOPS_AGE_KEY_FILE is required}"
SOPS_AGE_RECIPIENTS_FILE="${SOPS_AGE_RECIPIENTS_FILE:?SOPS_AGE_RECIPIENTS_FILE is required}"
MIKROTIK_CREDENTIALS_FORCE="${MIKROTIK_CREDENTIALS_FORCE:-0}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/lib/mikrotik-common.sh"

require_command openssl
require_command sops
require_command awk

plain_file="$(mktemp)"
trap 'rm -f "$plain_file"' EXIT

decrypt_password_file "$plain_file"

existing_host="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_HOST || true)"
existing_admin_user="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_ADMIN_USER || true)"
existing_admin_password="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_ADMIN_PASSWORD || true)"
existing_admin_new_password="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_ADMIN_NEW_PASSWORD || true)"
existing_automation_user="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_AUTOMATION_USER || true)"
existing_automation_password="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_AUTOMATION_PASSWORD || true)"
existing_backup_password="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_BACKUP_PASSWORD || true)"

router_host="${existing_host:-192.168.20.1}"
admin_user="${existing_admin_user:-admin}"
automation_user="${existing_automation_user:-homelab-ansible}"

if [[ "$MIKROTIK_CREDENTIALS_FORCE" == "1" || -z "$existing_host" ]]; then
  read -r -p "MikroTik router address [${router_host}]: " entered_host
  router_host="${entered_host:-$router_host}"
fi

admin_password="$existing_admin_password"
if [[ "$MIKROTIK_CREDENTIALS_FORCE" == "1" || -z "$admin_password" ]]; then
  printf 'Current MikroTik admin password for %s@%s: ' "$admin_user" "$router_host" >&2
  IFS= read -r -s admin_password
  printf '\n' >&2
fi

if [[ -z "$admin_password" ]]; then
  echo 'ERROR: MikroTik admin password cannot be blank.' >&2
  exit 1
fi

admin_new_password="$existing_admin_new_password"
if [[ "$MIKROTIK_CREDENTIALS_FORCE" == "1" || -z "$admin_new_password" ]]; then
  admin_new_password="$(openssl rand -base64 36 | tr -d '\n')"
fi

automation_password="$existing_automation_password"
if [[ "$MIKROTIK_CREDENTIALS_FORCE" == "1" || -z "$automation_password" ]]; then
  automation_password="$(openssl rand -base64 36 | tr -d '\n')"
fi

backup_password="$existing_backup_password"
if [[ "$MIKROTIK_CREDENTIALS_FORCE" == "1" || -z "$backup_password" ]]; then
  backup_password="$(openssl rand -base64 36 | tr -d '\n')"
fi

set_or_append_dotenv_value "$plain_file" MIKROTIK_HOST "$router_host"
set_or_append_dotenv_value "$plain_file" MIKROTIK_ADMIN_USER "$admin_user"
set_or_append_dotenv_value "$plain_file" MIKROTIK_ADMIN_PASSWORD "$admin_password"
set_or_append_dotenv_value "$plain_file" MIKROTIK_ADMIN_NEW_PASSWORD "$admin_new_password"
set_or_append_dotenv_value "$plain_file" MIKROTIK_AUTOMATION_USER "$automation_user"
set_or_append_dotenv_value "$plain_file" MIKROTIK_AUTOMATION_PASSWORD "$automation_password"
set_or_append_dotenv_value "$plain_file" MIKROTIK_BACKUP_PASSWORD "$backup_password"

# Compatibility aliases used by existing Technitium MikroTik deploy scripts.
set_or_append_dotenv_value "$plain_file" MIKROTIK_SSH_USER "$automation_user"
set_or_append_dotenv_value "$plain_file" MIKROTIK_SSH_PASSWORD "$automation_password"
set_or_append_dotenv_value "$plain_file" MIKROTIK_AUTOMATION_HOST "$router_host"

SOPS_AGE_RECIPIENTS_FILE="$SOPS_AGE_RECIPIENTS_FILE" encrypt_password_file "$plain_file"

echo 'MikroTik credentials are present in the encrypted password file.'
