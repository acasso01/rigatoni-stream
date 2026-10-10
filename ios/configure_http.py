#!/usr/bin/env python3
"""Local build setting for one explicitly selected HTTP provider; no credentials accepted."""
import argparse
import ipaddress
import os
from pathlib import Path
import plistlib
import re


def provider_host(value):
    host = value.strip().lower()
    if not host:
        return ''
    if len(host) > 253 or not re.fullmatch(r'[a-z0-9.-]+', host) or '.' not in host:
        raise ValueError('Enter the provider DNS hostname only, without http://, port, path or credentials.')
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ValueError('Use the provider DNS hostname, not its IP address.')
    if any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in host.split('.')):
        raise ValueError('Invalid provider hostname.')
    if host in ('supabase.co', 'ts.net') or host.endswith(('.supabase.co', '.ts.net')):
        raise ValueError('Account and gateway hosts must keep HTTPS. Enter only the provider hostname.')
    return host


def configure(plist_path, host):
    host = provider_host(host)
    path = Path(plist_path)
    with path.open('rb') as handle:
        values = plistlib.load(handle)
    # Replace only this script's transport settings; never enable arbitrary HTTP loads.
    values.pop('NSAppTransportSecurity', None)
    if host:
        values['NSAppTransportSecurity'] = {'NSExceptionDomains': {host: {
            'NSExceptionAllowsInsecureHTTPLoads': True,
            'NSIncludesSubdomains': False,
        }}}
    with path.open('wb') as handle:
        plistlib.dump(values, handle)
    os.chmod(path, 0o600)
    return host


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plist', default='Generated/Info.plist')
    parser.add_argument('--host', help='Test/configuration hostname; use the interactive prompt for a private provider.')
    parser.add_argument('--private-file', default='Private/provider-host')
    args = parser.parse_args()
    private = Path(args.private_file)
    existing = private.read_text().strip() if private.exists() else ''
    value = args.host
    if value is None:
        prompt = 'HTTP provider hostname only (blank keeps current setting; enter - for gateway-only): '
        value = input(prompt).strip()
        if not value:
            value = existing
        elif value == '-':
            value = ''
    try:
        host = configure(args.plist, value)
    except ValueError as error:
        parser.exit(2, str(error) + '\n')
    if args.host is None:
        private.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(private.parent, 0o700)
        private.write_text(host + '\n')
        os.chmod(private, 0o600)
    print('Provider-specific HTTP access configured locally.' if host else 'HTTP providers will use the HTTPS gateway.')


if __name__ == '__main__':
    main()
