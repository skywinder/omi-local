"""Explicit local grant/revoke of a separately scoped archive credential."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import tempfile

from archive_client import ArchiveError, origin, private_json


def write_private(path, value):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix='.archive-access-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def pairing(path):
    data = private_json(path)
    if (not isinstance(data, dict) or data.get('version') != 1
            or not re.fullmatch(r'[0-9a-f]{64}', str(data.get('key_sha256', '')))
            or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', str(data.get('owner_uid', '')))):
        raise ArchiveError('Invalid paired server state.')
    return data


def grant(pairing_path, config_path, base, *, replace=False):
    base = origin(base)
    before = pairing(pairing_path)
    config_path = Path(config_path)
    if config_path.resolve() == Path(pairing_path).resolve() or config_path.is_symlink():
        raise ArchiveError('Choose a separate private client configuration file.')
    if not replace and (config_path.exists() or before.get('archive_read_key_sha256')):
        raise ArchiveError('Access already exists. Use --replace to rotate and revoke the old read key.')
    if config_path.exists():
        private_json(config_path)
    key = 'omilocal_archive_' + secrets.token_urlsafe(32)
    write_private(config_path, {'version': 1, 'origin': base, 'archive_read_key': key})
    # Preserve pairing ownership and the existing phone key. Never log either.
    if pairing(pairing_path) != before:
        raise ArchiveError('Pairing changed. Retry the explicit grant with a fresh configuration file.')
    write_private(pairing_path, {**before, 'archive_read_key_sha256': hashlib.sha256(key.encode()).hexdigest()})


def revoke(pairing_path):
    data = pairing(pairing_path)
    data.pop('archive_read_key_sha256', None)
    write_private(pairing_path, data)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Grant or revoke read-only archive access; never prints credentials')
    parser.add_argument('operation', choices=['grant', 'revoke'])
    parser.add_argument('--pairing-file', required=True)
    parser.add_argument('--config')
    parser.add_argument('--origin')
    parser.add_argument('--replace', action='store_true')
    args = parser.parse_args()
    try:
        if args.operation == 'grant':
            if not args.config or not args.origin:
                raise ArchiveError('Grant requires --config and --origin.')
            grant(args.pairing_file, args.config, args.origin, replace=args.replace)
        else:
            revoke(args.pairing_file)
    except (ArchiveError, OSError):
        parser.exit(1, 'Archive access change failed; check private paths and explicit grant/rotation arguments.\n')
    parser.exit(0, 'Archive read access updated. Credentials were not printed.\n')
