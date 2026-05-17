#!/usr/bin/env python3
# ==============================================================================
# File: scripts/lib/env-file-manager.py
# Purpose:
#   Safely update dotenv-style state files used by homelab Task workflows.
# Notes:
#   - This helper preserves existing lines and updates or appends a single key.
#   - Values are written quoted so commas and spaces remain intact.
# ==============================================================================

from __future__ import annotations

import argparse
from pathlib import Path


def quote_dotenv_value(value: str) -> str:
    """Return a double-quoted dotenv-safe value."""
    escaped_value = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped_value}"'


def upsert_value(file_path: Path, key: str, value: str) -> None:
    """Update an existing key or append it when missing."""
    line = f"{key}={quote_dotenv_value(value)}\n"
    lines = file_path.read_text().splitlines(True) if file_path.exists() else []

    updated = False
    for index, existing_line in enumerate(lines):
        if existing_line.startswith(f"{key}="):
            lines[index] = line
            updated = True
            break

    if not updated:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(line)

    file_path.parent.mkdir(parents=True, exist_ok=True)
    file_path.write_text("".join(lines))
    file_path.chmod(0o600)


def main() -> int:
    parser = argparse.ArgumentParser(description="Update a dotenv-style file.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    upsert_parser = subparsers.add_parser("upsert", help="Update or append a key/value pair.")
    upsert_parser.add_argument("--file", required=True, type=Path)
    upsert_parser.add_argument("--key", required=True)
    upsert_parser.add_argument("--value", required=True)

    args = parser.parse_args()

    if args.command == "upsert":
        upsert_value(args.file, args.key, args.value)
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
