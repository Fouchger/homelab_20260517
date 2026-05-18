#!/usr/bin/env python3
"""
File: scripts/lib/technitium-inventory-sync.py
Purpose:
  Sync Technitium LXC definitions from config/proxmox-community-lxc.yml into the
  homelab inventory group used by Ansible.
Notes:
  - The parser supports the existing simple repository YAML shape only.
  - This script stores no secrets; SSH key authentication is expected.
"""
from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


def parse_simple_lxc_config(path: Path) -> list[dict[str, str]]:
    current_script = ''
    current_instance = ''
    records: list[dict[str, str]] = []
    current: dict[str, str] = {}

    for raw_line in path.read_text(encoding='utf-8').splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith('#'):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(' '))
        stripped = raw_line.strip()
        if ':' not in stripped:
            continue
        key, raw_value = stripped.split(':', 1)
        key = key.strip()
        value = raw_value.strip().strip('"\'')

        if indent == 0:
            if current_script == 'technitiumdns.sh' and current_instance and current:
                records.append(current)
            current_script = key
            current_instance = ''
            current = {}
            continue

        if current_script != 'technitiumdns.sh':
            continue

        if indent == 2 and not value:
            if current_instance and current:
                records.append(current)
            current_instance = key
            current = {'instance': current_instance}
            continue

        if indent == 4 and current_instance:
            current[key] = value

    if current_script == 'technitiumdns.sh' and current_instance and current:
        records.append(current)

    return records


def strip_cidr(value: str) -> str:
    return value.split('/', 1)[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--config-file', required=True)
    parser.add_argument('--inventory-file', required=True)
    parser.add_argument('--inventory-manager', required=True)
    parser.add_argument('--password-file', required=True)
    parser.add_argument('--recipients-file', required=True)
    args = parser.parse_args()

    config_file = Path(args.config_file)
    records = parse_simple_lxc_config(config_file)
    if not records:
        raise SystemExit(f'ERROR: No technitiumdns.sh definitions found in {config_file}')

    for record in records:
        hostname = record.get('var_hostname') or record['instance']
        ansible_host = strip_cidr(record.get('var_net', ''))
        if not ansible_host:
            raise SystemExit(f'ERROR: Missing var_net for {hostname}')
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', hostname):
            raise SystemExit(f'ERROR: Invalid hostname in Technitium config: {hostname}')

        command = [
            'python3', '-S', args.inventory_manager, 'add-server',
            '--inventory-file', args.inventory_file,
            '--password-file', args.password_file,
            '--recipients-file', args.recipients_file,
            '--group', 'technitiumdns',
            '--hostname', hostname,
            '--ansible-host', ansible_host,
            '--ssh-user', 'root',
            '--vm-lxc-id', record.get('var_ctid', ''),
            '--mac-address', record.get('var_mac', ''),
            '--ssh-port', '22',
            '--python-interpreter', 'auto_silent',
            '--no-password-var',
        ]
        subprocess.run(command, check=True)

    print(f'Synced {len(records)} Technitium DNS host(s) into {args.inventory_file}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
