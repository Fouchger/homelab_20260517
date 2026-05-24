#!/usr/bin/env python3
"""
File: scripts/lib/inventory-manager.py
Purpose:
  Manage the homelab SSH inventory for Taskfile tasks.
Notes:
  - This script may create or update the SSH inventory file.
  - This script must never create or recreate state/config/.env.
  - This script must never create or recreate passwords.enc.env.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import TextIO


def terminal() -> TextIO:
    try:
        return open('/dev/tty', 'r+', encoding='utf-8')
    except OSError:
        return sys.stdin


def prompt_line(handle: TextIO, text: str) -> str:
    output = handle if handle.writable() else sys.stdout
    print(text, end='', file=output, flush=True)
    return handle.readline().strip()


def prompt_required(handle: TextIO, label: str) -> str:
    while True:
        value = prompt_line(handle, f'{label}: ')
        if value:
            return value


def prompt_optional(handle: TextIO, label: str, default: str = '') -> str:
    suffix = f' [{default}]' if default else ''
    value = prompt_line(handle, f'{label}{suffix}: ')
    return value or default


def prompt_count(handle: TextIO) -> int:
    while True:
        value = prompt_optional(handle, 'Number of servers to add', '1')
        if value.isdigit() and int(value) > 0:
            return int(value)
        output = handle if handle.writable() else sys.stdout
        print('Please enter a whole number greater than zero.', file=output)


def env_var_from_hostname(hostname: str) -> str:
    value = re.sub(r'[^A-Z0-9_]', '_', f'{hostname}_SSH_PASSWORD'.upper())
    if re.match(r'^[0-9]', value):
        value = f'_{value}'
    return value


def lxc_root_password_var_from_hostname(hostname: str) -> str:
    value = re.sub(r'[^A-Z0-9_]', '_', f'{hostname}_LXC_ROOT_PASSWORD'.upper())
    if re.match(r'^[0-9]', value):
        value = f'_{value}'
    return value


def validate_name(label: str, value: str) -> None:
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', value):
        raise SystemExit(f'ERROR: {label} may only contain letters, numbers, underscore, dot, and dash.')


def validate_env_var(value: str) -> None:
    if value and not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', value):
        raise SystemExit('ERROR: SSH password variable must be a valid environment variable name.')


def validate_mac(value: str) -> None:
    if value and not re.fullmatch(r'([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}|[0-9A-Fa-f]{12}', value):
        raise SystemExit('ERROR: MAC address must be blank or a valid 12-digit MAC address.')


def validate_connection_target(value: str) -> None:
    if not value:
        raise SystemExit('ERROR: SSH IP address / DNS name is required.')
    if not re.fullmatch(r'[A-Za-z0-9_.:-]+', value):
        raise SystemExit('ERROR: SSH IP address / DNS name may only contain letters, numbers, underscore, dot, dash, and colon.')


def looks_like_env_var(value: str) -> bool:
    return bool(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', value or ''))


def dotenv_quote(value: str) -> str:
    escaped = value.replace('\\', '\\\\').replace('"', '\\"')
    return f'"{escaped}"'


def read_secret(handle: TextIO, prompt: str) -> str:
    output = handle if handle.writable() else sys.stdout
    print(f'{prompt}: ', end='', file=output, flush=True)
    if getattr(handle, 'name', '') == '/dev/tty':
        try:
            subprocess.run(['stty', '-echo'], stdin=handle, check=False)
            value = handle.readline().rstrip('\n')
        finally:
            subprocess.run(['stty', 'echo'], stdin=handle, check=False)
            print('', file=output, flush=True)
        return value
    return handle.readline().strip()


def command_exists(command: str) -> bool:
    for directory in os.environ.get('PATH', '').split(os.pathsep):
        candidate = Path(directory) / command
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return True
    return False


def encrypted_password_file_is_ready(password_file: Path) -> bool:
    if not password_file.is_file():
        return False
    try:
        first_chunk = password_file.read_text(encoding='utf-8', errors='ignore')[:2048]
    except OSError:
        return False
    return bool(re.search(r'^(sops_|sops:)', first_chunk, re.MULTILINE))


def save_password_value(password_file: Path, recipients_file: Path, age_key_file: Path, key: str, value: str) -> bool:
    if not value:
        return False
    if not looks_like_env_var(key):
        raise SystemExit('ERROR: SSH password variable must be a valid environment variable name.')
    if not encrypted_password_file_is_ready(password_file):
        print(f'WARNING: Encrypted password file is not ready: {password_file}', file=sys.stderr)
        print('         The inventory will reference the variable only. No password file was created.', file=sys.stderr)
        return False
    if not recipients_file.is_file():
        print(f'WARNING: Missing SOPS recipient file: {recipients_file}', file=sys.stderr)
        print('         The inventory will reference the variable only. No password file was created.', file=sys.stderr)
        return False
    if not age_key_file.is_file():
        print(f'WARNING: Missing SOPS age key file: {age_key_file}', file=sys.stderr)
        print('         The inventory will reference the variable only. No password file was created.', file=sys.stderr)
        return False
    if not command_exists('sops'):
        print('WARNING: sops is not installed. The inventory will reference the variable only.', file=sys.stderr)
        return False

    recipient = recipients_file.read_text(encoding='utf-8').strip()
    if not recipient:
        print(f'WARNING: SOPS recipient file is blank: {recipients_file}', file=sys.stderr)
        return False

    runtime_fd, runtime_name = tempfile.mkstemp()
    encrypted_fd, encrypted_name = tempfile.mkstemp()
    os.close(runtime_fd)
    os.close(encrypted_fd)
    runtime_path = Path(runtime_name)
    encrypted_path = Path(encrypted_name)

    try:
        sops_env = dict(os.environ)
        sops_env['SOPS_AGE_KEY_FILE'] = str(age_key_file)
        decrypt = subprocess.run(
            ['sops', '--decrypt', '--input-type', 'dotenv', '--output-type', 'dotenv', str(password_file)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env=sops_env,
        )
        if decrypt.returncode != 0:
            print('WARNING: Unable to decrypt the encrypted password file. The inventory will reference the variable only.', file=sys.stderr)
            return False

        lines = [line for line in decrypt.stdout.splitlines() if not line.startswith(f'{key}=')]
        lines.append(f'{key}={dotenv_quote(value)}')
        runtime_path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        os.chmod(runtime_path, 0o600)

        with encrypted_path.open('w', encoding='utf-8') as output_handle:
            encrypt = subprocess.run(
                ['sops', '--encrypt', '--age', recipient, '--filename-override', str(password_file), '--input-type', 'dotenv', '--output-type', 'dotenv', str(runtime_path)],
                stdout=output_handle,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                env=sops_env,
            )
        if encrypt.returncode != 0:
            print('WARNING: Unable to update the encrypted password file. The inventory will reference the variable only.', file=sys.stderr)
            return False

        # Intentionally write into the existing file path. This task never creates
        # the encrypted password file; passwords.Taskfile.yml owns creation.
        password_file.write_text(encrypted_path.read_text(encoding='utf-8'), encoding='utf-8')
        os.chmod(password_file, 0o600)
        return True
    finally:
        for path in (runtime_path, encrypted_path):
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def split_suffix(value: str) -> tuple[str, str, str]:
    match = re.match(r'^(.*?)(\d+)([^\d]*)$', value)
    if not match:
        return value, '', ''
    return match.group(1), match.group(2), match.group(3)


def increment_numeric_string(value: str, offset: int) -> str:
    if not value:
        return ''
    if not value.isdigit():
        return value if offset == 0 else ''
    return str(int(value) + offset).zfill(len(value))


def increment_host(value: str, offset: int) -> str:
    prefix, number, suffix = split_suffix(value)
    if not number:
        return value if offset == 0 else f'{value}-{offset + 1}'
    return f'{prefix}{str(int(number) + offset).zfill(len(number))}{suffix}'


def increment_env_var(value: str, offset: int) -> str:
    if not value:
        return ''
    return re.sub(r'[^A-Z0-9_]', '_', increment_host(value, offset).upper())


def increment_mac(value: str, offset: int) -> str:
    if not value:
        return ''
    clean = re.sub(r'[^0-9A-Fa-f]', '', value)
    if len(clean) != 12 or not re.fullmatch(r'[0-9A-Fa-f]{12}', clean):
        return value if offset == 0 else ''
    number = (int(clean, 16) + offset) % (1 << 48)
    hex_value = f'{number:012x}'
    return ':'.join(hex_value[index:index + 2] for index in range(0, 12, 2))


def increment_connection_target(value: str, offset: int) -> str:
    if not value:
        return ''
    ipv4_match = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)\.(\d+)', value)
    if ipv4_match:
        octets = [int(part) for part in ipv4_match.groups()]
        number = (octets[0] << 24) + (octets[1] << 16) + (octets[2] << 8) + octets[3] + offset
        if number < 0 or number > 0xFFFFFFFF:
            return value if offset == 0 else ''
        return '.'.join(str((number >> shift) & 255) for shift in (24, 16, 8, 0))
    return increment_host(value, offset)


def host_reachable(hostname: str) -> bool:
    lookup = subprocess.run(
        ['getent', 'hosts', hostname],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=1,
    )
    if lookup.returncode != 0:
        return False
    probe = subprocess.run(
        ['ping', '-c', '1', '-W', '1', hostname],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=2,
    )
    return probe.returncode == 0


def scalar(value: str) -> str:
    value = value.strip()
    if value == '':
        return ''
    if value.startswith('{{') and value.endswith('}}'):
        return '"' + value.replace('"', '\\"') + '"'
    if re.fullmatch(r'[A-Za-z0-9_./:@+-]+', value):
        return value
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def parse_inventory(text: str) -> tuple[dict[str, dict[str, str]], dict[str, dict[str, dict[str, str]]]]:
    root_hosts: dict[str, dict[str, str]] = {}
    groups: dict[str, dict[str, dict[str, str]]] = {}
    current_root_host: str | None = None
    current_group: str | None = None
    current_group_host: str | None = None
    in_root_hosts = False
    in_children = False
    in_group_hosts = False

    for raw_line in text.splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith('#'):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(' '))
        stripped = raw_line.strip()
        if ':' not in stripped:
            continue
        key, raw_value = stripped.split(':', 1)
        key = key.strip().strip('"\'')
        value = raw_value.strip().strip('"\'')

        if indent == 0 and key == 'all':
            in_root_hosts = False
            in_children = False
            in_group_hosts = False
            current_root_host = None
            current_group = None
            current_group_host = None
            continue
        if indent == 2 and key == 'hosts':
            in_root_hosts = True
            in_children = False
            in_group_hosts = False
            current_root_host = None
            continue
        if indent == 2 and key == 'children':
            in_root_hosts = False
            in_children = True
            in_group_hosts = False
            current_group = None
            current_group_host = None
            continue
        if in_root_hosts and indent == 4 and value == '':
            current_root_host = key
            root_hosts.setdefault(current_root_host, {})
            continue
        if in_root_hosts and indent == 6 and current_root_host:
            root_hosts[current_root_host][key] = value
            continue
        if in_children and indent == 4 and value == '':
            current_group = key
            groups.setdefault(current_group, {})
            in_group_hosts = False
            current_group_host = None
            continue
        if in_children and current_group and indent == 6 and key == 'hosts':
            in_group_hosts = True
            current_group_host = None
            continue
        if in_children and current_group and in_group_hosts and indent == 8 and value == '':
            current_group_host = key
            groups.setdefault(current_group, {}).setdefault(current_group_host, {})
            continue
        if in_children and current_group and current_group_host and indent == 10:
            groups[current_group][current_group_host][key] = value
            continue
    return root_hosts, groups


def write_inventory(inventory_file: Path, root_hosts: dict[str, dict[str, str]], groups: dict[str, dict[str, dict[str, str]]]) -> None:
    lines: list[str] = ['all:', '  hosts:']
    for host_name in sorted(root_hosts):
        lines.append(f'    {host_name}:')
        for key, value in root_hosts[host_name].items():
            lines.append(f'      {key}: {scalar(value)}')
    if groups:
        lines.append('  children:')
        for group_name in sorted(groups):
            lines.append(f'    {group_name}:')
            lines.append('      hosts:')
            for host_name in sorted(groups[group_name]):
                lines.append(f'        {host_name}:')
                for key, value in groups[group_name][host_name].items():
                    lines.append(f'          {key}: {scalar(value)}')
    else:
        lines.append('  children: {}')
    inventory_file.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    os.chmod(inventory_file, 0o600)


def read_inventory(inventory_file: Path) -> tuple[dict[str, dict[str, str]], dict[str, dict[str, dict[str, str]]]]:
    existing_text = inventory_file.read_text(encoding='utf-8') if inventory_file.exists() else ''
    root_hosts, groups = parse_inventory(existing_text)
    if not root_hosts:
        root_hosts['local'] = {
            'ansible_host': '127.0.0.1',
            'ansible_connection': 'local',
            'ansible_user': os.environ.get('USER', 'root'),
            'ansible_port': '22',
        }
    return root_hosts, groups


def add_servers(args: argparse.Namespace, interactive: bool) -> None:
    inventory_file = Path(args.inventory_file)
    password_file = Path(args.password_file)
    recipients_file = Path(args.recipients_file)
    age_key_file = Path(getattr(args, 'age_key_file', '') or os.environ.get('SOPS_AGE_KEY_FILE', ''))

    if interactive:
        tty = terminal()
        group = prompt_required(tty, 'Group')
        server_count = prompt_count(tty)
        first_vm_lxc_id = prompt_optional(tty, 'First VM/LXC container ID (blank for physical servers and routers)')
        first_hostname = prompt_required(tty, 'First hostname')
        first_ansible_host = prompt_required(tty, 'First SSH IP address / DNS name')
        first_mac_address = prompt_optional(tty, 'First MAC address')
        ssh_user = prompt_required(tty, 'SSH username')
        default_password_var = env_var_from_hostname(first_hostname)
        first_ssh_password_var = prompt_optional(
            tty,
            'SSH password variable name in state/secrets/passwords/passwords.enc.env',
            default_password_var,
        )
        first_ssh_password_value = ''
        if first_ssh_password_var:
            first_ssh_password_value = read_secret(
                tty,
                f'SSH password value for {first_ssh_password_var} (blank to only reference existing variable)',
            )
        python_interpreter = prompt_optional(tty, 'Python interpreter', 'auto_silent')
        ssh_port = '22'
        check_network = True
    else:
        group = args.group
        server_count = 1
        first_vm_lxc_id = args.vm_lxc_id or ''
        first_hostname = args.hostname
        first_ansible_host = args.ansible_host or args.hostname
        first_mac_address = args.mac_address or ''
        ssh_user = args.ssh_user
        first_ssh_password_var = '' if args.no_password_var else (args.ssh_password_var or env_var_from_hostname(first_hostname))
        first_ssh_password_value = os.environ.get(args.ssh_password_value_env, '') if args.ssh_password_value_env else ''
        python_interpreter = args.python_interpreter or 'auto_silent'
        ssh_port = args.ssh_port or '22'
        check_network = False

    validate_name('Group', group)
    validate_name('Hostname', first_hostname)
    validate_connection_target(first_ansible_host)
    validate_env_var(first_ssh_password_var)
    validate_mac(first_mac_address)

    root_hosts, groups = read_inventory(inventory_file)
    all_inventory_hosts = set(root_hosts)
    all_inventory_targets = {values.get('ansible_host', name) for name, values in root_hosts.items()}
    for group_hosts in groups.values():
        all_inventory_hosts.update(group_hosts)
        for name, values in group_hosts.items():
            all_inventory_targets.add(values.get('ansible_host', name))

    report: list[tuple[str, str, str]] = []
    added = 0
    groups.setdefault(group, {})

    for offset in range(server_count):
        hostname = increment_host(first_hostname, offset)
        ansible_host = increment_connection_target(first_ansible_host, offset)
        vm_lxc_id = increment_numeric_string(first_vm_lxc_id, offset)
        mac_address = increment_mac(first_mac_address, offset)
        ssh_password_var = increment_env_var(first_ssh_password_var, offset)

        existing_server = None
        existing_location = ''
        if hostname in root_hosts:
            existing_server = root_hosts[hostname]
            existing_location = 'root'
        elif hostname in groups.get(group, {}):
            existing_server = groups[group][hostname]
            existing_location = group

        if existing_server is None and ansible_host in all_inventory_targets:
            report.append(('SKIPPED', hostname, f'connection target {ansible_host} already exists in inventory under another hostname'))
            continue

        network_status = 'not checked'
        if check_network:
            network_status = 'reachable' if host_reachable(ansible_host) else 'unreachable'

        server = {
            'ansible_host': ansible_host,
            'ansible_user': ssh_user,
            'ansible_port': ssh_port,
            'ansible_ssh_private_key_file': os.environ.get('HOMELAB_SSH_KEY_FILE', '~/.ssh/homelab_ed25519'),
            'ansible_python_interpreter': python_interpreter,
        }
        if vm_lxc_id:
            server['homelab_vm_lxc_id'] = vm_lxc_id
        if mac_address:
            server['homelab_mac_address'] = mac_address
        if getattr(args, 'device_type', ''):
            server['homelab_device_type'] = args.device_type
        if getattr(args, 'automation_user', ''):
            server['homelab_automation_user'] = args.automation_user
        password_saved = False
        if ssh_password_var:
            if first_ssh_password_value and offset == 0:
                password_saved = save_password_value(password_file, recipients_file, age_key_file, ssh_password_var, first_ssh_password_value)
                if not password_saved and getattr(args, 'require_password_save', False):
                    raise SystemExit('ERROR: Password value was entered but could not be saved to the encrypted password file. Run: task passwords:setup, then retry task mikrotik:inventory:add.')
            server['ansible_password'] = "{{ lookup('env', '" + ssh_password_var + "') }}"
            server['homelab_ssh_password_var'] = ssh_password_var

        detail = f'ansible_host={ansible_host}, group={group}, network={network_status}, vm_lxc_id={vm_lxc_id or "-"}, mac={mac_address or "-"}, password_var={ssh_password_var or "-"}, password_saved={"yes" if password_saved else "no"}'

        if existing_server is not None:
            current_server = dict(existing_server)
            target_already_matches = existing_location == group and current_server == server
            if target_already_matches:
                all_inventory_targets.add(ansible_host)
                report.append(('SKIPPED', hostname, f'{detail}, reason=already matches inventory'))
                continue

            if existing_location != group and hostname in root_hosts:
                del root_hosts[hostname]
            groups[group][hostname] = server
            all_inventory_targets.add(ansible_host)
            added += 1
            report.append(('UPDATED', hostname, detail))
        else:
            groups[group][hostname] = server
            all_inventory_hosts.add(hostname)
            all_inventory_targets.add(ansible_host)
            added += 1
            report.append(('ADDED', hostname, detail))

    if added:
        write_inventory(inventory_file, root_hosts, groups)

    print('\nInventory add report')
    print('--------------------')
    for status, hostname, detail in report:
        print(f'{status:7} {hostname:30} {detail}')
    print(f'\nInventory file: {inventory_file}')
    print(f'Password file: {password_file} (updated through SOPS when a password value is supplied)')
    print(f'Servers requested: {server_count}; changed: {added}; skipped: {server_count - added}')





def strip_cidr(value: str) -> str:
    return (value or '').split('/', 1)[0].strip()


def iter_inventory_hosts(root_hosts: dict[str, dict[str, str]], groups: dict[str, dict[str, dict[str, str]]]):
    seen: set[tuple[str, str]] = set()
    for host_name, values in root_hosts.items():
        key = (host_name, values.get('ansible_host', host_name))
        if key not in seen:
            seen.add(key)
            yield host_name, '', values
    for group_name, group_hosts in groups.items():
        for host_name, values in group_hosts.items():
            key = (host_name, values.get('ansible_host', host_name))
            if key in seen:
                continue
            seen.add(key)
            yield host_name, group_name, values


def list_ssh_hosts(args: argparse.Namespace) -> None:
    inventory_file = Path(args.inventory_file)
    if not inventory_file.is_file():
        raise SystemExit(f'ERROR: Missing inventory file: {inventory_file}')

    root_hosts, groups = read_inventory(inventory_file)
    for host_name, group_name, values in iter_inventory_hosts(root_hosts, groups):
        host = values.get('ansible_host', host_name)
        user = values.get('ansible_user', '')
        connection = values.get('ansible_connection', 'ssh')
        port = values.get('ansible_port', '22')
        keyfile = values.get('ansible_ssh_private_key_file', '')
        password_var = values.get('homelab_ssh_password_var', '')
        if not password_var:
            match = re.search(r"lookup\('env', '([^']+)'\)", values.get('ansible_password', ''))
            if match:
                password_var = match.group(1)
        print('|'.join([host_name, group_name, host, user, connection, port, keyfile, password_var]))

def key_auth_works(host_values: dict[str, str], key_file: str) -> tuple[bool, str]:
    connection = host_values.get('ansible_connection', 'ssh')
    if connection == 'local':
        return True, 'local'

    host = host_values.get('ansible_host', '')
    user = host_values.get('ansible_user', '')
    port = host_values.get('ansible_port', '22')
    if not host:
        return False, 'missing ansible_host'

    target = f'{user}@{host}' if user else host
    command = [
        'ssh',
        '-i', key_file,
        '-p', port,
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=5',
        '-o', 'StrictHostKeyChecking=accept-new',
        target,
        'true',
    ]
    result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if result.returncode == 0:
        return True, f'key auth works for {target}'
    return False, f'key auth failed for {target}'


def normalise_auth(args: argparse.Namespace) -> None:
    inventory_file = Path(args.inventory_file)
    key_file = args.ssh_key_file
    if not inventory_file.is_file():
        raise SystemExit(f'ERROR: Missing inventory file: {inventory_file}')
    if not Path(key_file).is_file():
        raise SystemExit(f'ERROR: Missing SSH private key: {key_file}')

    root_hosts, groups = read_inventory(inventory_file)
    changed = False
    report: list[tuple[str, str, str]] = []

    for host_name, values in root_hosts.items():
        if values.get('ansible_connection') == 'local':
            report.append(('SKIPPED', host_name, 'local connection'))
            continue
        if values.get('homelab_device_type') == 'mikrotik':
            report.append(('SKIPPED', host_name, 'MikroTik RouterOS uses task mikrotik:bootstrap'))
            continue
        ok, detail = key_auth_works(values, key_file)
        if ok:
            values['ansible_ssh_private_key_file'] = key_file
            if 'ansible_password' in values:
                del values['ansible_password']
            changed = True
            report.append(('UPDATED', host_name, detail))
        else:
            report.append(('SKIPPED', host_name, detail))

    for group_name, group_hosts in groups.items():
        for host_name, values in group_hosts.items():
            if values.get('ansible_connection') == 'local':
                report.append(('SKIPPED', host_name, 'local connection'))
                continue
            if group_name == 'mikrotik' or values.get('homelab_device_type') == 'mikrotik':
                report.append(('SKIPPED', host_name, f'group={group_name}; MikroTik RouterOS uses task mikrotik:bootstrap'))
                continue
            ok, detail = key_auth_works(values, key_file)
            if ok:
                values['ansible_ssh_private_key_file'] = key_file
                if 'ansible_password' in values:
                    del values['ansible_password']
                changed = True
                report.append(('UPDATED', host_name, f'group={group_name}; {detail}'))
            else:
                report.append(('SKIPPED', host_name, f'group={group_name}; {detail}'))

    if changed:
        write_inventory(inventory_file, root_hosts, groups)

    print('\nSSH auth normalisation report')
    print('-----------------------------')
    for status, host_name, detail in report:
        print(f'{status:7} {host_name:30} {detail}')
    print(f'\nInventory file: {inventory_file}')
    print('Steady-state SSH auth prefers keys. Password variables are retained only as homelab metadata.')

def main() -> int:
    parser = argparse.ArgumentParser(description='Manage homelab SSH inventory entries.')
    subparsers = parser.add_subparsers(dest='command', required=True)

    interactive_parser = subparsers.add_parser('interactive-add')
    interactive_parser.add_argument('--inventory-file', required=True)
    interactive_parser.add_argument('--password-file', required=True)
    interactive_parser.add_argument('--recipients-file', required=True)

    add_parser = subparsers.add_parser('add-server')
    add_parser.add_argument('--inventory-file', required=True)
    add_parser.add_argument('--password-file', required=True)
    add_parser.add_argument('--recipients-file', required=True)
    add_parser.add_argument('--age-key-file', default='')
    add_parser.add_argument('--group', required=True)
    add_parser.add_argument('--hostname', required=True)
    add_parser.add_argument('--ansible-host', default='')
    add_parser.add_argument('--ssh-user', required=True)
    add_parser.add_argument('--vm-lxc-id', default='')
    add_parser.add_argument('--mac-address', default='')
    add_parser.add_argument('--ssh-password-var', default='')
    add_parser.add_argument('--ssh-password-value-env', default='')
    add_parser.add_argument('--no-password-var', action='store_true')
    add_parser.add_argument('--device-type', default='')
    add_parser.add_argument('--automation-user', default='')
    add_parser.add_argument('--python-interpreter', default='auto_silent')
    add_parser.add_argument('--ssh-port', default='22')
    add_parser.add_argument('--require-password-save', action='store_true')

    normalise_parser = subparsers.add_parser('normalise-auth')
    normalise_parser.add_argument('--inventory-file', required=True)
    normalise_parser.add_argument('--ssh-key-file', required=True)

    list_ssh_hosts_parser = subparsers.add_parser('list-ssh-hosts')
    list_ssh_hosts_parser.add_argument('--inventory-file', required=True)

    args = parser.parse_args()
    if args.command == 'interactive-add':
        add_servers(args, interactive=True)
        return 0
    if args.command == 'add-server':
        add_servers(args, interactive=False)
        return 0
    if args.command == 'normalise-auth':
        normalise_auth(args)
        return 0
    if args.command == 'list-ssh-hosts':
        list_ssh_hosts(args)
        return 0
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
