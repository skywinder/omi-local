"""Read ranked source pointers from the private model process and verify their revisions."""

import json
import os
import re
import socket
from datetime import datetime
from itertools import islice
from pathlib import Path

from utils.conversations.semantic_passages import owner_digest, passages, source_revision


_RECORDING_ID = re.compile(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}')


class SemanticUnavailable(ValueError):
    pass


def rank(uid, query):
    address = os.getenv('OMI_LOCAL_SEMANTIC_SOCKET')
    if not address and (state := os.getenv('OMI_HARNESS_STATE_ROOT')):
        address = str(Path(state) / 'services' / 'semantic-search' / 'queries.sock')
    if not address or not Path(address).is_absolute():
        raise SemanticUnavailable()
    request = json.dumps({'owner': owner_digest(uid), 'query': query}, ensure_ascii=False).encode() + b'\n'
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as owner:
            owner.settimeout(6)
            owner.connect(address)
            owner.sendall(request)
            with owner.makefile('rb') as stream:
                reply = stream.readline(32769)
        if len(reply) > 32768 or not reply.endswith(b'\n'):
            raise ValueError('Invalid semantic response frame')
        hits = json.loads(reply)['hits']
        if not isinstance(hits, list) or len(hits) > 40:
            raise ValueError('Invalid semantic response count')
        for hit in hits:
            if (not _RECORDING_ID.fullmatch(hit['id']) or not isinstance(hit['revision'], str)
                    or type(hit['position']) is not int or hit['position'] < 0):
                raise ValueError('Invalid semantic result pointer')
        return hits
    except (OSError, KeyError, TypeError, ValueError):
        raise SemanticUnavailable() from None


def resolve_passages(hits, rows, hydrate):
    """Yield canonical passages in pointer rank order."""
    found = False
    stale = False
    for hit in hits:
        identifier = hit['id']
        row = rows.get(identifier)
        if row is None:
            continue
        if source_revision(row['_local_read_version']) != hit['revision']:
            stale = True
            continue
        if not isinstance(row.get('started_at') or row.get('created_at'), datetime):
            continue
        position = hit['position']
        try:
            passage = next(islice(passages(hydrate(row)), position, position + 1), None)
        except (OSError, ValueError):
            stale = True
            continue
        if passage is not None:
            found = True
            yield identifier, row, passage
    if stale and not found:
        raise SemanticUnavailable()


def resolve(hits, rows, hydrate, *, limit=15):
    items = []
    for identifier, row, passage in resolve_passages(hits, rows, hydrate):
        started_at = row.get('started_at') or row.get('created_at')
        structured = row.get('structured')
        title = str(structured.get('title') or '') if isinstance(structured, dict) else ''
        items.append({
            'id': identifier, 'title': title[:240], 'started_at': started_at,
            'match_snippets': [passage.snippet] if passage.snippet else [],
        })
        if len(items) == limit:
            break
    return items
