# Homelab

A Taskfile-driven repository for building and operating a personal Proxmox-focused lab environment.

## What this repo contains

```text
.
├── install.sh                                  # Bootstrap installer for Debian/Ubuntu systems
├── Taskfile.yml                                # Root operational entry point
├── taskfile/
│   ├── apps.Taskfile.yml                       # Python, pipx, Ansible, Terraform, and Packer installation
│   ├── github.Taskfile.yml                     # Git and GitHub CLI setup and audit tasks
│   ├── health.Taskfile.yml                     # Consolidated health checks
│   ├── passwords.Taskfile.yml                  # SOPS, age, password, backup, audit, and cleanup tasks
│   ├── env_create.Taskfile.yml                 # Baseline state and SSH inventory creation
│   ├── proxmox.Taskfile.yml                    # Proxmox API bootstrap tasks
│   ├── proxmox_scripts.Taskfile.yml            # Proxmox helper script wrappers
│   └── ssh.Taskfile.yml                        # SSH key, copy-id, and audit tasks
├── scripts/
│   ├── banner/banner.sh                        # Homelab terminal banner
│   └── lib/                                    # Shared shell and Python helpers
├── services/                                   # Helper scripts used by supported tasks
├── state/                                      # Local runtime state; ignored by Git
└── .sops.yaml                                  # Local SOPS rules; generated and ignored by Git
```

## Operating model

`install.sh` prepares or updates the local checkout. `Taskfile.yml` is the control plane after installation. The standard setup flow now runs only:

```bash
task homelab:setup
```

That expands to:

1. `homelab:bootstrap`
2. `homelab:configure`
3. `homelab:validate`

Terraform provisioning, Terraform configuration files, Ansible roles, and Ansible playbooks have been removed. The Ansible and Terraform command-line tools are still installed by the application tooling tasks so they remain available for manual use outside this repository.

## Tooling installation retained

```bash
task apps:setup
task apps:ansible
task apps:terraform
task apps:audit
```

`apps:ansible` installs Ansible with pipx only. It no longer installs Ansible Galaxy roles or collections. `apps:terraform` installs Terraform from the official HashiCorp apt repository only. No repository task runs `ansible`, `ansible-playbook`, `ansible-galaxy`, or `terraform` deployment commands.

## Inventory model

The existing inventory file path is retained for compatibility with SSH and Proxmox helper tasks:

```text
state/ansible/inventory.yml
```

The inventory is now used as an SSH inventory rather than an Ansible execution target. Existing field names such as `ansible_host` are retained to avoid breaking current helper scripts and saved state.

## Secrets model

Secrets are managed with SOPS and age. The main encrypted password file is:

```text
state/secrets/passwords/passwords.enc.env
```

Runtime plaintext files are temporary and should be removed with:

```bash
task passwords:cleanup
```

## Health and validation

```bash
task health:check
task health:capabilities
task health:setup-state
task health:all
```

The health framework checks required files, installed tools, SOPS readiness, and first-run/repeat-run state markers without running Ansible playbooks or Terraform deployments.

## Local state and generated files

The following are expected to be local runtime artefacts and are ignored by Git:

- `state/config/.env`
- `state/ansible/inventory.yml`
- `state/secrets/`
- `state/backups/`
- `.sops.yaml`
- plaintext runtime password files

## Licence

This repository is licensed under GPL-3.0. See `LICENSE`.

## Quick start

Run the installer:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Fouchger/homelab_20260501/main/install.sh)"
```

Then enter the repo and view the safe task list:

```bash
cd ~/app/homelab_20260501
# or, for dev installs:
cd ~/Github/homelab_20260501

task help
```
