#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Filename: scripts/lib/add_shared_drives.sh
# Description: Interactive helper to mount remote SMB shares into an LXC/VM (supports privileged and unprivileged flows).
# Usage:
#   bash scripts/lib/add_shared_drives.sh
# Notes:
#   - Writes fstab entries; review before applying in production.
#   - Designed for repeat runs; can skip or replace existing entries.
# -----------------------------------------------------------------------------
set -Eeuo pipefail
IFS=$'\n\t'

# Print Header
ROOT_DIR="${ROOT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/lib/terminal-colours.sh"
print_section_header "Interactive helper to mount remote SMB shares into an LXC/VM (supports privileged and unprivileged flows)." "PEACH"  

# -----------------------------------------------------------------------------
# Purpose: Detect whether the container is privileged, and only then configure
#          shared CIFS drives + fstab entries.
# Notes:
# - Privileged check: root:root owns /proc (common indicator in LXC).
# - This script expects Debian/Ubuntu with apt available.
# -----------------------------------------------------------------------------

is_privileged_container() {
  local proc_owner
  proc_owner="$(stat -c "%U:%G" /proc 2>/dev/null || true)"

  if [[ "$proc_owner" == "root:root" ]]; then
    return 0
  fi
  return 1
}

shared_drives() {
  # === Prompt for OMV server IP (default applies if blank) ===
  read -rp "Enter OMV server IP (default 192.168.30.20): " omv_ip
  omv_ip="${omv_ip:-192.168.30.20}"

  # === Behaviour choice: skip or replace existing mountpoint entries ===
  read -rp "When a mountpoint already exists in /etc/fstab, do you want to (s)kip or (r)eplace it? [s/r]: " behaviour
  behaviour="${behaviour,,}"

  if [[ "$behaviour" != "s" && "$behaviour" != "r" ]]; then
    echo "Invalid option. Please enter 's' to skip or 'r' to replace."
    exit 1
  fi

  # === Install requirements early ===
  echo "Installing required packages..."
  sudo apt-get update -y
  sudo apt-get install -y cifs-utils

  # === Credentials file (more secure than writing password in fstab) ===
  local cred_file="/etc/samba/omv-cred"
  echo "Setting up CIFS credentials file at ${cred_file}..."
  sudo mkdir -p /etc/samba

  # Only create if it doesn't exist already
  if [[ ! -f "$cred_file" ]]; then
    read -rp "Enter OMV username (default omvuser): " omv_user
    omv_user="${omv_user:-omvuser}"

    read -rsp "Enter OMV password: " omv_pass
    echo

    if [[ -z "${omv_pass:-}" ]]; then
      echo "Password cannot be blank."
      exit 1
    fi

    tmp_cred_file="$(mktemp)"
    cleanup_tmp_cred_file() { rm -f "$tmp_cred_file"; }
    trap cleanup_tmp_cred_file RETURN

    {
      printf 'username=%s\n' "$omv_user"
      printf 'password=%s\n' "$omv_pass"
    } > "$tmp_cred_file"

    sudo install -m 0600 "$tmp_cred_file" "$cred_file"
    echo "Credentials file created."
  else
    echo "Credentials file already exists. Reusing it."
  fi


  # === Prompt for shared drive names ===
  local default_share_names="TB4a, TB5a, TB10a, TB10b, TB16a"

  read -rp "Enter shared drive names, comma separated (default ${default_share_names}): " share_names_input
  share_names_input="${share_names_input:-$default_share_names}"

  declare -A shares=()

  IFS=',' read -ra share_names <<< "$share_names_input"

  for share_name in "${share_names[@]}"; do
    # Trim leading/trailing whitespace
    share_name="$(xargs <<< "$share_name")"

    if [[ -z "$share_name" ]]; then
      continue
    fi

    local mount_point="/mnt/${share_name}"

    shares["$mount_point"]="//${omv_ip}/${share_name} ${mount_point} cifs credentials=${cred_file},uid=1000,gid=1000,iocharset=utf8,_netdev,nofail 0 0"
  done

  create_mount_point() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
      sudo mkdir -p "$dir"
      echo "Created mount point: $dir"
    else
      echo "Mount point exists: $dir"
    fi
  }

  mountpoint_exists_in_fstab() {
    local mount_point="$1"
    awk -v mp="$mount_point" '
      $0 !~ /^[[:space:]]*#/ && NF >= 2 && $2 == mp { found=1 }
      END { exit(found ? 0 : 1) }
    ' /etc/fstab
  }

  add_or_update_fstab_entry() {
    local entry="$1"
    local mount_point
    mount_point="$(awk '{print $2}' <<< "$entry")"

    if mountpoint_exists_in_fstab "$mount_point"; then
      if [[ "$behaviour" == "s" ]]; then
        echo "Skipped (mountpoint already exists in fstab): $mount_point"
        return
      fi

      echo "Replacing existing fstab entry for: $mount_point"
      sudo awk -v mp="$mount_point" -v new="$entry" '
        BEGIN { replaced=0 }
        $0 ~ /^[[:space:]]*#/ || NF < 2 { print; next }
        $2 == mp && !replaced { print new; replaced=1; next }
        $2 == mp && replaced { next }
        { print }
      ' /etc/fstab | sudo tee /etc/fstab >/dev/null

      echo "Updated: $entry"
    else
      echo "$entry" | sudo tee -a /etc/fstab >/dev/null
      echo "Added: $entry"
    fi
  }

  echo "Configuring mount points and /etc/fstab entries..."
  for mount_point in "${!shares[@]}"; do
    create_mount_point "$mount_point"
    add_or_update_fstab_entry "${shares[$mount_point]}"
  done

  echo "Mounting all fstab entries..."
  sudo mount -a

  echo
  echo "Mount validation (showing CIFS mounts):"
  findmnt -t cifs || echo "No CIFS mounts found (check /etc/fstab and network connectivity)."

  echo
  echo "Done."
}

main() {
  if is_privileged_container; then
    echo "Container appears to be PRIVILEGED (Root owns /proc). Proceeding..."
    shared_drives
  else
    echo ""
    echo "------------------------------------------------------------"
    local proc_owner
    proc_owner="$(stat -c "%U:%G" /proc 2>/dev/null || echo "unknown")"
    echo "Container appears to be UNPRIVILEGED (Owner: $proc_owner)."
    echo "Not running CIFS mount configuration."
    echo "If you want this in an unprivileged LXC, you typically need host-side setup (bind mounts) or specific LXC config (nesting, keyctl), depending on your security posture."
    exit 0
  fi
}

main "$@"