"""Read one imported transcript through the same paired detail and people APIs as Next."""

import hashlib
import json
import math
import re
import threading
import time
import uuid

import httpx

from .local_env import read_env


def _read(client, path, limit):
    deadline = time.monotonic() + 8
    with client.stream('GET', path) as response:
        response.raise_for_status()
        body = bytearray()
        for chunk in response.iter_bytes(65536):
            if len(body) + len(chunk) > limit or time.monotonic() >= deadline:
                raise ValueError('Paired response exceeded its read budget')
            body.extend(chunk)
    return json.loads(body)


def _segments(row, key, digest, duration):
    external = row.get('external_data')
    local = external.get('local_transcript') if isinstance(external, dict) else None
    if not isinstance(local, dict):
        raise ValueError('Missing paired transcript provenance')
    if (row.get('is_locked') or row.get('status') != 'completed' or local.get('result_key') != key or local.get('audio_sha256') != digest
            or local.get('segment_preview') is True):
        raise ValueError('Paired transcript source mismatch')
    segments = row.get('transcript_segments')
    if not isinstance(segments, list) or not segments:
        raise ValueError('Paired transcript incomplete')
    result = []
    for line in segments:
        start, end = line['start'], line['end']
        if (type(start) not in (int, float) or type(end) not in (int, float) or not math.isfinite(end)
                or not 0 <= start <= min(end, duration) or end > duration + .1
                or not isinstance(line['text'], str) or not line['text'].strip()):
            raise ValueError('Invalid paired transcript')
        speaker = line.get('speaker') or ''
        turn = {'start': start, 'end': min(end, duration), 'text': line['text'],
                'speaker': speaker if isinstance(speaker, str) and re.fullmatch(r'SPEAKER_\d+', speaker) else ''}
        if line.get('is_user') is True:
            turn['is_user'] = True
        elif isinstance(line.get('person_id'), str) and line['person_id']:
            turn['person_id'] = line['person_id']
        result.append(turn)
    return result


class PairedTranscript:
    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.cached = None

    def read(self, key, digest, duration, revision, files):
        secret = read_env(self.cfg.repo_root / '.env')['OMI_LOCAL_APP_KEY']
        # A Firestore edit, pairing switch, or replacement of the source files invalidates the last open transcript.
        stamps = tuple((st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns) for st in (path.stat() for path in files))
        identity = (hashlib.sha256(secret.encode()).digest(), key, digest, duration, revision, stamps)
        with self.lock:
            cached = self.cached
        turns = cached[1] if cached and revision and cached[0] == identity else None
        with httpx.Client(base_url=f'http://127.0.0.1:{self.cfg.backend_port}', trust_env=False,
                          follow_redirects=False, timeout=6, headers={'Authorization': 'Bearer ' + secret}) as client:
            if turns is None:
                cid = uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + key)
                row = _read(client, f'/v1/conversations/{cid}', 64 * 1024 * 1024)
                if not isinstance(row, dict) or row.get('id') != str(cid):
                    raise ValueError('Invalid paired recording')
                turns = _segments(row, key, digest, duration)
                if revision:
                    with self.lock:
                        self.cached = (identity, turns)
            names = {}
            names_unavailable = False
            if any('person_id' in turn for turn in turns):
                try:
                    people = _read(client, '/v1/local/people', 1024 * 1024)
                    if not isinstance(people, list):
                        raise ValueError('Invalid paired people')
                    names = {p['id']: p['name'] for p in people if isinstance(p, dict)
                             and isinstance(p.get('id'), str) and isinstance(p.get('name'), str)}
                except (httpx.HTTPError, ValueError):
                    names_unavailable = True
        public = []
        for turn in turns:
            if 'person_id' in turn:
                turn = turn.copy()
                name = names.get(turn.pop('person_id'))
                if name:
                    turn['speaker_name'] = name
            public.append(turn)
        return public, names_unavailable
