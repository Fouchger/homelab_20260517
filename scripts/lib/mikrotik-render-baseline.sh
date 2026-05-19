#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/mikrotik-render-baseline.sh
# Purpose:
#   Render an idempotent staged RouterOS baseline for RTR-MAIN.
# Notes:
#   - The rendered script intentionally contains sensitive values and is written
#     only under ignored state/generated/routeros.
#   - It is safe to re-import on the current router baseline.
# ===============================================================================

set -euo pipefail

ROOT_DIR="${ROOT_DIR:?ROOT_DIR is required}"
PASSWORDS_ENCRYPTED_FILE="${PASSWORDS_ENCRYPTED_FILE:?PASSWORDS_ENCRYPTED_FILE is required}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:?SOPS_AGE_KEY_FILE is required}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/lib/mikrotik-common.sh"

plain_file="$(mktemp)"
trap 'rm -f "$plain_file"' EXIT

decrypt_password_file "$plain_file"
mikrotik_read_connection "$plain_file"

if [[ -z "${MIKROTIK_AUTOMATION_PASSWORD}" || -z "${MIKROTIK_ADMIN_NEW_PASSWORD:-${MIKROTIK_ADMIN_PASSWORD}}" ]]; then
  echo 'ERROR: MikroTik generated passwords are missing. Run: task mikrotik:credentials' >&2
  exit 1
fi

output_dir="${ROOT_DIR}/state/generated/routeros"
output_file="${output_dir}/rtr-main-staged-baseline.rsc"
mkdir -p "$output_dir"
chmod 700 "$output_dir"

automation_password_escaped="$(routeros_escape "${MIKROTIK_AUTOMATION_PASSWORD}")"
admin_new_password_escaped="$(routeros_escape "${MIKROTIK_ADMIN_NEW_PASSWORD:-${MIKROTIK_ADMIN_PASSWORD}}")"
backup_password_escaped="$(routeros_escape "${MIKROTIK_BACKUP_PASSWORD}")"

cat > "$output_file" <<EOFBASE
# ==============================================================================
# File: rtr-main-staged-baseline.rsc
# Purpose: Staged MikroTik RouterOS baseline for homelab RTR-MAIN.
# Warning: This generated file contains sensitive values.
# Generated: $(date -Iseconds)
# ==============================================================================

:log info "HOMELAB: starting staged RouterOS baseline"

/system identity set name=RTR-MAIN
/system clock set time-zone-name=Pacific/Auckland
/system note set note="Production baseline build - VLAN segmented - managed by homelab automation"

/ip dns set allow-remote-requests=yes cache-size=4096KiB servers=192.168.30.2,192.168.30.3

/ip dhcp-server network set [find address=192.168.20.0/24] dns-server=192.168.30.2,192.168.30.3,192.168.20.1 gateway=192.168.20.1
/ip dhcp-server network set [find address=192.168.30.0/24] dns-server=192.168.30.2,192.168.30.3,192.168.30.1 gateway=192.168.30.1
/ip dhcp-server network set [find address=192.168.40.0/24] dns-server=192.168.30.2,192.168.30.3,192.168.40.1 gateway=192.168.40.1
/ip dhcp-server network set [find address=192.168.50.0/24] dns-server=192.168.30.2,192.168.30.3,192.168.50.1 gateway=192.168.50.1
/ip dhcp-server network set [find address=192.168.60.0/24] dns-server=192.168.30.2,192.168.30.3,192.168.60.1 gateway=192.168.60.1
/ip dhcp-server network set [find address=192.168.70.0/24] dns-server=192.168.30.2,192.168.30.3,192.168.70.1 gateway=192.168.70.1
/ip dhcp-server network set [find address=192.168.90.0/24] dns-server=192.168.30.2,192.168.30.3,192.168.90.1 gateway=192.168.90.1

/ip firewall filter set [find comment="DNS to Technitium01 UDP"] dst-address=192.168.30.2 dst-port=53 protocol=udp src-address-list=LANS
/ip firewall filter set [find comment="DNS to Technitium01 TCP"] dst-address=192.168.30.2 dst-port=53 protocol=tcp src-address-list=LANS
/ip firewall filter set [find comment="DNS to Technitium02 UDP"] dst-address=192.168.30.3 dst-port=53 protocol=udp src-address-list=LANS
/ip firewall filter set [find comment="DNS to Technitium02 TCP"] dst-address=192.168.30.3 dst-port=53 protocol=tcp src-address-list=LANS

