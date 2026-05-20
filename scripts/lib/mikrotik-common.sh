#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/mikrotik-common.sh
# Purpose:
#   Shared helpers for MikroTik RouterOS automation scripts.
# Notes:
#   - Secrets are read from a temporary decrypted SOPS dotenv file.
#   - Do not print password values.
# ===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/secrets-dotenv.sh
source "${SCRIPT_DIR}/secrets-dotenv.sh"

extract_dotenv_value_from_file() {
  secrets_dotenv_read_value_from_file "$@"
}

quote_dotenv_value() {
  secrets_dotenv_quote_value "$@"
}

set_or_append_dotenv_value() {
  secrets_dotenv_upsert_file "$@"
}

decrypt_password_file() {
  secrets_dotenv_decrypt_to_file "$@"
}

encrypt_password_file() {
  secrets_dotenv_encrypt_from_file "$@"
}

ensure_sshpass() {
  if ! command -v sshpass >/dev/null 2>&1; then
    if [[ "${EUID}" -eq 0 ]]; then
      apt-get update -y >/dev/null
      apt-get install -y sshpass >/dev/null
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -y >/dev/null
      sudo apt-get install -y sshpass >/dev/null
    else
      echo "ERROR: sshpass is required and sudo is not available to install it." >&2
      exit 1
    fi
  fi
}

routeros_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

mikrotik_read_connection() {
  local plain_file="$1"
  MIKROTIK_HOST="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_HOST || true)"
  MIKROTIK_ADMIN_USER="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_ADMIN_USER || true)"
  MIKROTIK_ADMIN_PASSWORD="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_ADMIN_PASSWORD || true)"
  MIKROTIK_ADMIN_NEW_PASSWORD="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_ADMIN_NEW_PASSWORD || true)"
  MIKROTIK_ADMIN_EFFECTIVE_PASSWORD="${MIKROTIK_ADMIN_NEW_PASSWORD:-${MIKROTIK_ADMIN_PASSWORD}}"
  MIKROTIK_AUTOMATION_USER="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_AUTOMATION_USER || true)"
  MIKROTIK_AUTOMATION_PASSWORD="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_AUTOMATION_PASSWORD || true)"
  MIKROTIK_BACKUP_PASSWORD="$(extract_dotenv_value_from_file "$plain_file" MIKROTIK_BACKUP_PASSWORD || true)"

  MIKROTIK_HOST="${MIKROTIK_HOST:-192.168.20.1}"
  MIKROTIK_ADMIN_USER="${MIKROTIK_ADMIN_USER:-admin}"
  MIKROTIK_AUTOMATION_USER="${MIKROTIK_AUTOMATION_USER:-homelab-ansible}"
}

mikrotik_ssh_admin() {
  sshpass -p "${MIKROTIK_ADMIN_PASSWORD}" ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=20 \
    "${MIKROTIK_ADMIN_USER}@${MIKROTIK_HOST}" "$@"
}

mikrotik_scp_admin_to_router() {
  local local_file="$1"
  local remote_file="$2"
  sshpass -p "${MIKROTIK_ADMIN_PASSWORD}" scp \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=20 \
    "$local_file" "${MIKROTIK_ADMIN_USER}@${MIKROTIK_HOST}:${remote_file}"
}

mikrotik_scp_admin_from_router() {
  local remote_file="$1"
  local local_file="$2"
  sshpass -p "${MIKROTIK_ADMIN_PASSWORD}" scp \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=20 \
    "${MIKROTIK_ADMIN_USER}@${MIKROTIK_HOST}:${remote_file}" "$local_file"
}
