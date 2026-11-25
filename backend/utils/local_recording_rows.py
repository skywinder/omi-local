"""Read-only Conversation projections for saved local audio awaiting a transcript."""

from __future__ import annotations

import hashlib
import json
import stat
import math
import os
import re
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from models.conversation import Conversation
from models.structured import Structured
from utils.env_loader import is_offline_runtime
from utils.local_transport_auth import load_pairing, local_tunnel_enabled
from utils.other.local_storage import local_storage_root_from_env


def _optional_json(path: Path) -> dict:
    try:
        limit = 4 * 1024 * 1024
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError('Invalid local recording state')
            raw = stream.read(limit + 1)
        if len(raw) > limit:
            raise ValueError('Invalid local recording state')
        value = json.loads(raw)
    except (OSError, ValueError):
        # These observations must not make the Conversations list/detail fail.
        # Canonical audio remains available even if a queue or receipt is unreadable.
        return {}
    if not isinstance(value, dict):
        return {}
    return value


def _origin(metadata):
    from utils.offline_audio_capture import _clean_origin
    return _clean_origin(metadata.get('origin'), metadata.get('source'))


def attach_saved_origin(row, origins):
    origin = origins.get(row.get('id'))
    if origin:
        external = dict(row.get('external_data') or {})
        external['local_transcript'] = {**(external.get('local_transcript') or {}), 'origin': origin}
        return {**row, 'external_data': external}
    return row


def _failed_stages(results, queue):
    failed = {key for key, job in queue.items() if isinstance(job, dict) and job.get('state') == 'failed'}
    stages = {}
    if not failed:
        return stages
    for path in results.glob('*/processing.json'):
        if path.parent.is_symlink() or (path.parent / 'import.json').exists():
            continue
        manifest = _optional_json(path.with_name('manifest.json'))
        key = manifest.get('capture_key')
        if not isinstance(key, str) or key not in failed or manifest.get('profile') != queue[key].get('profile'):
            continue
        entries = _optional_json(path)
        for stage in ('stt', 'diarization', 'summary'):
            entry = entries.get(stage)
            if isinstance(entry, dict) and entry.get('status') == 'failed':
                code = entry.get('error_code')
                stages[key] = {'stage': stage}
                if isinstance(code, str) and re.fullmatch(r'http_[1-5][0-9]{2}|timeout|connection|output_limit|invalid_json', code):
                    stages[key]['code'] = code
                break
    return stages