/ip service set ssh disabled=no address=192.168.20.0/24
/ip service set winbox disabled=no address=192.168.20.0/24
/ip service set www disabled=yes
/ip service set www-ssl disabled=no address=192.168.20.0/24 tls-version=only-1.2
/ip service set api disabled=no address=192.168.20.0/24
/ip service set api-ssl disabled=yes
/ip service set ftp disabled=yes
/ip service set telnet disabled=yes

:if ([:len [/ip firewall filter find comment="HOMELAB MGMT automation SSH/API"]] = 0) do={
  /ip firewall filter add chain=input action=accept in-interface-list=MGMT protocol=tcp dst-port=22,8728,8729 src-address=192.168.20.0/24 comment="HOMELAB MGMT automation SSH/API" place-before=[find comment="Drop WAN to router"]
} else={
  /ip firewall filter set [find comment="HOMELAB MGMT automation SSH/API"] chain=input action=accept in-interface-list=MGMT protocol=tcp dst-port=22,8728,8729 src-address=192.168.20.0/24
}

/user group
:if ([:len [find name="homelab-automation"]] = 0) do={
  add name=homelab-automation policy=local,ssh,reboot,read,write,policy,test,winbox,password,sniff,sensitive,api,romon,rest-api
} else={
  set [find name="homelab-automation"] policy=local,ssh,reboot,read,write,policy,test,winbox,password,sniff,sensitive,api,romon,rest-api
}

/user
:if ([:len [find name="${MIKROTIK_AUTOMATION_USER}"]] = 0) do={
  add name="${MIKROTIK_AUTOMATION_USER}" group=homelab-automation password="${automation_password_escaped}" comment="Homelab Ansible automation account"
} else={
  set [find name="${MIKROTIK_AUTOMATION_USER}"] group=homelab-automation password="${automation_password_escaped}" comment="Homelab Ansible automation account"
}

:if ([:len [/file find name="homelab_ed25519.pub"]] > 0) do={
  :do { /user ssh-keys remove [find user="${MIKROTIK_AUTOMATION_USER}"] } on-error={}
  :do { /user ssh-keys import user="${MIKROTIK_AUTOMATION_USER}" public-key-file=homelab_ed25519.pub } on-error={ :log warning "HOMELAB: SSH public key import failed" }
}

/system ntp client set enabled=yes
:if ([:len [/system ntp client servers find address="time.cloudflare.com"]] = 0) do={ /system ntp client servers add address=time.cloudflare.com }
:if ([:len [/system ntp client servers find address="time.google.com"]] = 0) do={ /system ntp client servers add address=time.google.com }

/system scheduler
:if ([:len [find name="homelab-sensitive-export"]] = 0) do={
  add name=homelab-sensitive-export interval=1d start-time=03:30:00 on-event="/export show-sensitive file=homelab-scheduled-sensitive-export" comment="Daily sensitive text export for local router recovery"
} else={
  set [find name="homelab-sensitive-export"] interval=1d start-time=03:30:00 on-event="/export show-sensitive file=homelab-scheduled-sensitive-export" comment="Daily sensitive text export for local router recovery"
}

:if ([:len [find name="homelab-binary-backup"]] = 0) do={
  add name=homelab-binary-backup interval=1d start-time=03:35:00 on-event="/system backup save name=homelab-scheduled-binary-backup password=\"${backup_password_escaped}\"" comment="Daily encrypted RouterOS binary backup"
} else={
  set [find name="homelab-binary-backup"] interval=1d start-time=03:35:00 on-event="/system backup save name=homelab-scheduled-binary-backup password=\"${backup_password_escaped}\"" comment="Daily encrypted RouterOS binary backup"
}

/user set [find name="${MIKROTIK_ADMIN_USER}"] password="${admin_new_password_escaped}"

:log info "HOMELAB: staged RouterOS baseline completed"
EOFBASE

chmod 600 "$output_file"
echo "Rendered MikroTik staged baseline: ${output_file}"
