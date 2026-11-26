"""Fixed read operations against one explicitly configured paired archive."""
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
from time import monotonic
from urllib.parse import urlsplit

import httpx


class ArchiveError(ValueError):
    pass


def origin(value):
    try:
        uri = urlsplit(value)
        if (uri.scheme not in {'http', 'https'} or not uri.hostname or uri.username or uri.password
                or uri.query or uri.fragment or uri.path not in {'', '/'} or not 1 <= (uri.port or 443) <= 65535):
            raise ValueError()
        if uri.scheme == 'http':
            ip = ipaddress.ip_address(uri.hostname)
            if not ip.is_loopback and ip not in ipaddress.ip_network('100.64.0.0/10'):
                raise ValueError()
        return value.rstrip('/')
    except (TypeError, ValueError):
        raise ArchiveError('Use HTTPS, a Tailscale IPv4 address, or a loopback origin without a path.') from None


def private_json(path):
    try:
        fd = os.open(Path(path), os.O_RDONLY | os.O_NONBLOCK | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(fd, 'r') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 4096:
                raise ValueError()
            return json.load(stream)
    except (OSError, ValueError, TypeError):
        raise ArchiveError('A private regular JSON configuration file (mode 600) is required.') from None


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}', value):
        raise ArchiveError('Invalid recording ID.')
    return value


class ArchiveClient:
    def __init__(self, config, *, transport=None):
        self.config, self.transport = config, transport

    def _request(self, operation, data):
        routes = {
            'list': ('GET', '/v1/local/archive/recordings'),
            'read': ('POST', '/v1/local/archive/read'),
            'words': ('POST', '/v1/local/conversations/search'),
            'meaning': ('POST', '/v1/local/conversations/semantic-search'),
        }
        method, path = routes[operation]
        config = private_json(self.config)
        if not isinstance(config, dict) or config.get('version') != 1:
            raise ArchiveError('Invalid archive configuration.')
        base = origin(config.get('origin'))
        token = config.get('archive_read_key')
        if not isinstance(token, str) or not re.fullmatch(r'omilocal_archive_[A-Za-z0-9_-]{43}', token):
            raise ArchiveError('An archive read key is required.')
        try:
            with httpx.Client(trust_env=False, follow_redirects=False, timeout=httpx.Timeout(15, connect=5),
                              transport=self.transport) as client:
                started, raw = monotonic(), bytearray()
                args = {'params': data} if method == 'GET' else {'json': data}
                with client.stream(method, base + path, headers={'Authorization': 'Bearer ' + token}, **args) as response:
                    if response.status_code == 409:
                        raise ArchiveError('The source changed. Start a new read before using its quotes.')
                    if response.status_code != 200:
                        raise ArchiveError('Archive read unavailable; check access and server capabilities.')
                    for chunk in response.iter_bytes():
                        raw.extend(chunk)
                        if len(raw) > 256 * 1024 or monotonic() - started > 40:
                            raise ArchiveError('Archive response exceeds the read budget.')
                result = json.loads(raw)
                if not isinstance(result, dict):
                    raise ValueError()
                return result
        except ArchiveError:
            raise
        except (httpx.HTTPError, ValueError, TypeError):
            raise ArchiveError('Archive response unavailable or invalid.') from None

    def list(self, after=None):
        if after is not None and (not isinstance(after, str) or not 1 <= len(after) <= 1500):
            raise ArchiveError('Invalid page cursor.')
        return self._request('list', {} if after is None else {'after': after})

    def search(self, query, mode='words', after=None):
        if not isinstance(query, str) or not 1 <= len(query.strip()) <= 240 or mode not in {'words', 'meaning'}:
            raise ArchiveError('Use a nonempty query up to 240 characters and words or meaning mode.')
        if mode == 'meaning' and after is not None:
            raise ArchiveError('Meaning search does not use page cursors.')
        if after is not None and (not isinstance(after, str) or not 1 <= len(after) <= 1500):
            raise ArchiveError('Invalid page cursor.')
        return self._request(mode, {'query': query.strip(), **({'after': after} if after else {})})

    def read(self, recording_id, *, revision=None, start_segment=0, start_character=0, limit=10, segment_id=None):
        identifier(recording_id)
        if (type(start_segment) is not int or start_segment < 0 or type(start_character) is not int or start_character < 0
                or type(limit) is not int or not 1 <= limit <= 30
                or revision is not None and (not isinstance(revision, str) or not 1 <= len(revision) <= 100)
                or segment_id is not None and (not isinstance(segment_id, str) or not 1 <= len(segment_id) <= 256)):
            raise ArchiveError('Invalid quote or pagination arguments.')
        if (start_segment or start_character) and revision is None:
            raise ArchiveError('Continue using the revision returned by the previous read.')
        return self._request('read', {'id': recording_id, 'start_segment': start_segment,
            'start_character': start_character, 'limit': limit, **({'revision': revision} if revision else {}),
            **({'segment_id': segment_id} if segment_id else {})})
