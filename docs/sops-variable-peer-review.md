# SOPS and variable peer review

## Scope

Reviewed the `homelab:setup` execution path with focus on SOPS, password-file handling, and shared variable flow.

## Findings fixed

1. The root Taskfile previously defined a repo-local SOPS key under `state/secrets/sops/keys.txt`. This conflicted with the requirement to use the default SOPS age key location.
2. Downstream Technitium tasks prefixed `{{.ROOT_DIR}}/` to the SOPS key path. That is wrong once the key path is absolute/defaulted.
3. `.sops.yaml` generation was too broad and could fail when SOPS was asked to encrypt a file via stdout without a filename context.
4. Multiple downstream scripts encrypted the same password file without `--filename-override`, making them dependent on command context rather than the single shared rule.

## Current standard

- Encrypted password file: `state/secrets/passwords/passwords.enc.env`
- Runtime plaintext file: `state/secrets/passwords/passwords.runtime.env`
- SOPS private age key: `${HOME}/.config/sops/age/keys.txt`
- SOPS recipient cache: `state/secrets/passwords/sops-age-recipient.txt`
- SOPS config: `.sops.yaml`

The recipient cache is not a second key. It is the public recipient derived from the single private age key and is used by non-interactive scripts.

## Execution flow

`homelab:setup` calls `homelab:bootstrap`, which calls `passwords:setup`. The password setup flow now:

1. Installs `sops` and `age`.
2. Creates or reuses `${HOME}/.config/sops/age/keys.txt`.
3. Derives `state/secrets/passwords/sops-age-recipient.txt`.
4. Writes `.sops.yaml` with one rule for `state/secrets/passwords/passwords.enc.env`.
5. Creates or validates the encrypted password file.

All downstream code should consume the root variables only and should not define its own SOPS key path or password file path.
