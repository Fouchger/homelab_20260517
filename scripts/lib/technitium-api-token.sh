#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/technitium-api-token.sh
# Purpose:
#   Create or validate the Technitium DHCP sync API token non-interactively and
#   store it in the encrypted homelab SOPS dotenv password file.
# Notes:
#   - The token is generated from the configured Technitium admin credentials.
#   - Existing valid tokens are preserved by default.
#   - Use TECHNITIUM_DHCP_SYNC_TOKEN_FORCE=1 to rotate the token.
# ==============================================================================

set -euo pipefail

PASSWORDS_ENCRYPTED_FILE="${PASSWORDS_ENCRYPTED_FILE:?PASSWORDS_ENCRYPTED_FILE is required}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:?SOPS_AGE_KEY_FILE is required}"
SOPS_AGE_RECIPIENTS_FILE="${SOPS_AGE_RECIPIENTS_FILE:?SOPS_AGE_RECIPIENTS_FILE is required}"
TECHNITIUM_PRIMARY_URL="${TECHNITIUM_PRIMARY_URL:-http://192.168.30.2:5380}"
TECHNITIUM_DHCP_SYNC_TOKEN_NAME="${TECHNITIUM_DHCP_SYNC_TOKEN_NAME:-homelab-mikrotik-ddns}"
TECHNITIUM_DHCP_SYNC_USER="${TECHNITIUM_DHCP_SYNC_USER:-mikrotik-ddns}"
TECHNITIUM_DHCP_SYNC_TOKEN_FORCE="${TECHNITIUM_DHCP_SYNC_TOKEN_FORCE:-0}"

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
require_command python3
require_command cat

if [[ ! -f "$PASSWORDS_ENCRYPTED_FILE" ]]; then
  echo "ERROR: Missing encrypted password file: ${PASSWORDS_ENCRYPTED_FILE}" >&2
  echo "Run: task passwords:setup" >&2
  exit 1
fi

plain_file="$(mktemp)"
next_file="$(mktemp)"
trap 'rm -f "$plain_file" "$next_file"' EXIT

SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops --decrypt --input-type dotenv --output-type dotenv "$PASSWORDS_ENCRYPTED_FILE" > "$plain_file"
chmod 600 "$plain_file"

admin_user="$(extract_dotenv_value TECHNITIUM_ADMIN_USER || true)"
admin_password="$(extract_dotenv_value TECHNITIUM_ADMIN_PASSWORD || true)"
existing_token="$(extract_dotenv_value TECHNITIUM_DHCP_SYNC_TOKEN || true)"

if [[ -z "$admin_user" || -z "$admin_password" ]]; then
  echo 'ERROR: Missing Technitium admin credentials. Run: task technitium:credentials' >&2
  exit 1
fi

if [[ "$TECHNITIUM_DHCP_SYNC_TOKEN_FORCE" != "1" && -n "$existing_token" ]]; then
  if TECHNITIUM_PRIMARY_URL="$TECHNITIUM_PRIMARY_URL" TECHNITIUM_DHCP_SYNC_TOKEN="$existing_token" python3 - <<'PYVALIDATE'
import json
import os
import sys
import time
import urllib.error
import urllib.request

base_url = os.environ['TECHNITIUM_PRIMARY_URL'].rstrip('/')
token = os.environ['TECHNITIUM_DHCP_SYNC_TOKEN']
request = urllib.request.Request(
    f'{base_url}/api/user/session/get',
    headers={'Authorization': f'Bearer {token}'},
    method='POST',
)
payload = None
for attempt in range(1, 6):
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.loads(response.read().decode('utf-8'))
        break
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        if attempt == 5:
            sys.exit(1)
        time.sleep(min(attempt * 2, 8))

sys.exit(0 if payload and payload.get('status') == 'ok' else 1)
PYVALIDATE
  then
    echo 'Technitium DHCP sync API token already exists and is valid. Skipping token creation.'
    exit 0
  fi

  echo 'Existing Technitium DHCP sync API token is missing or invalid. Creating a replacement.'
fi

new_token="$(TECHNITIUM_PRIMARY_URL="$TECHNITIUM_PRIMARY_URL" \
  TECHNITIUM_ADMIN_USER="$admin_user" \
  TECHNITIUM_ADMIN_PASSWORD="$admin_password" \
  TECHNITIUM_DHCP_SYNC_TOKEN_NAME="$TECHNITIUM_DHCP_SYNC_TOKEN_NAME" \
  TECHNITIUM_DHCP_SYNC_USER="$TECHNITIUM_DHCP_SYNC_USER" \
  python3 - <<'PYTOKEN'
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

