#!/usr/bin/env bash
# ==============================================================================
# File: scripts/lib/mikrotik-review.sh
# Purpose:
#   Compare the latest MikroTik backup export with the latest proposed RouterOS
#   baseline render, then optionally approve apply/verify orchestration.
# Notes:
#   - Runs on the local control node only.
#   - Produces redacted review artefacts by default so secrets are not printed.
#   - Exits 0 when the user approves, 20 when the user declines, and 1 on error.
# ==============================================================================
set -euo pipefail

usage() {
  cat <<'EOUSAGE'
Usage: mikrotik-review.sh --backup-dir DIR --generated-dir DIR [--router NAME] [--approval-file FILE] [--vimdiff | --no-vimdiff]

Options:
  --backup-dir DIR       Root backup directory, usually state/backups/mikrotik.
  --generated-dir DIR    Generated config directory, usually state/backups/mikrotik/generated.
  --router NAME          Optional router inventory name to review.
  --approval-file FILE   Optional file to write when the user approves.
  --vimdiff              Open vimdiff for each router review before approval.
  --no-vimdiff           Do not open vimdiff; only write diff artefacts.
EOUSAGE
}

backup_dir=""
generated_dir=""
router_filter=""
approval_file=""
use_vimdiff="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir) backup_dir="$2"; shift 2 ;;
    --generated-dir) generated_dir="$2"; shift 2 ;;
    --router) router_filter="$2"; shift 2 ;;
    --approval-file) approval_file="$2"; shift 2 ;;
    --vimdiff) use_vimdiff="yes"; shift ;;
    --no-vimdiff) use_vimdiff="no"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$backup_dir" ]] || { echo "ERROR: --backup-dir is required" >&2; exit 1; }
[[ -n "$generated_dir" ]] || { echo "ERROR: --generated-dir is required" >&2; exit 1; }
[[ -d "$backup_dir" ]] || { echo "ERROR: Missing MikroTik backup directory: $backup_dir" >&2; exit 1; }
[[ -d "$generated_dir" ]] || { echo "ERROR: Missing MikroTik generated directory: $generated_dir" >&2; exit 1; }

command -v diff >/dev/null 2>&1 || { echo "ERROR: diff is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

vimdiff_available="no"
if command -v vimdiff >/dev/null 2>&1; then
  vimdiff_available="yes"
fi

if [[ "$use_vimdiff" == "auto" ]]; then
  if [[ "$vimdiff_available" == "yes" ]]; then
    use_vimdiff="yes"
  else
    use_vimdiff="no"
  fi
fi

if [[ "$use_vimdiff" == "yes" && "$vimdiff_available" != "yes" ]]; then
  echo "ERROR: --vimdiff was requested, but vimdiff is not installed." >&2
  echo "Install vim or run this task with --no-vimdiff." >&2
  exit 1
fi

safe_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_.-]+/-/g; s/^-+//; s/-+$//'
}

redact_routeros_file() {
  local source_file="$1"
  local dest_file="$2"
  python3 - "$source_file" "$dest_file" <<'PYREDACT'
from pathlib import Path
import re
import sys
source = Path(sys.argv[1]).read_text(errors="replace")
patterns = [
    (r'passphrase="(?:\\.|[^"])*"', 'passphrase="REDACTED"'),
    (r'passphrase=[^\s]+', 'passphrase=REDACTED'),
    (r'password="(?:\\.|[^"])*"', 'password="REDACTED"'),
    (r'password=[^\s]+', 'password=REDACTED'),
    (r'(on-event="[^"]*password=)\\"(?:\\.|[^\\"])*\\"', r'\1\\"REDACTED\\"'),
]
for pattern, replacement in patterns:
    source = re.sub(pattern, replacement, source)
Path(sys.argv[2]).write_text(source)
PYREDACT
  chmod 640 "$dest_file"
}

latest_generated_root="$(find "$generated_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {print $2}')"
if [[ -z "$latest_generated_root" ]]; then
  echo "ERROR: No generated MikroTik plan directory found below: $generated_dir" >&2
  echo "Run: task mikrotik:plan" >&2
  exit 1
