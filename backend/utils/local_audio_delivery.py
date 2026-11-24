"""Immutable phone outbox parts: validate, decode, publish, then acknowledge."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import struct
import tempfile
import uuid
from datetime import datetime
from pathlib import Path
from typing import Callable

from utils import local_conversation_groups as groups
from utils.offline_audio_capture import (
    CAPTURE_DIRECTORY,
    METADATA_NAME,
    OfflineAudioCapture,
    create_offline_audio_capture,
    _atomic_json,
)
from utils.opus_preroll import decode_fresh_audio, validate_preroll

MAGIC = b'OMILOC1\n'
MAX_BODY_BYTES = 16 * 1024 * 1024
MAX_HEADER_BYTES = 4096
MAX_FRAME_BYTES = 4096
MAX_PCM_BYTES = 301 * 16000 * 2


def initialize_local_capture(
    *, offline: bool, headers: object, session_id: str, source: str | None, codec: str, sample_rate: int, channels: int
) -> tuple[bool, OfflineAudioCapture | None]:
    """One production capture-owner decision shared by listen and its tests."""
    preview_only = (
        offline
        and headers.get('x-omi-local-audio-outbox') == '1'
        and (source, codec) in {('omi', 'opus'), ('omi', 'opus_fs320'), ('phone', 'pcm16')}
        and sample_rate == 16000
        and channels == 1
    )
    sink = (
        None
        if preview_only
        else create_offline_audio_capture(
            session_id=session_id,
            source=source,
            input_codec=codec,
            sample_rate=sample_rate,
            channels=channels,
        )
    )
    return preview_only, sink


class DeliveryConflict(ValueError):
    """A stable part identity already belongs to different bytes."""


def _uuid(value: object) -> str:
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise ValueError('Invalid audio part identity')
    return value


def parse_part(body: bytes) -> tuple[dict, list[bytes]]:
    if len(body) > MAX_BODY_BYTES or len(body) < 12 or body[:8] != MAGIC:
        raise ValueError('Invalid audio part envelope')
    header_size = struct.unpack('>I', body[8:12])[0]
    if not 0 < header_size <= MAX_HEADER_BYTES or 12 + header_size > len(body):
        raise ValueError('Invalid audio part header')
    header = json.loads(body[12 : 12 + header_size])
    if not isinstance(header, dict) or type(header.get('version')) is not int or header['version'] not in {1, 2, 3}:
        raise ValueError('Invalid audio part version')
    _uuid(header.get('id'))
    _uuid(header.get('recording_id'))
    if type(header.get('index')) is not int or not 0 <= header['index'] <= 1_000_000_000:
        raise ValueError('Invalid audio part order')
    if not isinstance(header.get('server_id'), str) or not re.fullmatch('[0-9a-f]{64}', header['server_id']):
        raise ValueError('Invalid audio part server binding')
    if (header.get('source'), header.get('codec')) not in {('omi', 'opus'), ('omi', 'opus_fs320'), ('phone', 'pcm16')}:
        raise ValueError('Unsupported audio part format')
    if not isinstance(header.get('started_at'), str) or len(header['started_at']) > 40:
        raise ValueError('Invalid audio part time')
    started = datetime.fromisoformat(header['started_at'].replace('Z', '+00:00'))
    if started.tzinfo is None:
        raise ValueError('Audio part time requires a timezone')
    position = 12 + header_size
    frames = []
    while position < len(body):
        if position + 4 > len(body):
            raise ValueError('Incomplete audio packet length')
        size = struct.unpack('>I', body[position : position + 4])[0]
        position += 4
        if not 0 < size <= MAX_FRAME_BYTES or position + size > len(body):
            raise ValueError('Incomplete or oversized audio packet')
        frames.append(body[position : position + size])
        position += size
        if len(frames) > 60_000:
            raise ValueError('Too many audio packets')
    if header['version'] == 3:
        if (type(header.get('group_version')) is not int or header['group_version'] != 1
                or type(header.get('silence_seconds')) is not int or header['silence_seconds'] not in groups.SILENCE_OPTIONS
                or not isinstance(header.get('group_started_at'), str) or len(header['group_started_at']) > 40
                or datetime.fromisoformat(header['group_started_at'].replace('Z', '+00:00')).tzinfo is None):
            raise ValueError('Invalid conversation group')
        if header.get('kind') == 'finish':
            if (frames or header['index'] < 1 or header['id'] != header['recording_id']
                    or type(header.get('preroll_frames')) is not int or header['preroll_frames'] != 0):
                raise ValueError('Invalid group finish')
            return header, []
        if (header.get('kind') != 'audio' or type(header.get('first_sample')) is not int
                or not 0 <= header['first_sample'] < 2**53 or (header['index'] == 0 and header['first_sample'] != 0)
                or header['id'] == header['recording_id']):
            raise ValueError('Invalid grouped audio')
    elif 'group_version' in header:
        raise ValueError('Invalid grouped delivery version')
    if not frames:
        raise ValueError('Audio part is empty')
    validate_preroll(header, frames)
    return header, frames


def _sync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _receipt(target: Path, part_id: str, digest: str, *, grouped=False) -> dict | None:
    if not target.exists():
        return None
    try:
        metadata = json.loads((target / METADATA_NAME).read_text())
        delivery = metadata['delivery']
        durable = (target / 'audio.wav').is_file() or (grouped and metadata.get('group_part_archived') is True)
        if delivery['sha256'] == digest and delivery['id'] == part_id and durable:
            return {'id': part_id, 'sha256': digest, 'stored': True}
    except (OSError, ValueError, KeyError, TypeError):
        pass
    raise DeliveryConflict('Audio part identity already exists')


def accept_part(
    body: bytes,
    root: Path,
    *,
    decoder_factory: Callable[[], object] | None = None,
    check_capacity: Callable[[Path], None] | None = None,
) -> dict:
    """Return a receipt only after a whole immutable part is durably published.

    Staging is outside the transcription watcher's capture tree. Concurrent or
    repeated uploads converge on the exact body checksum, including lost ACKs.
    """
    header, frames = parse_part(body)
    digest = hashlib.sha256(body).hexdigest()
    if header['version'] == 3:
        return _accept_grouped(header, frames, digest, root, decoder_factory, check_capacity)
    capture_root = root / CAPTURE_DIRECTORY
    capture_root.mkdir(parents=True, exist_ok=True)
    _sync_directory(root)
    return _store_audio(header, frames, digest, root, capture_root / header['id'], decoder_factory, check_capacity)


def _check_neighbors(parts, index, start, sample_count):
    before = parts / str(index - 1) / METADATA_NAME
    after = parts / str(index + 1) / METADATA_NAME
    if index > 0 and before.exists():
        metadata = groups.read_json(before)
        if start != metadata['delivery']['first_sample'] + metadata['decoded_pcm_bytes'] // 2:
            raise DeliveryConflict('Grouped audio conflicts with the preceding part')
    if after.exists() and start + sample_count != groups.read_json(after)['delivery']['first_sample']:
        raise DeliveryConflict('Grouped audio conflicts with the following part')


def _accept_grouped(header, frames, digest, root, decoder_factory, check_capacity):
    group_root = root / 'grouped-recordings'
    group = group_root / header['recording_id']
    parts = group / 'parts'
    group_root.mkdir(parents=True, mode=0o700, exist_ok=True)
    group.mkdir(mode=0o700, exist_ok=True)
    parts.mkdir(mode=0o700, exist_ok=True)
    _sync_directory(root)
    _sync_directory(group_root)
    receipt = {'id': header['id'], 'sha256': digest, 'stored': True}
    lock_fd = os.open(group / '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        config = {key: header[key] for key in ('source', 'codec', 'server_id', 'silence_seconds')}
        config['started_at'] = header['group_started_at']
        config_path = group / 'config.json'
        if config_path.exists():
            if groups.read_json(config_path) != config:
                raise DeliveryConflict('Conversation settings conflict')
        else:
            _atomic_json(config_path, config)
        _sync_directory(group)
        finish_path = group / 'finish.json'
        index = header['index']
        if header['kind'] == 'finish':
            finish = {**receipt, 'index': index}
            if finish_path.exists():
                if groups.read_json(finish_path) != finish:
                    raise DeliveryConflict('Conversation finish conflict')
            else:
                if any(part.name.isdecimal() and int(part.name) >= index for part in parts.iterdir()):
                    raise DeliveryConflict('Conversation finish excludes delivered parts')
                _atomic_json(finish_path, finish)
                _sync_directory(group)
        else:
            if finish_path.exists() and index >= groups.read_json(finish_path)['index']:
                raise DeliveryConflict('Part beyond conversation finish')
            _store_audio(header, frames, digest, root, parts / str(index), decoder_factory, check_capacity)
        groups.advance_group(root, group, config)
        return receipt


def _store_audio(header, frames, digest, root, target, decoder_factory, check_capacity):
    capture_root = target.parent
    grouped = header['version'] == 3
    existing = _receipt(target, header['id'], digest, grouped=grouped)
    if existing is not None:
        _sync_directory(target)
        _sync_directory(capture_root)
        return existing
    if check_capacity is not None:
        check_capacity(root)
    if header['codec'] == 'pcm16':
        decode = lambda frame: frame
    else:
        if decoder_factory is None:
            import opuslib

            decoder_factory = lambda: opuslib.Decoder(16000, 1)
        decoder = decoder_factory()
        decode = lambda frame: decoder.decode(frame, frame_size=1920)
    preroll = validate_preroll(header, frames)
    pcm = decode_fresh_audio(frames, preroll, decode, limit=MAX_PCM_BYTES)
    if grouped:
        _check_neighbors(capture_root, header['index'], header['first_sample'], len(pcm) // 2)
    staging_root = root / 'local-audio-staging'
    staging_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='part-', dir=staging_root) as temporary:
        capture = OfflineAudioCapture(
            session_id=header['id'], source=header['source'], input_codec=header['codec'], root=Path(temporary)
        )
        capture.session_dir.chmod(0o700)
        capture.started_at = header['started_at']
        capture.record_decoded_frame(encoded_bytes=sum(map(len, frames[preroll:])), pcm=pcm)
        capture.frames_received = len(frames) - preroll
        metadata = capture.finalize()
        metadata['delivery'] = {key: header[key] for key in ('id', 'recording_id', 'index')}
        metadata['delivery']['sha256'] = digest
        metadata['delivery']['preroll_frames'] = preroll
        if grouped:
            metadata['delivery']['first_sample'] = header['first_sample']
            metadata['speech_runs'] = list(groups.SpeechDetector().runs(pcm)) if header['silence_seconds'] else []
        _atomic_json(capture.metadata_path, metadata)
        _sync_directory(capture.session_dir)
        try:
            os.rename(capture.session_dir, target)
        except OSError:
            existing = _receipt(target, header['id'], digest, grouped=grouped)
            if existing is None:
                raise
        _sync_directory(capture_root)
    return {'id': header['id'], 'sha256': digest, 'stored': True}
