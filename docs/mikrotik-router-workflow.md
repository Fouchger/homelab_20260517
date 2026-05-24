# MikroTik RouterOS Workflow

## Purpose

This workflow manages the homelab MikroTik RouterOS 7 router from the local control node.
It combines the current repository inventory, SOPS secret storage, SSH key bootstrap, local backups, and a safer render/plan/apply model.

## Operator flow

Use this sequence for routine changes:

```bash
task mikrotik:bootstrap
task mikrotik:verify
task mikrotik:backup
task mikrotik:render
task mikrotik:plan
task mikrotik:apply
```

`task mikrotik:configure` is an alias for `task mikrotik:apply`.

## What each mode does

`mikrotik:render` renders the desired RouterOS script locally and writes a redacted copy for review. It does not connect to the router.

`mikrotik:plan` renders the desired script from the managed RouterOS export template, copies the latest sensitive backup export created by `task mikrotik:backup`, and writes both sensitive and redacted diffs. It does not re-export live configuration, so the comparison uses the same RouterOS `/export` formatting on both sides.

`mikrotik:apply` runs a fresh local backup, requires confirmation, renders the desired script, creates a duplicate-safe apply script from the latest backup baseline, writes a pre-apply RouterOS backup on the router, uploads the apply script, imports it, and removes the uploaded script.

## Managed RouterOS baseline source

The proposed configuration is stored in the same style as a RouterOS sensitive export:

```text
ansible/roles/mikrotik_router_config/templates/router-baseline.rsc.j2
```

The plan renderer keeps that file formatting as-is and only substitutes SOPS-backed sensitive values, including the admin password, Wi-Fi passphrases, and scheduled backup password. This reduces noisy diffs because both sides of the comparison are RouterOS export-style files.

## Output folders

Generated render, plan, and apply artefacts are stored under:

```text
state/backups/mikrotik/generated/<timestamp>/<router>/
```

Per-router files include:

```text
<router>-install.rsc
<router>-install.redacted.rsc
<router>-current.rsc
<router>-current.redacted.rsc
<router>-diff.sensitive.patch
<router>-diff.redacted.patch
manifest.txt
```

Files containing secrets are written with restrictive permissions.

## Secrets

The workflow reuses the standard SOPS encrypted dotenv file:

```text
state/secrets/passwords/passwords.enc.env
```

Required keys:

```text
MIKROTIK_ADMIN_PASSWORD
MIKROTIK_BACKUP_PASSWORD
MIKROTIK_WIFI_USERS_PASSPHRASE
MIKROTIK_WIFI_MGMT_PASSPHRASE
MIKROTIK_WIFI_IOT_PASSPHRASE
MIKROTIK_WIFI_GUEST_PASSPHRASE
```

Run this to prompt for any missing values:

```bash
task mikrotik:secrets:ensure
```

## Safety notes

Router configuration is high-impact. Always run `task mikrotik:backup`, `task mikrotik:plan`, and `task mikrotik:review` before applying.

For unattended automation only, confirmation can be bypassed with:

```bash
MIKROTIK_APPLY_CONFIRM=APPLY_ALL task mikrotik:apply
```

Do not use the bypass for routine interactive work.

## Review backup versus proposed config

After `task mikrotik:backup` and `task mikrotik:plan`, run:

```bash
task mikrotik:review
```

This compares the latest sensitive RouterOS export captured by `task mikrotik:backup` with the latest proposed rendered baseline from `task mikrotik:plan`. It writes redacted review artefacts below:

```text
state/backups/mikrotik/generated/<timestamp>/review-from-backup/<router>/
```

The key files are:

- `<router>-backup-vs-proposed.side-by-side.redacted.diff`
- `<router>-backup-vs-proposed.redacted.patch`
- `<router>-current-from-backup.redacted.rsc`
- `<router>-proposed.redacted.rsc`

The task opens `vimdiff` for each router so you can compare the redacted backup export against the redacted proposed config in an interactive split view. In `vimdiff`, close the review with `:qa` when finished.

After `vimdiff` closes, the task prompts for explicit approval. If you type `APPLY`, it runs `task mikrotik:apply` and then `task mikrotik:verify`. Any other response stops without changing the router.

If you need non-interactive artefact generation, call `scripts/lib/mikrotik-review.sh` directly with `--no-vimdiff`; the default `task mikrotik:review` is intentionally interactive.