def local_recording_rows(uid: str, origins=None) -> list[dict]:
    if not is_offline_runtime() or not local_tunnel_enabled():
        return []
    if uid != load_pairing()['owner_uid']:
        return []
    storage = local_storage_root_from_env()
    state = os.environ.get('OMI_HARNESS_STATE_ROOT')
    if storage is None or not state:
        return []
    results = Path(state) / 'services' / 'local-transcripts'
    queue = _optional_json(results / 'watch-queue.json')
    failures = _failed_stages(results, queue)
    imported = {}
    for receipt in results.glob('*/import.json'):
        if receipt.parent.is_symlink():
            continue
        data = _optional_json(receipt)
        key = data.get('capture_key')
        if data.get('import') == 'passed' and isinstance(key, str):
            imported.setdefault(key, []).append(receipt.parent.name)
    rows = []
    for folder in (storage / 'listen-captures').glob('*'):
        if folder.is_symlink() or not folder.is_dir():
            continue
        try:
            capture_id = str(uuid.UUID(folder.name))
            key = hashlib.sha256(capture_id.encode()).hexdigest()
            job = queue.get(key, {})
            if not isinstance(job, dict):
                job = {}
            metadata = _optional_json(folder / 'metadata.json')
            if key in imported or job.get('state') == 'completed':
                if origins is not None and metadata.get('session_id') == capture_id and (origin := _origin(metadata)):
                    for result_key in imported.get(key, ()):
                        if re.fullmatch(r'[a-f0-9]{64}', result_key):
                            origins[str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + result_key))] = origin
                continue
            if metadata.get('status') not in {'completed', 'recovered'} or not (folder / 'audio.wav').is_file():
                continue
            duration = metadata.get('duration_seconds')
            if type(duration) not in (int, float) or not math.isfinite(duration) or duration <= 0:
                continue
            if metadata.get('session_id') != capture_id or metadata.get('source') not in {'omi', 'phone'}:
                continue
            started_at = metadata.get('started_at')
            if not isinstance(started_at, str):
                continue
            started = datetime.fromisoformat(started_at.replace('Z', '+00:00'))
            if started.tzinfo is None:
                continue
            status = job.get('state', 'saved')
            if not isinstance(status, str) or status not in {'pending', 'processing', 'failed', 'no_speech'}:
                status = 'saved'
            rows.append(Conversation(
                id=str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-capture:' + capture_id)),
                created_at=started, started_at=started, finished_at=started + timedelta(seconds=duration),
                source=metadata['source'], status='processing', uses_custom_stt=True,
                structured=Structured(title='Local recording', overview='', emoji='🎙️'),
                transcript_segments=[], discarded=False, deferred=False,
                external_data={'local_recording': {'status': status, 'duration_seconds': duration,
                                                  **({'origin': origin} if (origin := _origin(metadata)) else {}),
                                                  **({'failure': {**failures.get(key, {}),
                                                      'attempts': job.get('attempts') if type(job.get('attempts')) is int else 0}}
                                                     if status == 'failed' else {})}},
            ).model_dump())
        except (ValueError, KeyError, TypeError, OSError, OverflowError):
            # An incomplete/corrupt capture cannot hide other saved recordings.
            continue
    for folder in (storage / 'grouped-recordings').glob('*'):
        if folder.is_symlink() or not folder.is_dir():
            continue
        progress = _optional_json(folder / 'progress.json')
        row = progress.get('waiting_row')
        if not progress.get('waiting_for_parts') or not isinstance(row, dict):
            continue
        try:
            started = datetime.fromisoformat(row['started_at'])
            duration = row['duration_seconds']
            if started.tzinfo is None or type(duration) not in (float, int) or not math.isfinite(duration) or duration < 0:
                continue
            if row['source'] not in {'omi', 'phone'}:
                continue
            rows.append(Conversation(
                id=str(uuid.uuid5(uuid.UUID(folder.name), 'waiting-for-parts')), created_at=started,
                started_at=started, source=row['source'], status='processing', uses_custom_stt=True,
                structured=Structured(title='Local recording', overview='', emoji='🎙️'), transcript_segments=[],
                discarded=False, deferred=False,
                external_data={'local_recording': {'status': 'waiting_for_parts', 'duration_seconds': duration,
                                                  **({'origin': origin} if (origin := _origin(row)) else {})}},
            ).model_dump())
        except (ValueError, KeyError, TypeError, OverflowError):
            continue
    return rows


def filter_local_recording_rows(rows, *, statuses, sources, start_date, end_date, folder_id, starred):
    if 'processing' not in statuses or folder_id or starred:
        return []
    if start_date is not None and start_date.tzinfo is None:
        start_date = start_date.replace(tzinfo=timezone.utc)
    if end_date is not None and end_date.tzinfo is None:
        end_date = end_date.replace(tzinfo=timezone.utc)
    return [row for row in rows if (not sources or row['source'] in sources)
            and (start_date is None or row['created_at'] >= start_date)
            and (end_date is None or row['created_at'] <= end_date)]


def merge_local_recording_page(conversations, recordings, *, offset, limit):
    rows = sorted([*conversations, *recordings], key=lambda row: row['created_at'], reverse=True)
    return rows[offset:offset + limit]


def read_local_archive_page(read_canonical, uid, limit, offset, *, budget, **filters):
    """Read one paired page with the same storage advance as the upstream list."""
    origins = {}
    recordings = filter_local_recording_rows(
        local_recording_rows(uid, origins),
        statuses=filters['statuses'],
        sources=filters['sources'],
        start_date=filters['start_date'],
        end_date=filters['end_date'],
        folder_id=filters['folder_id'],
        starred=filters['starred'],
    )
    # One extra row distinguishes a full final page from an actual continuation.
    canonical = read_canonical(
        uid,
        limit + offset + 1 if recordings else limit + 1,
        0 if recordings else offset,
        budget=budget,
        **filters,
    )
    if recordings:
        if budget.truncated:
            # A local capture behind the observed Firestore prefix may follow
            # unread canonical rows. Advancing past it would skip those rows.
            recordings = (
                [row for row in recordings if row['created_at'] > canonical[-1]['created_at']]
                if canonical else []
            )
        page = merge_local_recording_page(canonical, recordings, offset=offset, limit=limit + 1)
    else:
        page = canonical
    has_more = None if budget.truncated else len(page) > limit
    return [attach_saved_origin(row, origins) for row in page[:limit]], has_more


def get_local_recording(uid: str, conversation_id: str, origins=None) -> dict | None:
    return next((row for row in local_recording_rows(uid, origins) if row['id'] == conversation_id), None)
