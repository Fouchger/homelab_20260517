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

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: $1" >&2
    exit 1
  }
}

extract_dotenv_value_from_file() {
  local file_path="$1"
  local key="$2"
  awk -F= -v key="$key" '
    $1 == key {
      sub(/^[^=]*=/, "")
      gsub(/^"|"$/, "")
      gsub(/\\"/, "\"")
      gsub(/\\\\/, "\\")
      print
      exit
    }
  ' "$file_path"
}

quote_dotenv_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

set_or_append_dotenv_value() {
  local file_path="$1"
  local key="$2"
  local value="$3"
  local quoted_value
  quoted_value="$(quote_dotenv_value "$value")"

  if grep -q "^${key}=" "$file_path"; then
    python3 - "$file_path" "$key" "$quoted_value" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text().splitlines()
out = []
updated = False
for line in lines:
    if line.startswith(key + '='):
        out.append(f'{key}={value}')
        updated = True
    else:
        out.append(line)
if not updated:
    out.append(f'{key}={value}')
path.write_text('\n'.join(out) + '\n')
PY
  else
    printf '%s=%s\n' "$key" "$quoted_value" >> "$file_path"
  fi
}

decrypt_password_file() {
  local output_file="$1"
  require_command sops
  if [[ ! -f "${PASSWORDS_ENCRYPTED_FILE}" ]]; then
    echo "ERROR: Encrypted password file does not exist: ${PASSWORDS_ENCRYPTED_FILE}" >&2
    exit 1
  fi
  SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE}" sops --decrypt --input-type dotenv --output-type dotenv "${PASSWORDS_ENCRYPTED_FILE}" > "$output_file"
  chmod 600 "$output_file"
}

encrypt_password_file() {
  local input_file="$1"
  local next_file
  require_command sops
  next_file="$(mktemp)"
  SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE}" sops --encrypt \
    --age "$(cat "${SOPS_AGE_RECIPIENTS_FILE}")" \
    --filename-override "${PASSWORDS_ENCRYPTED_FILE}" \
    --input-type dotenv \
    --output-type dotenv \
    "$input_file" > "$next_file"
  mv "$next_file" "${PASSWORDS_ENCRYPTED_FILE}"
  chmod 600 "${PASSWORDS_ENCRYPTED_FILE}"
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
