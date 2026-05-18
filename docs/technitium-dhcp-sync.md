# Technitium DHCP Dynamic DNS Sync

## Purpose

This repository keeps infrastructure DNS records under Ansible control and uses a MikroTik DHCP lease script for dynamic client records.

Static records remain in:

```text
ansible/group_vars/technitiumdns.yml
```

Dynamic DHCP records are created under:

```text
dhcp.fouchger.uk
```

This keeps client leases separate from production infrastructure records.

## Flow

```text
MikroTik DHCP lease event
  -> RouterOS lease script
  -> Technitium primary API at 192.168.30.2:5380
  -> A record in dhcp.fouchger.uk
  -> PTR record in the matching reverse zone
  -> Zone transfer to dns02
```

## Automated Technitium setup

The repository creates and maintains the DHCP sync token without user interaction.

`task technitium:setup` performs this sequence:

1. Ensures the Technitium LXCs exist.
2. Syncs `dns01` and `dns02` into the Ansible inventory.
3. Ensures bootstrap admin credentials exist in SOPS.
4. Configures zones and records through Ansible.
5. Creates or validates the dedicated `mikrotik-ddns` Technitium user.
6. Grants that user view, modify, and delete access to `dhcp.fouchger.uk` and the VLAN reverse zones.
7. Creates a non-expiring API token for the dedicated user and stores it as `TECHNITIUM_DHCP_SYNC_TOKEN` in SOPS.
8. Renders the RouterOS lease script.

No manual Technitium token creation is required. To rotate the token, run:

```bash
TECHNITIUM_DHCP_SYNC_TOKEN_FORCE=1 task technitium:dhcp-sync:token
```

## Render the RouterOS script

```bash
task technitium:dhcp-sync:render
```

The rendered file is written to:

```text
state/generated/routeros/technitium-dhcp-ddns.rsc
```

The rendered file contains the API token and must not be committed.

## Apply on MikroTik

Copy the rendered file to the MikroTik router and run:

```routeros
/import file-name=technitium-dhcp-ddns.rsc
```

## Validate

From a client VLAN, renew a DHCP lease and then test:

```bash
nslookup <hostname>.dhcp.fouchger.uk 192.168.30.2
nslookup <leased-ip> 192.168.30.2
```

Check RouterOS logs for:

```text
Technitium DDNS updated
```

## Notes

The script writes to the primary Technitium server only. Secondary propagation is handled by Technitium zone transfer from dns01 to dns02.

## Ansible layout

Technitium uses the standard repository Ansible layout:

```text
ansible/
  playbooks/technitium.yml
  group_vars/technitiumdns.yml
  roles/technitium_dns/
    defaults/main.yml
    tasks/main.yml
    tasks/bootstrap.yml
    tasks/host_baseline.yml
    tasks/zones.yml
    tasks/secondary.yml
    tasks/validate_dns.yml
    handlers/main.yml
    templates/technitium-backup.sh.j2
    meta/main.yml
```

Keep reusable role defaults in `ansible/roles/technitium_dns/defaults/main.yml` and environment-specific non-secret values in `ansible/group_vars/technitiumdns.yml`.
