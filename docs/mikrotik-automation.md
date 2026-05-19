# MikroTik RouterOS automation

This repository manages the MikroTik router through a staged, backup-first workflow.

## Routine setup

Run from the repository root:

```bash
task mikrotik:setup
```

The first run asks for the current RouterOS `admin` password, the same password used for WinBox. The password is stored in the encrypted SOPS password file and is not requested again unless it is missing or forced.

```bash
MIKROTIK_CREDENTIALS_FORCE=1 task mikrotik:credentials
```

## Sequence

The setup task performs the following sequence:

1. Capture or reuse MikroTik credentials in SOPS.
2. Create a sensitive text export and encrypted binary backup.
3. Render a staged RouterOS baseline under `state/generated/routeros/`.
4. Upload the homelab SSH public key when available.
5. Import the staged baseline.
6. Create the `homelab-ansible` automation account.
7. Rotate the `admin` password to the generated SOPS-managed password.
8. Validate SSH/API reachability and DNS settings.

## Backup location

Backups are stored under:

```text
state/backups/mikrotik/
```

These files contain sensitive values. Do not commit or share them.

## Current design

This workflow is intended for the existing RTR-MAIN baseline. It does not factory-reset the router. That is deliberate: the workflow backs up the live router first, then applies idempotent staged changes that keep management access intact.

