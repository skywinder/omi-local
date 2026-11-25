"""Read-only Conversation projections for saved local audio awaiting a transcript."""

from __future__ import annotations

import hashlib
import json
import stat
import math
import os
import re
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

from models.conversation import Conversation
from models.structured import Structured
from utils.env_loader import is_offline_runtime
from utils.local_transport_auth import load_pairing, local_tunnel_enabled
from utils.other.local_storage import local_storage_root_from_env

_FAILURE_STAGES = frozenset({'prepare', 'stt', 'diarization', 'summary', 'import'})
_FAILURE_CODES = frozenset({
    'configuration', 'connection', 'credential_missing', 'database_preflight_failed', 'disk_full', 'import_failed',
    'invalid_audio', 'invalid_checkpoint', 'invalid_diarization', 'invalid_json', 'invalid_provider_response',
    'invalid_summary', 'invalid_transcript', 'io_error', 'output_limit', 'response_encoding', 'response_too_large',
    'storage_access', 'summary_model_unavailable', 'timeout', 'unknown',
})


def _safe_failure_code(value):
    if isinstance(value, str) and (value in _FAILURE_CODES or re.fullmatch(r'http_[1-5][0-9]{2}', value)):
        return value
    return None


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
        try:
            written = path.stat().st_mtime
        except OSError:
            continue
        attempt_started = queue[key].get('attempt_started_at')
        if type(attempt_started) in (float, int) and written < attempt_started:
            continue
        if key in stages and stages[key][0] >= written:
            continue
        entries = _optional_json(path)
        for stage in ('stt', 'diarization', 'summary'):
            entry = entries.get(stage)
            if isinstance(entry, dict) and entry.get('status') == 'failed':
                code = _safe_failure_code(entry.get('error_code'))
                stages[key] = (written, {'stage': stage, **({'code': code} if code else {})})
                break
    return {key: value for key, (_, value) in stages.items()}


def _saved_failure(job, checkpoint):
    failure = job.get('failure')
    failure = failure if isinstance(failure, dict) else {}
    stage = failure.get('stage')
    code = _safe_failure_code(failure.get('code'))
    # Explicit preflight/import errors describe the latest attempt even if a previous stage checkpoint survived.
    if isinstance(stage, str) and stage in _FAILURE_STAGES:
        value = {'stage': stage}
    else:
        value = dict(checkpoint)
    if code and value.get('code') in (None, 'unknown'):
        value['code'] = code
    value['attempts'] = job['attempts'] if type(job.get('attempts')) is int else 0
    return value


@dataclass
class RecordingResolution:
    id: str
    include_results: bool = False
    result_keys: set[str] = field(default_factory=set)
    saved: dict | None = None
    group_id: str | None = None
    group: dict | None = None
    children: list[dict] = field(default_factory=list)
    parent: tuple[str, str, str] | None = None


def _group_projection(folder, row_id, *, include_closed=False):
    if folder.is_symlink() or not folder.is_dir():
        return None
    progress = _optional_json(folder / 'progress.json')
    waiting = progress.get('waiting_for_parts') is True
    if not waiting and not include_closed:
        return None
    row = progress.get('waiting_row') if waiting else _optional_json(folder / 'config.json')
    if not isinstance(row, dict):
        return None
    try:
        started = datetime.fromisoformat(row['started_at'])
        duration = row['duration_seconds'] if waiting else progress['next_sample'] / 16_000
        if started.tzinfo is None or type(duration) not in (float, int) or not math.isfinite(duration) or duration < 0:
            return None
        if row['source'] not in {'omi', 'phone'}:
            return None
        status = 'waiting_for_parts' if waiting else 'processing' if progress.get('completed') is True else 'receiving'
        return Conversation(
            id=row_id, created_at=started, started_at=started, finished_at=None,
            source=row['source'], status='processing',
            uses_custom_stt=True, structured=Structured(title='Local recording', overview='', emoji='🎙️'),
            transcript_segments=[], discarded=False, deferred=False,
            external_data={'local_recording': {'status': status, 'duration_seconds': duration, 'group': True,
                                              **({'origin': origin} if (origin := _origin(row)) else {})}},
        ).model_dump()
    except (ValueError, KeyError, TypeError, OverflowError):
        return None


def _group_rows(storage, resolution):
    for folder in (storage / 'grouped-recordings').glob('*'):
        try:
            group_id = uuid.UUID(folder.name)
        except ValueError:
            continue
        if str(group_id) != folder.name:
            continue
        row_id = str(uuid.uuid5(group_id, 'waiting-for-parts'))
        requested = resolution is not None and resolution.include_results and row_id == resolution.id
        projection = _group_projection(folder, row_id, include_closed=requested)
        if projection is None:
            continue
        if requested:
            resolution.group_id, resolution.group = str(group_id), projection
        if projection['external_data']['local_recording']['status'] == 'waiting_for_parts':
            yield projection


def _is_group_child(capture_id, metadata, group_id):
    provenance = metadata.get('conversation_group')
    if not isinstance(provenance, dict) or provenance.get('recording_id') != group_id or group_id is None:
        return False
    start = provenance.get('start_sample')
    end = provenance.get('end_sample')
    return (type(start) is int and type(end) is int and 0 <= start < end
            and str(uuid.uuid5(uuid.UUID(group_id), f'conversation:{start}')) == capture_id)


