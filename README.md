# Homelab

Homelab is a Taskfile-driven control-plane repository for building and operating a personal Proxmox-focused lab environment.

The repository is designed around a simple operating model: `install.sh` bootstraps or updates the repo, then `Taskfile.yml` becomes the main entry point for day-to-day setup and maintenance.

## What this repo contains

```text
.
├── install.sh                                  # Bootstrap installer for Debian/Ubuntu systems
```

## Operating model

This repo separates bootstrap, orchestration, secrets, and service helpers.

## Supported environment

The bootstrap flow is currently intended for Debian/Ubuntu-family systems.

The default target environments are:

- `prod` → `~/app/homelab_20260501`
- `dev` → `~/Github/homelab_20260501`

The installer supports environment overrides such as `SETUP`, `TARGET_DIR`, `HOMELAB_BRANCH`, `HOMELAB_GIT_PROTOCOL`, and `NONINTERACTIVE`.

## Quick start

Run the installer:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Fouchger/homelab_20260517/main/install.sh)"
```

## Common tasks


## Licence

This repository is licensed under GPL-3.0. See `LICENSE`.

## Operational health and capabilities

