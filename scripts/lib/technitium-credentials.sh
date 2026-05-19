#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/technitium-credentials.sh
# Purpose:
#   Ensure Technitium DNS bootstrap credentials exist in the encrypted homelab
#   SOPS dotenv password file without interactive prompts.
# Notes:
#   - This script does not write plaintext credentials into the repository.
#   - Existing values are preserved by default to keep setup idempotent.
#   - DHCP sync API tokens are created by technitium-api-token.sh after the
#     Technitium API is reachable; they are not requested from the operator.
# ==============================================================================

set -euo pipefail

PASSWORDS_ENCRYPTED_FILE="${PASSWORDS_ENCRYPTED_FILE:?PASSWORDS_ENCRYPTED_FILE is required}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
SOPS_AGE_RECIPIENTS_FILE="${SOPS_AGE_RECIPIENTS_FILE:-${ROOT_DIR}/state/secrets/sops/recipients.txt}"
TECHNITIUM_CREDENTIALS_FORCE="${TECHNITIUM_CREDENTIALS_FORCE:-0}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: $1" >&2
    exit 1
  }
}

dotenv_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
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

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 36 | tr -d '\n' | cut -c1-40
  else
    LC_ALL=C tr -dc 'A-Za-z0-9_@%+=:.,-' < /dev/urandom | head -c 40
  fi
}

upsert_secret() {
  local key="$1"
  local value="$2"
  local quoted_value
  quoted_value="$(dotenv_quote "$value")"

  if grep -Eq "^${key}=" "$plain_file"; then
    awk -v key="$key" -v value="$quoted_value" 'BEGIN { FS = OFS = "=" } $1 == key { $0 = key "=" value } { print }' "$plain_file" > "$next_file"
    mv "$next_file" "$plain_file"
  else
    printf '%s=%s\n' "$key" "$quoted_value" >> "$plain_file"
  fi
}

require_command sops
require_command awk
require_command cat

if [[ ! -f "$PASSWORDS_ENCRYPTED_FILE" ]]; then
  echo "ERROR: Missing encrypted password file: ${PASSWORDS_ENCRYPTED_FILE}" >&2
  echo "Run: task passwords:setup" >&2
  exit 1
fi

if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
  echo "ERROR: Missing SOPS age key file: ${SOPS_AGE_KEY_FILE}" >&2
  echo "Run: task passwords:setup" >&2
  exit 1
fi

if [[ ! -f "$SOPS_AGE_RECIPIENTS_FILE" ]]; then
  echo "ERROR: Missing SOPS age recipients file: ${SOPS_AGE_RECIPIENTS_FILE}" >&2
  echo "Run: task passwords:setup" >&2
  exit 1
fi

plain_file="$(mktemp)"
next_file="$(mktemp)"
trap 'rm -f "$plain_file" "$next_file"' EXIT

SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops --decrypt --input-type dotenv --output-type dotenv "$PASSWORDS_ENCRYPTED_FILE" > "$plain_file"
chmod 600 "$plain_file"

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

SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops --encrypt \
  --age "$(cat "$SOPS_AGE_RECIPIENTS_FILE")" \
  --filename-override "$PASSWORDS_ENCRYPTED_FILE" \
  --input-type dotenv \
  --output-type dotenv \
  "$plain_file" > "$next_file"

mv "$next_file" "$PASSWORDS_ENCRYPTED_FILE"
chmod 600 "$PASSWORDS_ENCRYPTED_FILE"

echo 'Technitium bootstrap credentials are present in the encrypted password file.'
