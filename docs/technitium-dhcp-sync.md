# Technitium DHCP Sync

This document describes the homelab Technitium DNS integration.

## Current design

MikroTik remains the DHCP authority for the VLANs. Technitium is the internal DNS authority and resolver pair:

- `dns01` / primary: `192.168.30.2`
- `dns02` / secondary: `192.168.30.3`

DHCP clients receive the Technitium pair from MikroTik. A generated RouterOS lease script publishes dynamic DHCP A and PTR records to Technitium through the Technitium API.

Dynamic client records are isolated under:

- `dhcp.fouchger.uk`

Static infrastructure records remain managed by Ansible under the primary internal zones.

## Routine command

Run the full setup from the repository root:

```bash
task technitium:setup
```

The task flow:

1. Ensures the Technitium LXC containers exist.
2. Syncs `dns01` and `dns02` into the runtime Ansible inventory.
3. Reuses existing SOPS credentials without prompts.
4. Configures Technitium primary/secondary zones and records.
5. Creates or reuses the dedicated DHCP sync API token.
6. Renders the MikroTik RouterOS DHCP DDNS script.
7. Deploys and imports the RouterOS script over SSH when MikroTik SSH access is available.

## Secrets

Secrets stay in:

```text
state/secrets/passwords/passwords.enc.env
```

Supported MikroTik deployment secrets:

```env
MIKROTIK_HOST=192.168.20.1
MIKROTIK_SSH_USER=admin
MIKROTIK_SSH_PASSWORD=optional_password_for_non_interactive_ssh
```

If `MIKROTIK_SSH_PASSWORD` is absent, the deployment script uses key-based SSH.

## Hardening included

The role includes:

- Ansible fact syntax compatible with future Ansible releases.
- API timeout, retry, and backoff controls.
- DNS validation for forward records, reverse records, recursion, and SOA serial sync.
- Management-only HTTPS reverse proxy on port `5443`.
- Technitium systemd service detection and enablement.
- Lightweight local health checks with optional Uptime Kuma push URL support.
- Automated MikroTik script deployment.
- Disabled-by-default split-horizon DNS scaffold for future internal/public record policy.

## Optional monitoring push

To push health results into Uptime Kuma later, set this non-secret variable in `ansible/group_vars/technitiumdns.yml`:

```yaml
technitium_uptime_kuma_push_url: "https://kuma.example/api/push/example"
```

Keep it blank to write local status only.
