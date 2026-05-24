#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/mikrotik-config-secrets.sh
# Purpose:
#   Ensure required MikroTik RouterOS configuration secrets exist in the standard
#   SOPS encrypted dotenv password file before Ansible applies router config.
# Notes:
#   - Prompts only for missing values.
#   - Saves entered values back to SOPS.
#   - Never prints secret values.
# ==============================================================================
set -euo pipefail

usage() {
  cat <<'EOUSAGE'
Usage: mikrotik-config-secrets.sh --password-file FILE --age-key-file FILE --recipients-file FILE [options]

Options:
  --admin-password-var NAME
  --backup-password-var NAME
  --wifi-users-passphrase-var NAME
  --wifi-mgmt-passphrase-var NAME
  --wifi-iot-passphrase-var NAME
  --wifi-guest-passphrase-var NAME
EOUSAGE
}

password_file=""
age_key_file=""
recipients_file=""
admin_password_var="MIKROTIK_ADMIN_PASSWORD"
backup_password_var="MIKROTIK_BACKUP_PASSWORD"
wifi_users_passphrase_var="MIKROTIK_WIFI_USERS_PASSPHRASE"
wifi_mgmt_passphrase_var="MIKROTIK_WIFI_MGMT_PASSPHRASE"
wifi_iot_passphrase_var="MIKROTIK_WIFI_IOT_PASSPHRASE"
wifi_guest_passphrase_var="MIKROTIK_WIFI_GUEST_PASSPHRASE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password-file) password_file="$2"; shift 2 ;;
    --age-key-file) age_key_file="$2"; shift 2 ;;
    --recipients-file) recipients_file="$2"; shift 2 ;;
    --admin-password-var) admin_password_var="$2"; shift 2 ;;
    --backup-password-var) backup_password_var="$2"; shift 2 ;;
    --wifi-users-passphrase-var) wifi_users_passphrase_var="$2"; shift 2 ;;
    --wifi-mgmt-passphrase-var) wifi_mgmt_passphrase_var="$2"; shift 2 ;;
    --wifi-iot-passphrase-var) wifi_iot_passphrase_var="$2"; shift 2 ;;
    --wifi-guest-passphrase-var) wifi_guest_passphrase_var="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$password_file" ]] || { echo "ERROR: --password-file is required" >&2; exit 1; }
[[ -n "$age_key_file" ]] || { echo "ERROR: --age-key-file is required" >&2; exit 1; }
[[ -n "$recipients_file" ]] || { echo "ERROR: --recipients-file is required" >&2; exit 1; }
[[ -f "$password_file" ]] || { echo "ERROR: Missing encrypted password file: $password_file" >&2; exit 1; }
[[ -f "$age_key_file" ]] || { echo "ERROR: Missing SOPS age key file: $age_key_file" >&2; exit 1; }
[[ -f "$recipients_file" ]] || { echo "ERROR: Missing SOPS recipients file: $recipients_file" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${script_dir}/secrets-dotenv.sh"
export PASSWORDS_ENCRYPTED_FILE="$password_file"
export SOPS_AGE_KEY_FILE="$age_key_file"
export SOPS_AGE_RECIPIENTS_FILE="$recipients_file"

if [[ ! -r /dev/tty ]]; then
  echo "ERROR: Cannot prompt for missing MikroTik secrets because /dev/tty is not available." >&2
  echo "Run this task from an interactive shell, or add the values with: task passwords:edit" >&2
  exit 1
fi

runtime_file="$(mktemp)"
cleanup() {
  rm -f "$runtime_file"
}
trap cleanup EXIT

secrets_dotenv_decrypt_to_file "$runtime_file"

read_secret_value() {
  local key="$1"
  secrets_dotenv_read_value_from_file "$runtime_file" "$key" || true
}

prompt_secret_value() {
  local label="$1"
  local value=""
  local confirm=""

  while true; do
    printf '%s: ' "$label" > /dev/tty
    stty -echo < /dev/tty || true
    IFS= read -r value < /dev/tty
    stty echo < /dev/tty || true
    printf '\n' > /dev/tty

    if [[ -z "$value" ]]; then
      echo "Value cannot be blank." > /dev/tty
      continue
    fi

    printf 'Confirm %s: ' "$label" > /dev/tty
    stty -echo < /dev/tty || true
    IFS= read -r confirm < /dev/tty
    stty echo < /dev/tty || true
    printf '\n' > /dev/tty

    if [[ "$value" == "$confirm" ]]; then
      printf '%s' "$value"
      return 0
    fi

    echo "Values did not match. Try again." > /dev/tty
  done
}

ensure_secret() {
  local key="$1"
  local label="$2"
  local current=""
  current="$(read_secret_value "$key")"

  if [[ -n "$current" ]]; then
    echo "Existing SOPS value found for ${key}. Reusing saved value."
    return 0
  fi

  echo "Missing SOPS value for ${key}."
  local value=""
  value="$(prompt_secret_value "$label")"
  secrets_dotenv_upsert_file "$runtime_file" "$key" "$value"
  echo "Saved ${key} to SOPS."
}

ensure_secret "$admin_password_var" "MikroTik admin user password"
ensure_secret "$backup_password_var" "MikroTik encrypted binary backup password"
ensure_secret "$wifi_users_passphrase_var" "MikroTik USERS Wi-Fi passphrase"
ensure_secret "$wifi_mgmt_passphrase_var" "MikroTik MGMT Wi-Fi passphrase"
ensure_secret "$wifi_iot_passphrase_var" "MikroTik IOT Wi-Fi passphrase"
ensure_secret "$wifi_guest_passphrase_var" "MikroTik GUEST Wi-Fi passphrase"

secrets_dotenv_encrypt_from_file "$runtime_file"
echo "MikroTik configuration secrets are ready in SOPS."
