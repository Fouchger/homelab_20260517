#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/technitium-credentials.sh
# Purpose:
#   Ensure Technitium DNS bootstrap credentials exist in the encrypted homelab
#   SOPS dotenv password file without interactive prompts.
# Notes:
#   - This script does not write plaintext credentials into the repository.
#   - Existing values are preserved by default to keep setup idempotent.
# # ==============================================================================

set -euo pipefail

PASSWORDS_ENCRYPTED_FILE="${PASSWORDS_ENCRYPTED_FILE:?PASSWORDS_ENCRYPTED_FILE is required}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:?SOPS_AGE_KEY_FILE is required}"
SOPS_AGE_RECIPIENTS_FILE="${SOPS_AGE_RECIPIENTS_FILE:?SOPS_AGE_RECIPIENTS_FILE is required}"
TECHNITIUM_CREDENTIALS_FORCE="${TECHNITIUM_CREDENTIALS_FORCE:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/secrets-dotenv.sh
source "${SCRIPT_DIR}/secrets-dotenv.sh"

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 36 | tr -d '\n' | cut -c1-40
  else
    LC_ALL=C tr -dc 'A-Za-z0-9_@%+=:.,-' < /dev/urandom | head -c 40
  fi
}

extract_dotenv_value() {
  secrets_dotenv_read_value_from_file "$plain_file" "$1"
}

upsert_secret() {
  secrets_dotenv_upsert_file "$plain_file" "$1" "$2"
}

secrets_dotenv_require_write_config

plain_file="$(mktemp)"
next_file="$(mktemp)"
trap 'rm -f "$plain_file" "$next_file"' EXIT

secrets_dotenv_decrypt_to_file "$plain_file"

existing_admin_user="$(extract_dotenv_value TECHNITIUM_ADMIN_USER || true)"
existing_initial_password="$(extract_dotenv_value TECHNITIUM_INITIAL_PASSWORD || true)"
existing_admin_password="$(extract_dotenv_value TECHNITIUM_ADMIN_PASSWORD || true)"

if [[ "$TECHNITIUM_CREDENTIALS_FORCE" != "1" \
  && -n "$existing_admin_user" \
  && -n "$existing_initial_password" \
  && -n "$existing_admin_password" ]]; then
  echo 'Technitium bootstrap credentials already exist in the encrypted password file. Skipping update.'
  exit 0
fi

admin_user="${existing_admin_user:-admin}"
initial_password="${existing_initial_password:-admin}"
admin_password="$existing_admin_password"

if [[ "$TECHNITIUM_CREDENTIALS_FORCE" == "1" || -z "$admin_password" ]]; then
  admin_password="$(generate_secret)"
fi

if [[ ${#admin_password} -lt 12 ]]; then
  echo 'ERROR: Generated Technitium production password is shorter than 12 characters.' >&2
  exit 1
fi

upsert_secret TECHNITIUM_ADMIN_USER "$admin_user"
upsert_secret TECHNITIUM_INITIAL_PASSWORD "$initial_password"
upsert_secret TECHNITIUM_ADMIN_PASSWORD "$admin_password"

secrets_dotenv_encrypt_from_file "$plain_file"

echo 'Technitium bootstrap credentials are present in the encrypted password file.'
