#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/technitium-run-playbook.sh
# Purpose:
#   Decrypt Technitium credentials into a temporary Ansible extra-vars file and
#   run the Technitium DNS playbook against the homelab inventory.
# Notes:
#   - Plaintext secrets only exist in temporary files during this process.
# ==============================================================================

set -euo pipefail

ROOT_DIR="${ROOT_DIR:?ROOT_DIR is required}"
PASSWORDS_ENCRYPTED_FILE="${PASSWORDS_ENCRYPTED_FILE:?PASSWORDS_ENCRYPTED_FILE is required}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
ANSIBLE_INVENTORY_FILE="${ANSIBLE_INVENTORY_FILE:?ANSIBLE_INVENTORY_FILE is required}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: $1" >&2
    exit 1
  }
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

yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

require_command ansible-playbook
require_command sops
require_command awk
require_command python3
require_command ssh-keygen
require_command ssh-keyscan

prepare_ssh_known_hosts() {
  local hosts_file
  hosts_file="$(mktemp)"
  python3 - "$ANSIBLE_INVENTORY_FILE" > "$hosts_file" <<'PYHOSTS'
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print('ERROR: Python module PyYAML is required to prepare SSH known_hosts.', file=sys.stderr)
    sys.exit(1)

inventory_file = Path(sys.argv[1])
inventory = yaml.safe_load(inventory_file.read_text()) or {}
hosts = (
    inventory.get('all', {})
    .get('children', {})
    .get('technitiumdns', {})
    .get('hosts', {})
)
for name, values in hosts.items():
    if isinstance(values, dict):
        address = values.get('ansible_host')
        port = values.get('ansible_port', 22)
        if address:
            print(f'{name} {address} {port}')
PYHOSTS

  while read -r host_name host_address host_port; do
    if [[ -z "${host_address:-}" ]]; then
      continue
    fi

    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    # Technitium LXCs can be recreated with the same IP. Refresh their known host
    # entries before the Ansible host-baseline play to avoid stale-key failures.
    ssh-keygen -R "$host_name" >/dev/null 2>&1 || true
    ssh-keygen -R "$host_address" >/dev/null 2>&1 || true
    ssh-keyscan -p "$host_port" -H "$host_name" "$host_address" >> ~/.ssh/known_hosts 2>/dev/null || true
    chmod 600 ~/.ssh/known_hosts
  done < "$hosts_file"
  rm -f "$hosts_file"
}


if [[ ! -f "$ANSIBLE_INVENTORY_FILE" ]]; then
  echo "ERROR: Missing inventory file: ${ANSIBLE_INVENTORY_FILE}" >&2
  echo "Run: task technitium:inventory:sync" >&2
  exit 1
fi

prepare_ssh_known_hosts

plain_file="$(mktemp)"
extra_vars_file="$(mktemp)"
trap 'rm -f "$plain_file" "$extra_vars_file"' EXIT

SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops --decrypt --input-type dotenv --output-type dotenv "$PASSWORDS_ENCRYPTED_FILE" > "$plain_file"
chmod 600 "$plain_file"

admin_user="$(extract_dotenv_value TECHNITIUM_ADMIN_USER)"
initial_password="$(extract_dotenv_value TECHNITIUM_INITIAL_PASSWORD)"
admin_password="$(extract_dotenv_value TECHNITIUM_ADMIN_PASSWORD)"

if [[ -z "$admin_user" || -z "$initial_password" || -z "$admin_password" ]]; then
  echo 'ERROR: Missing Technitium secrets. Run: task technitium:credentials' >&2
  exit 1
fi

{
  echo '---'
  printf 'technitium_admin_user_secret: %s\n' "$(yaml_quote "$admin_user")"
  printf 'technitium_initial_password_secret: %s\n' "$(yaml_quote "$initial_password")"
  printf 'technitium_admin_password_secret: %s\n' "$(yaml_quote "$admin_password")"
} > "$extra_vars_file"
chmod 600 "$extra_vars_file"

ANSIBLE_HOST_KEY_CHECKING=True ANSIBLE_ROLES_PATH="$ROOT_DIR/ansible/roles" ansible-playbook \
  -i "$ANSIBLE_INVENTORY_FILE" \
  "$ROOT_DIR/ansible/playbooks/technitium.yml" \
  --extra-vars "@$extra_vars_file"
