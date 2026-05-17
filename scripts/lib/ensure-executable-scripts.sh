#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Filename: scripts/lib/ensure-executable-scripts.sh
# Description: Ensure all shell scripts and key entrypoints in the current repo are executable.
# Usage:
#   bash scripts/lib/ensure-executable-scripts.sh
# Notes:
#   - Runs in the current working directory by default; uses the git root if detected.
#   - Idempotent and safe to re-run.
# -----------------------------------------------------------------------------
set -Eeuo pipefail
IFS=$'\n\t'

# Print Header
ROOT_DIR="${ROOT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/lib/terminal-colours.sh"
print_section_header "Ensure all shell scripts and key entrypoints in the current repo are executable." "PEACH"  

# Resolve repo root (prefer git when available)
if git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  BASE_DIR="$git_root"
else
  BASE_DIR="$(pwd)"
fi

echo "Working directory: $BASE_DIR"

# 1) Make all *.sh files executable (recursive)
echo "Making all *.sh files executable..."
while IFS= read -r -d '' file; do
  chmod +x "$file"
  echo "  chmod +x $file"
done < <(find "$BASE_DIR" -type f -name "*.sh" -print0)

# 2) Make key Python entrypoints executable (if present)
TARGETS=(
  "$BASE_DIR/install.sh"
)

echo "Making target entrypoint scripts executable (if they exist)..."
for target in "${TARGETS[@]}"; do
  if [[ -f "$target" ]]; then
    chmod +x "$target"
    echo "  chmod +x $target"
  else
    echo "  Skipped (not found): $target"
  fi
done

echo "Done."