fi

review_root="${latest_generated_root}/review-from-backup"
mkdir -p "$review_root"
chmod 700 "$review_root"

approved_count=0
reviewed_count=0
changed_count=0
failed_count=0
summary_file="${review_root}/review-summary.txt"
: > "$summary_file"
chmod 640 "$summary_file"

find_proposed_files() {
  if [[ -n "$router_filter" ]]; then
    find "$latest_generated_root" -mindepth 2 -maxdepth 2 -type f -name "${router_filter}-install.redacted.rsc" -print
  else
    find "$latest_generated_root" -mindepth 2 -maxdepth 2 -type f -name '*-install.redacted.rsc' -print | sort
  fi
}

while IFS= read -r proposed_redacted; do
  [[ -n "$proposed_redacted" ]] || continue
  router_dir="$(dirname "$proposed_redacted")"
  router_name="$(basename "$router_dir")"
  router_slug="$(safe_name "$router_name")"
  proposed_sensitive="${router_dir}/${router_name}-install.rsc"

  if [[ ! -f "$proposed_sensitive" ]]; then
    echo "ERROR: ${router_name}: missing sensitive proposed file: $proposed_sensitive" >&2
    failed_count=$((failed_count + 1))
    continue
  fi

  backup_export="$(find "$backup_dir" -mindepth 3 -maxdepth 3 -type f -path "*/${router_slug}/*.rsc" ! -path "*/generated/*" -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {print $2}')"
  if [[ -z "$backup_export" ]]; then
    echo "ERROR: ${router_name}: no backup export found below ${backup_dir}. Run: task mikrotik:backup" >&2
    failed_count=$((failed_count + 1))
    continue
  fi

  router_review_dir="${review_root}/${router_name}"
  mkdir -p "$router_review_dir"
  chmod 700 "$router_review_dir"

  current_redacted="${router_review_dir}/${router_name}-current-from-backup.redacted.rsc"
  proposed_review="${router_review_dir}/${router_name}-proposed.redacted.rsc"
  unified_diff="${router_review_dir}/${router_name}-backup-vs-proposed.redacted.patch"
  side_by_side="${router_review_dir}/${router_name}-backup-vs-proposed.side-by-side.redacted.diff"
  router_summary="${router_review_dir}/README.txt"

  redact_routeros_file "$backup_export" "$current_redacted"
  cp "$proposed_redacted" "$proposed_review"
  chmod 640 "$proposed_review"

  if diff -u "$current_redacted" "$proposed_review" > "$unified_diff"; then
    has_changes="no"
  else
    has_changes="yes"
    changed_count=$((changed_count + 1))
  fi
  chmod 640 "$unified_diff"

  diff -y --width=220 "$current_redacted" "$proposed_review" > "$side_by_side" || true
  chmod 640 "$side_by_side"

  removed_lines="$(grep -c '^-\([^ -]\|$\)' "$unified_diff" || true)"
  added_lines="$(grep -c '^+\([^ +]\|$\)' "$unified_diff" || true)"

  cat > "$router_summary" <<EOF_SUMMARY
# MikroTik backup versus proposed configuration review

Router: ${router_name}
Latest backup export: ${backup_export}
Latest generated plan: ${latest_generated_root}
Changes found: ${has_changes}
Removed lines: ${removed_lines}
Added lines: ${added_lines}

Review files:
- ${current_redacted}
- ${proposed_review}
- ${unified_diff}
- ${side_by_side}

Notes:
- Review files are redacted and safe for normal terminal review.
- Sensitive source files remain in their original backup/generated folders with restrictive permissions.
EOF_SUMMARY
  chmod 640 "$router_summary"

  {
    echo "Router: ${router_name}"
    echo "  Backup export: ${backup_export}"
    echo "  Proposed file: ${proposed_sensitive}"
    echo "  Changes found: ${has_changes}"
    echo "  Removed lines: ${removed_lines}"
    echo "  Added lines: ${added_lines}"
    echo "  Side-by-side diff: ${side_by_side}"
    echo "  Unified diff: ${unified_diff}"
    echo
  } >> "$summary_file"

  echo "${router_name}: backup-versus-proposed review created."
  echo "  Current redacted file:  ${current_redacted}"
  echo "  Proposed redacted file: ${proposed_review}"
  echo "  Side-by-side diff:     ${side_by_side}"
  echo "  Unified diff:          ${unified_diff}"
  if [[ "$has_changes" == "yes" ]]; then
    echo "  Summary: ${removed_lines} removed line(s), ${added_lines} added line(s)."
  else
    echo "  Summary: no redacted differences detected."
  fi

  if [[ "$use_vimdiff" == "yes" ]]; then
    if { exec 4<>/dev/tty; } 2>/dev/null; then
      echo
      echo "Opening vimdiff for ${router_name}. Close vimdiff with :qa when finished reviewing."
      echo "  Left:  current backup export (redacted)"
      echo "  Right: proposed config (redacted)"
      printf 'Press Enter to open vimdiff, or Ctrl+C to stop: ' >&4
      IFS= read -r _ <&4
      vimdiff "$current_redacted" "$proposed_review" <&4 >&4 2>&4 || true
      exec 4>&- 4<&-
    elif [[ -t 0 && -t 1 ]]; then
      echo
      echo "Opening vimdiff for ${router_name}. Close vimdiff with :qa when finished reviewing."
      echo "  Left:  current backup export (redacted)"
      echo "  Right: proposed config (redacted)"
      printf 'Press Enter to open vimdiff, or Ctrl+C to stop: '
      IFS= read -r _
      vimdiff "$current_redacted" "$proposed_review" || true
    else
      echo "WARNING: No interactive TTY available, so vimdiff was not opened." >&2
    fi
  fi

  reviewed_count=$((reviewed_count + 1))
done < <(find_proposed_files)

if (( reviewed_count == 0 )); then
  echo "ERROR: No proposed redacted install files found below latest generated plan: $latest_generated_root" >&2
  echo "Run: task mikrotik:plan" >&2
  exit 1
fi

if (( failed_count > 0 )); then
  echo "ERROR: Review failed for ${failed_count} router(s)." >&2
  exit 1
fi

echo
echo "MikroTik review summary:"
echo "  Latest generated plan: ${latest_generated_root}"
echo "  Review folder:         ${review_root}"
echo "  Routers reviewed:      ${reviewed_count}"
echo "  Routers with changes:  ${changed_count}"
echo "  Summary file:          ${summary_file}"
echo

if [[ "$use_vimdiff" == "yes" ]]; then
  echo "Review completed in vimdiff. The written diff file(s) are also available above."
else
  echo "Review the side-by-side diff file(s) above before applying."
fi
confirmation=""
if { exec 3<>/dev/tty; } 2>/dev/null; then
  printf 'Apply the proposed MikroTik configuration now? Type APPLY to continue, or anything else to stop: ' >&3
  IFS= read -r confirmation <&3
  exec 3>&- 3<&-
elif [[ -t 0 ]]; then
  printf 'Apply the proposed MikroTik configuration now? Type APPLY to continue, or anything else to stop: '
  IFS= read -r confirmation
else
  if ! IFS= read -r confirmation; then
    echo "ERROR: Interactive approval requires a TTY or stdin response." >&2
    exit 1
  fi
fi

if [[ "$confirmation" != "APPLY" ]]; then
  echo "MikroTik apply cancelled. No router changes were made."
  exit 20
fi

if [[ -n "$approval_file" ]]; then
  mkdir -p "$(dirname "$approval_file")"
  cat > "$approval_file" <<EOF_APPROVAL
approved_at=$(date -Is)
review_root=${review_root}
latest_generated_root=${latest_generated_root}
routers_reviewed=${reviewed_count}
routers_with_changes=${changed_count}
EOF_APPROVAL
  chmod 600 "$approval_file"
fi

echo "MikroTik apply approved."
exit 0
