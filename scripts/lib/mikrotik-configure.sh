#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/mikrotik-configure.sh
# Purpose:
#   Render, plan, and apply the homelab RouterOS 7 baseline configuration for
#   MikroTik inventory hosts from the local control node.
# Notes:
#   - Uses key-based SSH for the steady-state automation user.
#   - Reads secrets from the standard SOPS dotenv password file.
#   - Produces sensitive and redacted review artefacts before any apply.
#   - Apply uploads the rendered RouterOS script with SCP and imports it over SSH.
# ==============================================================================
set -euo pipefail

usage() {
  cat <<'EOUSAGE'
Usage: mikrotik-configure.sh --inventory-file FILE --password-file FILE --age-key-file FILE --recipients-file FILE --inventory-manager FILE --ssh-key-file FILE --config-template FILE [options]

Options:
  --mode render|plan|apply
  --output-dir DIR
  --remote-config-file NAME
  --group NAME
  --admin-password-var NAME
  --backup-password-var NAME
  --wifi-users-passphrase-var NAME
  --wifi-mgmt-passphrase-var NAME
  --wifi-iot-passphrase-var NAME
  --wifi-guest-passphrase-var NAME
EOUSAGE
}

inventory_file=""
password_file=""
age_key_file=""
recipients_file=""
inventory_manager=""
ssh_key_file=""
config_template=""
mode="apply"
output_dir=""
remote_config_file="homelab-router-baseline.rsc"
group="mikrotik"
admin_password_var="MIKROTIK_ADMIN_PASSWORD"
backup_password_var="MIKROTIK_BACKUP_PASSWORD"
wifi_users_passphrase_var="MIKROTIK_WIFI_USERS_PASSPHRASE"
wifi_mgmt_passphrase_var="MIKROTIK_WIFI_MGMT_PASSPHRASE"
wifi_iot_passphrase_var="MIKROTIK_WIFI_IOT_PASSPHRASE"
wifi_guest_passphrase_var="MIKROTIK_WIFI_GUEST_PASSPHRASE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory-file) inventory_file="$2"; shift 2 ;;
    --password-file) password_file="$2"; shift 2 ;;
    --age-key-file) age_key_file="$2"; shift 2 ;;
    --recipients-file) recipients_file="$2"; shift 2 ;;
    --inventory-manager) inventory_manager="$2"; shift 2 ;;
    --ssh-key-file) ssh_key_file="$2"; shift 2 ;;
    --config-template) config_template="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --output-dir) output_dir="$2"; shift 2 ;;
    --remote-config-file) remote_config_file="$2"; shift 2 ;;
    --group) group="$2"; shift 2 ;;
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

case "$mode" in
  render|plan|apply) ;;
  *) echo "ERROR: Unknown MikroTik configuration mode: $mode" >&2; usage >&2; exit 1 ;;
esac

[[ -n "$inventory_file" ]] || { echo "ERROR: --inventory-file is required" >&2; exit 1; }
[[ -n "$password_file" ]] || { echo "ERROR: --password-file is required" >&2; exit 1; }
[[ -n "$age_key_file" ]] || { echo "ERROR: --age-key-file is required" >&2; exit 1; }
[[ -n "$recipients_file" ]] || { echo "ERROR: --recipients-file is required" >&2; exit 1; }
[[ -n "$inventory_manager" ]] || { echo "ERROR: --inventory-manager is required" >&2; exit 1; }
[[ -n "$ssh_key_file" ]] || { echo "ERROR: --ssh-key-file is required" >&2; exit 1; }
[[ -n "$config_template" ]] || { echo "ERROR: --config-template is required" >&2; exit 1; }

[[ -f "$inventory_file" ]] || { echo "ERROR: Missing inventory file: $inventory_file" >&2; exit 1; }
[[ -f "$password_file" ]] || { echo "ERROR: Missing encrypted password file: $password_file" >&2; exit 1; }
[[ -f "$age_key_file" ]] || { echo "ERROR: Missing SOPS age key file: $age_key_file" >&2; exit 1; }
[[ -f "$recipients_file" ]] || { echo "ERROR: Missing SOPS recipients file: $recipients_file" >&2; exit 1; }
[[ -f "$inventory_manager" ]] || { echo "ERROR: Missing inventory manager: $inventory_manager" >&2; exit 1; }
[[ -f "$ssh_key_file" ]] || { echo "ERROR: Missing SSH key file: $ssh_key_file" >&2; exit 1; }
[[ -f "$config_template" ]] || { echo "ERROR: Missing RouterOS config template: $config_template" >&2; exit 1; }