def _result_parent(storage, resolution, capture_id, row_id, metadata, result_keys):
    expected = {str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + result)): result for result in result_keys}
    result_id = next(iter(expected)) if resolution.id == row_id and len(expected) == 1 else resolution.id
    if result_id not in expected:
        return None
    provenance = metadata.get('conversation_group')
    raw_group = provenance.get('recording_id') if isinstance(provenance, dict) else None
    if isinstance(raw_group, str):
        try:
            group = uuid.UUID(raw_group)
            if str(group) == raw_group and _is_group_child(capture_id, metadata, raw_group):
                parent_id = str(uuid.uuid5(group, 'waiting-for-parts'))
                projection = _group_projection(storage / 'grouped-recordings' / raw_group, parent_id, include_closed=True)
                if projection is not None and projection['source'] == metadata.get('source'):
                    return result_id, expected[result_id], parent_id
        except ValueError:
            pass
    if len(expected) > 1:
        return result_id, expected[result_id], row_id
    return None


def attach_recording_parent(row, resolution):
    if resolution is None:
        return row
    external = row.get('external_data') or {}
    local = external.get('local_transcript')
    if not isinstance(local, dict):
        return row
    linked = None
    if resolution.parent is not None:
        result_id, key, parent_id = resolution.parent
        if (row.get('id') == result_id and row.get('status') == 'completed' and local.get('result_key') == key
                and not row.get('deleted') and not row.get('local_chat_deleting')):
            linked = parent_id
    if linked is None and 'recording_results_id' not in local:
        return row
    local = {**local}
    if linked is None:
        local.pop('recording_results_id', None)
    else:
        local['recording_results_id'] = linked
    return {**row, 'external_data': {**external, 'local_transcript': local}}


def local_recording_rows(uid: str, origins=None, *, retry_targets=None, resolution=None) -> list[dict]:
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
    groups = list(_group_rows(storage, resolution))
    rows = []
    for folder in (storage / 'listen-captures').glob('*'):
        if folder.is_symlink() or not folder.is_dir():
            continue
        try:
            capture_id = str(uuid.UUID(folder.name))
            if capture_id != folder.name:
                continue
            key = hashlib.sha256(capture_id.encode()).hexdigest()
            job = queue.get(key, {})
            if not isinstance(job, dict):
                job = {}
            metadata = _optional_json(folder / 'metadata.json')
            row_id = str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-capture:' + capture_id))
            child = resolution is not None and _is_group_child(capture_id, metadata, resolution.group_id)
            if key in imported or job.get('state') == 'completed':
                if metadata.get('session_id') != capture_id:
                    continue
                result_keys = [result for result in imported.get(key, ()) if re.fullmatch(r'[a-f0-9]{64}', result)]
                if resolution is not None:
                    if row_id == resolution.id or child:
                        resolution.result_keys.update(result_keys)
                        if resolution.include_results and not child:
                            resolution.saved = metadata
                    if resolution.include_results and resolution.group is None and resolution.parent is None:
                        resolution.parent = _result_parent(storage, resolution, capture_id, row_id, metadata, result_keys)
                if origins is not None and (origin := _origin(metadata)):
                    for result_key in result_keys:
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
            if status == 'failed' and not (folder / '.retry-processing').is_symlink() and (folder / '.retry-processing').is_file():
                status = 'pending'
            if retry_targets is not None:
                retry_targets[row_id] = (folder, status)
            projection = Conversation(
                id=row_id,
                created_at=started, started_at=started, finished_at=started + timedelta(seconds=duration),
                source=metadata['source'], status='processing', uses_custom_stt=True,
                structured=Structured(title='Local recording', overview='', emoji='🎙️'),
                transcript_segments=[], discarded=False, deferred=False,
                external_data={'local_recording': {'status': status, 'duration_seconds': duration,
                                                  **({'origin': origin} if (origin := _origin(metadata)) else {}),
                                                  **({'failure': _saved_failure(job, failures.get(key, {}))}
                                                     if status == 'failed' else {})}},
            ).model_dump()
            rows.append(projection)
            if child:
                resolution.children.append(projection)
        except (ValueError, KeyError, TypeError, OSError, OverflowError):
            # An incomplete/corrupt capture cannot hide other saved recordings.
            continue
    return rows + groups


def request_processing_retry(uid: str, conversation_id: str) -> str:
    """Wake the existing watcher for this owner's unimported recording and pinned job."""
    targets = {}
    local_recording_rows(uid, retry_targets=targets)
    target = targets.get(conversation_id)
    if target is None:
        return 'not_found'
    folder, state = target
    if state in {'pending', 'processing'}:
        return state
    if state != 'failed':
        return 'conflict'
    directory = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            marker = os.open('.retry-processing', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directory)
        except FileExistsError:
            try:
                mode = os.stat('.retry-processing', dir_fd=directory, follow_symlinks=False).st_mode
            except FileNotFoundError:
                return 'pending'  # The watcher already consumed the request.
            if not stat.S_ISREG(mode):
                raise ValueError('Invalid retry marker')
        else:
            os.close(marker)
            os.fsync(directory)
    finally:
        os.close(directory)
    return 'pending'


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


def get_local_recording(uid: str, conversation_id: str, origins=None, *, resolution=None) -> dict | None:
    rows = (local_recording_rows(uid, origins) if resolution is None else
            local_recording_rows(uid, origins, resolution=resolution))
    return next((row for row in rows if row['id'] == conversation_id), None)
