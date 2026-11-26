"""Browser note actions share the paired owner's Firestore metadata."""

import json
import re
import time

import httpx

from .local_env import read_env
from .local_library_transcript import PairedTranscript


class NoteConflict(Exception):
    pass


def valid_change(change):
    if not isinstance(change, dict) or len(change) != 1:
        return False
    field, value = next(iter(change.items()))
    if field in {'starred', 'archived'}:
        return type(value) is bool
    return (field == 'category' and isinstance(value, dict) and set(value) == {'expected', 'value'}
            and all(isinstance(item, str) and re.fullmatch(r'[a-z]{1,32}', item) for item in value.values()))


def public_note(value):
    if not isinstance(value, dict) or any(type(value.get(field)) is not bool for field in ('starred', 'archived')):
        raise ValueError('Invalid note metadata')
    result = {field: value[field] for field in ('starred', 'archived')}
    for field, limit in (('category', 32), ('emoji', 12)):
        item = value.get(field)
        if not isinstance(item, str) or not 0 < len(item) <= limit:
            continue
        normalized = item.replace('\u200d', '') if field == 'emoji' else item
        if normalized and normalized.isprintable():
            result[field] = item
    revision = value.get('transcript_revision')
    if isinstance(revision, str) and 0 < len(revision) <= 64:
        result['transcript_revision'] = revision
    card = value.get('card')
    if isinstance(card, dict):
        fields = {key: card[key] for key, limit in (('title', 500), ('overview', 20000), ('model', 300))
                  if isinstance(card.get(key), str) and len(card[key]) <= limit}
        if fields:
            result['card'] = fields
    return result


class NoteStates:
    def __init__(self, cfg):
        self.cfg = cfg
        self.transcript = PairedTranscript(cfg)

    def exchange(self, keys, *, change=None, detail=False):
        key = read_env(self.cfg.repo_root / '.env')['OMI_LOCAL_APP_KEY']
        endpoint = f'http://127.0.0.1:{self.cfg.backend_port}/v1/local/library/note-states'
        deadline = time.monotonic() + 8
        result = {}
        headers = {'Authorization': 'Bearer ' + key}
        if change is None:
            headers['X-Omiloc-Card'] = 'detail' if detail else 'titles'
        # Keep the existing 200-record read. Titles are bounded by the paired API;
        # the overview is requested only for the open recording.
        batch_size = 1 if detail else 200
        response_limit = 256 * 1024 if detail else 1024 * 1024
        with httpx.Client(trust_env=False, follow_redirects=False, timeout=3) as client:
            for start in range(0, len(keys), batch_size):
                if time.monotonic() >= deadline:
                    raise TimeoutError('Note metadata timeout')
                batch = keys[start:start + batch_size]
                with client.stream('POST', endpoint, headers=headers,
                                   json={'keys': batch, 'change': change}) as response:
                    if change is not None and response.status_code == 404:
                        return {}
                    if change is not None and response.status_code == 409:
                        raise NoteConflict()
                    response.raise_for_status()
                    body = bytearray()
                    for part in response.iter_bytes():
                        body.extend(part)
                        if len(body) > response_limit or time.monotonic() >= deadline:
                            raise ValueError('Invalid note response')
                rows = json.loads(body)
                if not isinstance(rows, dict) or set(rows) - set(batch):
                    raise ValueError('Invalid note response')
                result.update({key: public_note(row) for key, row in rows.items()})
        return result