command -v ssh >/dev/null 2>&1 || { echo "ERROR: ssh is required" >&2; exit 1; }
command -v scp >/dev/null 2>&1 || { echo "ERROR: scp is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }
command -v diff >/dev/null 2>&1 || { echo "ERROR: diff is required" >&2; exit 1; }

if [[ -z "$output_dir" ]]; then
  repo_root="$(cd "$(dirname "$inventory_file")/../.." && pwd)"
  output_dir="${repo_root}/state/backups/mikrotik/generated/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$output_dir"
chmod 700 "$output_dir"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${script_dir}/secrets-dotenv.sh"
export PASSWORDS_ENCRYPTED_FILE="$password_file"
export SOPS_AGE_KEY_FILE="$age_key_file"
export SOPS_AGE_RECIPIENTS_FILE="$recipients_file"

password_runtime_file="$(mktemp)"
cleanup() {
  rm -f "$password_runtime_file"
}
trap cleanup EXIT
secrets_dotenv_decrypt_to_file "$password_runtime_file"

read_secret() {
  local key="$1"
  secrets_dotenv_read_value_from_file "$password_runtime_file" "$key" || true
}

missing=()
admin_password="$(read_secret "$admin_password_var")"
backup_password="$(read_secret "$backup_password_var")"
wifi_users_passphrase="$(read_secret "$wifi_users_passphrase_var")"
wifi_mgmt_passphrase="$(read_secret "$wifi_mgmt_passphrase_var")"
wifi_iot_passphrase="$(read_secret "$wifi_iot_passphrase_var")"
wifi_guest_passphrase="$(read_secret "$wifi_guest_passphrase_var")"

[[ -n "$admin_password" ]] || missing+=("$admin_password_var")
[[ -n "$backup_password" ]] || missing+=("$backup_password_var")
[[ -n "$wifi_users_passphrase" ]] || missing+=("$wifi_users_passphrase_var")
[[ -n "$wifi_mgmt_passphrase" ]] || missing+=("$wifi_mgmt_passphrase_var")
[[ -n "$wifi_iot_passphrase" ]] || missing+=("$wifi_iot_passphrase_var")
[[ -n "$wifi_guest_passphrase" ]] || missing+=("$wifi_guest_passphrase_var")

if (( ${#missing[@]} > 0 )); then
  echo "ERROR: Missing required MikroTik configuration secret(s) in SOPS:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "Run: task mikrotik:secrets:ensure" >&2
  echo "Or run task passwords:edit and add the missing values manually." >&2
  exit 1
fi

render_router_config() {
  local router_name="$1"
  local dest_file="$2"
  python3 - "$config_template" "$dest_file" "$router_name" \
    "$admin_password" "$backup_password" "$wifi_users_passphrase" "$wifi_mgmt_passphrase" "$wifi_iot_passphrase" "$wifi_guest_passphrase" <<'PYRENDER'
from pathlib import Path
import re
import sys


def routeros_escape_quoted(value: str) -> str:
    if "\n" in value or "\r" in value:
        raise SystemExit("RouterOS secret values must not contain newlines")
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")


def routeros_can_be_unquoted(value: str) -> bool:
    if value == "":
        return False
    if "\n" in value or "\r" in value:
        raise SystemExit("RouterOS secret values must not contain newlines")
    # Conservative export-compatible rule. Ordinary Wi-Fi punctuation such as
    # ^, &, @, # and % is left unquoted to match RouterOS /export output.
    return re.fullmatch(r'[^\s"\\;$`|<>]+', value) is not None


def routeros_value(value: str) -> str:
    if routeros_can_be_unquoted(value):
        return value
    return '"' + routeros_escape_quoted(value) + '"'


def routeros_on_event_quote(value: str) -> str:
    return '\\"' + routeros_escape_quoted(value) + '\\"'


template = Path(sys.argv[1]).read_text()
output = Path(sys.argv[2])
router_name = sys.argv[3]
values = {
    "__MIKROTIK_ROUTER_IDENTITY__": routeros_value(router_name),
    "__MIKROTIK_ADMIN_PASSWORD__": routeros_value(sys.argv[4]),
    "__MIKROTIK_BACKUP_PASSWORD__": routeros_value(sys.argv[5]),
    "__MIKROTIK_BACKUP_PASSWORD_ON_EVENT__": routeros_on_event_quote(sys.argv[5]),
    "__MIKROTIK_WIFI_USERS_PASSPHRASE__": routeros_value(sys.argv[6]),
    "__MIKROTIK_WIFI_MGMT_PASSPHRASE__": routeros_value(sys.argv[7]),
    "__MIKROTIK_WIFI_IOT_PASSPHRASE__": routeros_value(sys.argv[8]),
    "__MIKROTIK_WIFI_GUEST_PASSPHRASE__": routeros_value(sys.argv[9]),
}
for token, value in values.items():
    template = template.replace(token, value)
leftovers = sorted(set(re.findall(r"__MIKROTIK_[A-Z0-9_]+__", template)))
if leftovers:
    raise SystemExit(f"Unrendered token(s): {', '.join(leftovers)}")
# Keep the uploaded RouterOS export formatting as-is. Do not reflow or normalise
# lines here; the whole point of the plan is to compare RouterOS-export style
# backup files against a proposed RouterOS-export style file.
output.write_text(template if template.endswith("\n") else template + "\n")
PYRENDER
  chmod 600 "$dest_file"
}

safe_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_.-]+/-/g; s/^-+//; s/-+$//'
}

latest_backup_export_for_router() {
  local router_name="$1"
  local backup_root="$2"
  local router_slug=""
  router_slug="$(safe_name "$router_name")"
  if [[ ! -d "$backup_root" ]]; then
    return 1
  fi
  find "$backup_root" \
    -path "${backup_root}/generated" -prune -o \
    -type f -path "*/${router_slug}/${router_slug}-sensitive-*.rsc" -print \
    | sort \
    | tail -n 1
}

backup_root_from_output_dir() {
  local dir="$1"
  local parent=""
  parent="$(dirname "$dir")"
  if [[ "$(basename "$parent")" == "generated" ]]; then
    dirname "$parent"
    return 0
  fi
  dirname "$(dirname "$dir")"
}


routeros_quote_for_command() {
  local value="$1"
  python3 - "$value" <<'PYQUOTE'
import sys
value = sys.argv[1]
if "\n" in value or "\r" in value:
    raise SystemExit("RouterOS secret values must not contain newlines")
value = value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")
print('"' + value + '"')
PYQUOTE
}

backup_password_routeros="$(routeros_quote_for_command "$backup_password")"

redact_routeros_file() {
  local source_file="$1"
  local dest_file="$2"
  python3 - "$source_file" "$dest_file" <<'PYREDACT'
from pathlib import Path
import re
import sys
source = Path(sys.argv[1]).read_text()
patterns = [
    (r'passphrase="(?:\\.|[^"])*"', 'passphrase="REDACTED"'),
    (r'passphrase=[^\s]+', 'passphrase=REDACTED'),
    (r'password="(?:\\.|[^"])*"', 'password="REDACTED"'),
    (r'password=[^\s]+', 'password=REDACTED'),
]
for pattern, replacement in patterns:
    source = re.sub(pattern, replacement, source)
Path(sys.argv[2]).write_text(source)
PYREDACT
  chmod 640 "$dest_file"
}

create_apply_routeros_file() {
  local current_file="$1"
  local desired_file="$2"
  local apply_file="$3"
  python3 - "$current_file" "$desired_file" "$apply_file" <<'PYAPPLY'
from pathlib import Path
import re
import shlex
import sys

current_path = Path(sys.argv[1])
desired_path = Path(sys.argv[2])
apply_path = Path(sys.argv[3])


def join_continuations(text: str) -> list[str]:
    logical: list[str] = []
    buffer = ""
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line:
            if buffer:
                logical.append(buffer)
                buffer = ""
            logical.append("")
            continue
        stripped = line.lstrip()
        if buffer:
            line = stripped
        if line.endswith("\\"):
            buffer += line[:-1]
            continue
        buffer += line
        logical.append(buffer)
        buffer = ""
    if buffer:
        logical.append(buffer)
    return logical


def parse_props(command: str) -> dict[str, str]:
    props: dict[str, str] = {}
    lexer = shlex.shlex(command, posix=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    lexer.escape = "\\"
    try:
        tokens = list(lexer)
    except ValueError:
        tokens = command.split()
    for token in tokens[1:]:
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        props[key] = value.strip('"')
    return props


def add_key(section: str, command: str) -> tuple[str, ...] | None:
    if not command.startswith("add "):
        return None
    props = parse_props(command)

    def prop(name: str) -> str | None:
        value = props.get(name)
        return value if value not in (None, "") else None

    if section == "/interface bridge port":
        value = prop("interface")
        return (section, "interface", value) if value else None
    if section == "/interface bridge vlan":
        bridge = prop("bridge") or ""
        vlan_ids = prop("vlan-ids")
        return (section, bridge, vlan_ids) if vlan_ids else None
    if section == "/interface list member":
        interface = prop("interface")
        list_name = prop("list")
        return (section, interface, list_name) if interface and list_name else None
    if section == "/ip address":
        address = prop("address")
        return (section, address) if address else None
    if section == "/ip dhcp-client":
        interface = prop("interface")
        return (section, interface) if interface else None
    if section == "/ip dhcp-server network":
        address = prop("address")
        return (section, address) if address else None
    if section == "/ip firewall address-list":
        list_name = prop("list")
        address = prop("address")
        return (section, list_name, address) if list_name and address else None
    if section in {"/ip firewall filter", "/ip firewall nat"}:
        chain = prop("chain") or ""
        comment = prop("comment")
        action = prop("action") or ""
        if comment:
            return (section, chain, comment)
        return (section, chain, action, command)
    if section == "/system ntp client servers":
        address = prop("address")
        return (section, address) if address else None
    if section == "/system logging":
        topics = prop("topics")
        return (section, topics) if topics else None

    name = prop("name")
    if name:
        return (section, "name", name)
    return None


def keys_for_export(text: str) -> set[tuple[str, ...]]:
    keys: set[tuple[str, ...]] = set()
    section = ""
    for line in join_continuations(text):
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith(":"):
            continue
        if stripped.startswith("/"):
            section = stripped
            continue
        key = add_key(section, stripped)
        if key:
            keys.add(key)
    return keys


def build_apply(current_text: str, desired_text: str) -> str:
    existing = keys_for_export(current_text)
    output: list[str] = [
        "# ==============================================================================",
        "# File: homelab-router-baseline.apply.rsc",
        "# Purpose:",
        "#   Safe RouterOS apply file generated by the homelab MikroTik workflow.",
        "#   Existing add-only objects are skipped to avoid duplicate import failures.",
        "# ==============================================================================",
        "",
    ]
    section = ""
    skipped = 0
    for line in join_continuations(desired_text):
        stripped = line.strip()
        if not stripped:
            output.append("")
            continue
        if stripped.startswith("#"):
            output.append(stripped)
            continue
        if stripped.startswith("/"):
            section = stripped
            output.append(stripped)
            continue
        key = add_key(section, stripped)
        if key and key in existing:
            skipped += 1
            output.append(f':put "homelab skip existing {section} object {skipped}"')
            continue
        output.append(stripped)
    output.append("")
    output.append(f':put "Homelab RouterOS baseline apply completed; skipped existing add objects: {skipped}"')
    output.append("")
    return "\n".join(output)


apply_path.write_text(build_apply(current_path.read_text(), desired_path.read_text()))
PYAPPLY
  chmod 600 "$apply_file"
}

ssh_common_opts=(-i "$ssh_key_file" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

failures=0
checked=0
completed=0

while IFS='|' read -r name host_group host user connection port keyfile password_var; do
  [[ -n "$name" ]] || continue
  [[ "$host_group" == "$group" ]] || continue
  [[ "$connection" != "local" ]] || continue
  checked=$((checked + 1))

  if [[ -z "$host" || -z "$user" ]]; then
    echo "ERROR: ${name}: inventory host and SSH user are required." >&2
    failures=$((failures + 1))
    continue
  fi
  if [[ -z "$port" || "$port" == "None" ]]; then
    port="22"
  fi

  router_dir="${output_dir}/${name}"
  mkdir -p "$router_dir"
  chmod 700 "$router_dir"
  sensitive_install="${router_dir}/${name}-install.rsc"
  redacted_install="${router_dir}/${name}-install.redacted.rsc"
  apply_install="${router_dir}/${name}-apply.rsc"
  apply_redacted="${router_dir}/${name}-apply.redacted.rsc"
  current_export="${router_dir}/${name}-current.rsc"
  current_redacted="${router_dir}/${name}-current.redacted.rsc"
  sensitive_diff="${router_dir}/${name}-diff.sensitive.patch"
  redacted_diff="${router_dir}/${name}-diff.redacted.patch"
  manifest_file="${router_dir}/manifest.txt"

  render_router_config "$name" "$sensitive_install"
  redact_routeros_file "$sensitive_install" "$redacted_install"
  cat > "$manifest_file" <<EOF_MANIFEST
# ==============================================================================
# File: manifest.txt
# Purpose:
#   Non-secret metadata for generated MikroTik RouterOS desired state.
# ==============================================================================
router=${name}
host=${host}
user=${user}
mode=${mode}
sensitive_install=${sensitive_install}
redacted_install=${redacted_install}
created_at=$(date -Is)
EOF_MANIFEST
  chmod 640 "$manifest_file"

  echo "${name}: rendered RouterOS baseline."
  echo "${name}: redacted review file: ${redacted_install}"

  if [[ "$mode" == "render" ]]; then
    completed=$((completed + 1))
    continue
  fi

  target="${user}@${host}"
  backup_root="$(backup_root_from_output_dir "$output_dir")"
  latest_backup_export="$(latest_backup_export_for_router "$name" "$backup_root")"
  if [[ -z "$latest_backup_export" ]]; then
    echo "ERROR: ${name}: no local MikroTik sensitive backup export found under ${backup_root}." >&2
    echo "       Run task mikrotik:backup before task mikrotik:${mode}." >&2
    failures=$((failures + 1))
    continue
  fi

  echo "${name}: using latest local backup export for plan baseline: ${latest_backup_export}"
  cp "$latest_backup_export" "$current_export"
  chmod 600 "$current_export"
  redact_routeros_file "$current_export" "$current_redacted"
  diff -u "$current_export" "$sensitive_install" > "$sensitive_diff" || true
  chmod 600 "$sensitive_diff"
  diff -u "$current_redacted" "$redacted_install" > "$redacted_diff" || true
  chmod 640 "$redacted_diff"
  echo "${name}: redacted diff: ${redacted_diff}"

  if [[ "$mode" == "plan" ]]; then
    completed=$((completed + 1))
    continue
  fi

  echo "${name}: creating duplicate-safe apply file."
  create_apply_routeros_file "$current_export" "$sensitive_install" "$apply_install"
  redact_routeros_file "$apply_install" "$apply_redacted"
  echo "${name}: redacted apply file: ${apply_redacted}"

  echo "${name}: creating pre-apply RouterOS backup on the router."
  ssh -n "${ssh_common_opts[@]}" -p "$port" "$target" \
    "/system backup save name=pre-homelab-apply password=${backup_password_routeros}" >/dev/null || true

  echo "${name}: uploading duplicate-safe RouterOS apply file to ${target}."
  if ! scp -P "$port" "${ssh_common_opts[@]}" "$apply_install" "${target}:${remote_config_file}" >/dev/null; then
    echo "ERROR: ${name}: failed to upload RouterOS baseline." >&2
    failures=$((failures + 1))
    continue
  fi

  echo "${name}: importing RouterOS baseline configuration."
  if ! ssh -n "${ssh_common_opts[@]}" -p "$port" "$target" "/import file-name=${remote_config_file}"; then
    echo "ERROR: ${name}: RouterOS baseline import failed." >&2
    ssh -n "${ssh_common_opts[@]}" -p "$port" "$target" "/file remove [find where name=\"${remote_config_file}\"]" >/dev/null 2>&1 || true
    failures=$((failures + 1))
    continue
  fi

  ssh -n "${ssh_common_opts[@]}" -p "$port" "$target" "/file remove [find where name=\"${remote_config_file}\"]" >/dev/null 2>&1 || true
  echo "${name}: RouterOS baseline applied."
  completed=$((completed + 1))
done < <(python3 -S "$inventory_manager" list-ssh-hosts --inventory-file "$inventory_file")

if (( checked == 0 )); then
  echo "No MikroTik routers found in inventory group ${group}."
  exit 0
fi

if (( failures > 0 )); then
  echo "ERROR: MikroTik ${mode} failed for ${failures} router(s)." >&2
  exit 1
fi

echo "MikroTik ${mode} completed for ${completed} router(s)."
echo "Output folder: ${output_dir}"
