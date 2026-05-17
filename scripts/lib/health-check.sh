#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/health-check.sh
# Purpose:
#   Shared health, audit, and capability helpers for homelab Taskfiles.
# Notes:
#   - Source this file from Taskfile shell blocks.
#   - Do not print secret values through these helpers.
#   - pipx-installed command paths are supported through HOME/.local/bin.
# ==============================================================================

export PATH="${HOME}/.local/bin:${PATH}"

health_heading() {
  local title="$1"
  local underline=""
  local index=0

  while [[ "$index" -lt "${#title}" ]]; do
    underline="${underline}-"
    index=$((index + 1))
  done

  printf '\n%s\n' "$title"
  printf '%s\n' "$underline"
}

health_status() {
  local status="$1"
  local label="$2"
  local detail="${3:-}"

  if [[ -n "$detail" ]]; then
    printf '%-10s %s: %s\n' "[$status]" "$label" "$detail"
  else
    printf '%-10s %s\n' "[$status]" "$label"
  fi
}

health_ok() { health_status "OK" "$1" "${2:-}"; }
health_missing() { health_status "MISSING" "$1" "${2:-}"; }
health_warn() { health_status "WARN" "$1" "${2:-}"; }
health_fail() { health_status "FAIL" "$1" "${2:-}"; }
health_skip() { health_status "SKIPPED" "$1" "${2:-}"; }
health_optional() { health_status "OPTIONAL" "$1" "${2:-}"; }
health_ready() { health_status "SOPS READY" "$1" "${2:-}"; }
health_locked() { health_status "SOPS LOCKED" "$1" "${2:-}"; }

health_command() {
  local label="$1"
  local command_name="$2"
  shift 2

  if command -v "$command_name" >/dev/null 2>&1; then
    local output
    output="$($@ 2>/dev/null | head -n 1 || true)"
    health_ok "$label" "${output:-installed}"
  else
    health_missing "$label" "$command_name not found"
  fi
}

health_binary_or_pipx() {
  local label="$1"
  local command_name="$2"
  local pipx_package="$3"
  shift 3

  if command -v "$command_name" >/dev/null 2>&1; then
    local output
    output="$($@ 2>/dev/null | head -n 1 || true)"
    health_ok "$label" "${output:-installed}"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1 && python3 -m pipx list 2>/dev/null | grep -Eq "package ${pipx_package}(,| )"; then
    local pipx_bin="${HOME}/.local/bin/${command_name}"
    if [[ -x "$pipx_bin" ]]; then
      local output
      output="$($pipx_bin --version 2>/dev/null | head -n 1 || true)"
      health_ok "$label" "${output:-installed with pipx}"
      return 0
    fi

    health_ok "$label" "installed with pipx; ${command_name} not on PATH"
    return 0
  fi

  health_missing "$label" "$command_name not found and pipx package ${pipx_package} not detected"
  return 1
}

health_file() {
  local label="$1"
  local file_path="$2"

  if [[ -f "$file_path" ]]; then
    health_ok "$label" "$file_path"
  else
    health_missing "$label" "$file_path"
  fi
}

health_optional_file() {
  local label="$1"
  local file_path="$2"

  if [[ -f "$file_path" ]]; then
    health_ok "$label" "$file_path"
  else
    health_optional "$label" "$file_path"
  fi
}

health_sops_status() {
  local label="$1"
  local encrypted_file="$2"
  local age_key_file="${3:-}"

  if [[ ! -f "$encrypted_file" ]]; then
    health_missing "$label" "$encrypted_file"
    return 1
  fi

  if ! command -v sops >/dev/null 2>&1; then
    health_locked "$label" "sops is not installed"
    return 1
  fi

  if [[ -n "$age_key_file" && -f "$age_key_file" ]]; then
    if SOPS_AGE_KEY_FILE="$age_key_file" sops -d "$encrypted_file" >/dev/null 2>&1; then
      health_ready "$label" "$encrypted_file can be decrypted"
      return 0
    fi
  elif sops -d "$encrypted_file" >/dev/null 2>&1; then
    health_ready "$label" "$encrypted_file can be decrypted"
    return 0
  fi

  health_locked "$label" "$encrypted_file exists but cannot be decrypted in this shell"
  return 1
}

health_capability() {
  local label="$1"
  local command_name="$2"
  local detail="${3:-}"

  if command -v "$command_name" >/dev/null 2>&1; then
    health_ok "$label" "${detail:-available}"
  else
    health_missing "$label" "${command_name} unavailable"
  fi
}

health_apt_package() {
  local label="$1"
  local package_name="$2"

  if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status} ${Version}' "$package_name" 2>/dev/null | grep -q '^install ok installed'; then
    local version
    version="$(dpkg-query -W -f='${Version}' "$package_name" 2>/dev/null || true)"
    health_ok "$label" "apt package ${package_name} ${version}"
  else
    health_missing "$label" "apt package ${package_name} not installed"
  fi
}

health_pipx_package() {
  local label="$1"
  local package_name="$2"

  if command -v python3 >/dev/null 2>&1 && python3 -m pipx list 2>/dev/null | grep -Eq "package ${package_name}(,| )"; then
    health_ok "$label" "pipx package ${package_name} installed"
  else
    health_missing "$label" "pipx package ${package_name} not installed"
  fi
}
