#!/usr/bin/env python3
"""
File: scripts/lib/network-discovery.py
Purpose:
  Discover live hosts on a network and compare them with the homelab inventory.
Notes:
  - This script does not modify inventory or secrets.
  - It writes an advisory report that can be used with env_create:inventory:add.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


def inventory_targets(inventory_file: Path) -> set[str]:
    if not inventory_file.is_file():
        return set()
    targets: set[str] = set()
    for line in inventory_file.read_text(encoding='utf-8', errors='ignore').splitlines():
        match = re.match(r'\s*ansible_host:\s*["\']?([^"\'\s#]+)', line)
        if match:
            targets.add(match.group(1))
    return targets


def run_nmap(cidr: str) -> str:
    try:
        result = subprocess.run(
            ['nmap', '-sn', cidr],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except FileNotFoundError:
        raise SystemExit('ERROR: nmap is not installed. Run: task apps:prerequisites')

    if result.returncode != 0:
        raise SystemExit(result.stdout.strip() or f'ERROR: nmap failed for {cidr}')
    return result.stdout


def parse_nmap(output: str) -> list[dict[str, str]]:
    hosts: list[dict[str, str]] = []
    current: dict[str, str] | None = None

    for line in output.splitlines():
        report = re.match(r'Nmap scan report for\s+(.+)$', line.strip())
        if report:
            if current:
                hosts.append(current)
            value = report.group(1).strip()
            name = ''
            address = value
            bracketed = re.match(r'(.+)\s+\(([^)]+)\)$', value)
            if bracketed:
                name = bracketed.group(1).strip()
                address = bracketed.group(2).strip()
            current = {'name': name, 'address': address, 'mac': ''}
            continue

        mac = re.match(r'MAC Address:\s+([0-9A-Fa-f:]{17})\s*(.*)$', line.strip())
        if mac and current is not None:
            current['mac'] = mac.group(1).lower()

    if current:
        hosts.append(current)
    return hosts


def write_report(report_file: Path, cidr: str, hosts: list[dict[str, str]], known_targets: set[str]) -> None:
    report_file.parent.mkdir(parents=True, exist_ok=True)
    with report_file.open('w', encoding='utf-8') as handle:
        handle.write('Network discovery report\n')
        handle.write('========================\n\n')
        handle.write(f'CIDR: {cidr}\n')
        handle.write(f'Live hosts found: {len(hosts)}\n')
        handle.write(f'Inventory targets known: {len(known_targets)}\n\n')
        handle.write(f'{"Status":<12} {"Address":<18} {"MAC":<20} Name\n')
        handle.write(f'{"------":<12} {"-------":<18} {"---":<20} ----\n')
        for host in hosts:
            status = 'KNOWN' if host['address'] in known_targets else 'NEW'
            handle.write(f'{status:<12} {host["address"]:<18} {host["mac"] or "-":<20} {host["name"] or "-"}\n')


def print_summary(report_file: Path, hosts: list[dict[str, str]], known_targets: set[str]) -> None:
    print('\nNetwork discovery')
    print('-----------------')
    print(f'Live hosts found: {len(hosts)}')
    new_hosts = [host for host in hosts if host['address'] not in known_targets]
    print(f'New hosts not in inventory: {len(new_hosts)}')
    print(f'Report: {report_file}')
    if new_hosts:
        print('\nSuggested next step:')
        print('  task env_create:inventory:add')


def main() -> int:
    parser = argparse.ArgumentParser(description='Discover live network hosts and compare with inventory.')
    parser.add_argument('--cidr', required=True, help='CIDR to scan, for example 192.168.20.0/24')
    parser.add_argument('--inventory-file', required=True)
    parser.add_argument('--report-file', required=True)
    args = parser.parse_args()

    inventory_file = Path(args.inventory_file)
    report_file = Path(args.report_file)
    known_targets = inventory_targets(inventory_file)
    output = run_nmap(args.cidr)
    hosts = parse_nmap(output)
    write_report(report_file, args.cidr, hosts, known_targets)
    print_summary(report_file, hosts, known_targets)
    return 0


if __name__ == '__main__':
    sys.exit(main())
