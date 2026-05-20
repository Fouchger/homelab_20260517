#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/secrets-dotenv.sh
# Purpose:
#   Shared helpers for reading and updating the homelab SOPS encrypted dotenv
#   password file.
# Notes:
#   - Callers must provide PASSWORDS_ENCRYPTED_FILE and SOPS_AGE_KEY_FILE.
#   - Callers that write secrets must also provide SOPS_AGE_RECIPIENTS_FILE.
#   - Do not print secret values.
# ==============================================================================

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: $1" >&2
    exit 1
  }
}

secrets_dotenv_require_read_config() {
  : "${PASSWORDS_ENCRYPTED_FILE:?PASSWORDS_ENCRYPTED_FILE is required}"
  : "${SOPS_AGE_KEY_FILE:?SOPS_AGE_KEY_FILE is required}"

  require_command sops
  require_command awk

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
}

secrets_dotenv_require_write_config() {
  secrets_dotenv_require_read_config
  : "${SOPS_AGE_RECIPIENTS_FILE:?SOPS_AGE_RECIPIENTS_FILE is required}"

  require_command cat

  if [[ ! -f "$SOPS_AGE_RECIPIENTS_FILE" ]]; then
    echo "ERROR: Missing SOPS age recipients file: ${SOPS_AGE_RECIPIENTS_FILE}" >&2
    echo "Run: task passwords:setup" >&2
    exit 1
  fi
}

secrets_dotenv_quote_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

secrets_dotenv_read_value_from_file() {
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

secrets_dotenv_upsert_file() {
  local file_path="$1"
  local key="$2"
  local value="$3"
  local quoted_value
  quoted_value="$(secrets_dotenv_quote_value "$value")"

  python3 - "$file_path" "$key" "$quoted_value" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

lines = path.read_text().splitlines() if path.exists() else []
out = []
updated = False

for line in lines:
    if line.startswith(f"{key}="):
        out.append(f"{key}={value}")
        updated = True
    else:
        out.append(line)

if not updated:
    out.append(f"{key}={value}")

path.write_text("\n".join(out) + "\n")
PY
}

secrets_dotenv_decrypt_to_file() {
  local output_file="$1"
  secrets_dotenv_require_read_config
  SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops --decrypt \
    --input-type dotenv \
    --output-type dotenv \
    "$PASSWORDS_ENCRYPTED_FILE" > "$output_file"
  if [[ "$output_file" != "/dev/stdout" ]]; then
    chmod 600 "$output_file"
  fi
}

secrets_dotenv_encrypt_from_file() {
  local input_file="$1"
  local next_file
  secrets_dotenv_require_write_config
  next_file="$(mktemp)"
  SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops --encrypt \
    --age "$(cat "$SOPS_AGE_RECIPIENTS_FILE")" \
    --filename-override "$PASSWORDS_ENCRYPTED_FILE" \
    --input-type dotenv \
    --output-type dotenv \
    "$input_file" > "$next_file"
  mv "$next_file" "$PASSWORDS_ENCRYPTED_FILE"
  chmod 600 "$PASSWORDS_ENCRYPTED_FILE"
}