base_url = os.environ['TECHNITIUM_PRIMARY_URL'].rstrip('/')
admin_user = os.environ['TECHNITIUM_ADMIN_USER']
admin_password = os.environ['TECHNITIUM_ADMIN_PASSWORD']
dhcp_user = os.environ['TECHNITIUM_DHCP_SYNC_USER']
token_name = os.environ['TECHNITIUM_DHCP_SYNC_TOKEN_NAME']

dynamic_zones = [
    'dhcp.fouchger.uk',
    '20.168.192.in-addr.arpa',
    '30.168.192.in-addr.arpa',
    '40.168.192.in-addr.arpa',
    '50.168.192.in-addr.arpa',
    '60.168.192.in-addr.arpa',
    '70.168.192.in-addr.arpa',
    '90.168.192.in-addr.arpa',
]


def api_call(path, data=None, token=None, timeout=20, retries=5):
    encoded = None
    headers = {}
    if data is not None:
        encoded = urllib.parse.urlencode(data).encode('utf-8')
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
    if token:
        headers['Authorization'] = f'Bearer {token}'
    request = urllib.request.Request(
        f'{base_url}{path}',
        data=encoded,
        headers=headers,
        method='POST',
    )
    last_error = None
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode('utf-8'))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            last_error = error
            if attempt == retries:
                raise
            time.sleep(min(attempt * 2, 10))
    raise RuntimeError(f'API call failed: {last_error}')

try:
    login = api_call('/api/user/login', {
        'user': admin_user,
        'pass': admin_password,
        'includeInfo': 'true',
    })
except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
    print(f'ERROR: Technitium admin login failed while creating DHCP sync token: {error}', file=sys.stderr)
    sys.exit(1)

if login.get('status') != 'ok' or not login.get('token'):
    print('ERROR: Technitium admin login was rejected while creating DHCP sync token.', file=sys.stderr)
    sys.exit(1)

admin_token = login['token']
transient_password = secrets.token_urlsafe(36)

try:
    create_user = api_call('/api/admin/users/create', {
        'user': dhcp_user,
        'pass': transient_password,
        'displayName': 'MikroTik DHCP DDNS',
    }, token=admin_token)
except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
    print(f'ERROR: Technitium DHCP sync user creation failed: {error}', file=sys.stderr)
    sys.exit(1)

if create_user.get('status') != 'ok':
    message = str(create_user.get('errorMessage', create_user))
    if 'exist' not in message.lower() and 'already' not in message.lower():
        print(f'ERROR: Technitium DHCP sync user creation failed: {message}', file=sys.stderr)
        sys.exit(1)

for zone in dynamic_zones:
    try:
        result = api_call('/api/zones/permissions/set', {
            'zone': zone,
            'userPermissions': f'{dhcp_user}|true|true|true',
        }, token=admin_token)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        print(f'ERROR: Failed to set permissions for zone {zone}: {error}', file=sys.stderr)
        sys.exit(1)
    if result.get('status') != 'ok':
        print(f'ERROR: Failed to set permissions for zone {zone}: {result.get("errorMessage", result)}', file=sys.stderr)
        sys.exit(1)

try:
    created_token = api_call('/api/admin/sessions/createToken', {
        'user': dhcp_user,
        'tokenName': token_name,
    }, token=admin_token)
except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
    print(f'ERROR: Technitium API token creation failed: {error}', file=sys.stderr)
    sys.exit(1)

payload = created_token.get('response', created_token)
if created_token.get('status') != 'ok' or not payload.get('token'):
    print('ERROR: Technitium API token creation returned an unexpected response.', file=sys.stderr)
    sys.exit(1)

print(payload['token'])
PYTOKEN
)"

if [[ -z "$new_token" ]]; then
  echo 'ERROR: Technitium API token creation did not return a token.' >&2
  exit 1
fi

upsert_secret TECHNITIUM_DHCP_SYNC_TOKEN "$new_token"

SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops --encrypt \
  --age "$(cat "$SOPS_AGE_RECIPIENTS_FILE")" \
  --filename-override "$PASSWORDS_ENCRYPTED_FILE" \
  --input-type dotenv \
  --output-type dotenv \
  "$plain_file" > "$next_file"

mv "$next_file" "$PASSWORDS_ENCRYPTED_FILE"
chmod 600 "$PASSWORDS_ENCRYPTED_FILE"

echo 'Technitium DHCP sync API token is present in the encrypted password file.'
