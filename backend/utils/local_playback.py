"""Resolve an owner's local Conversation to a finalized capture without exposing paths."""

import hashlib
import os
import re
import stat
import uuid
from contextlib import ExitStack, closing
from pathlib import Path

from utils.local_recording_rows import local_recording_rows, _optional_json
from utils.local_transport_auth import load_pairing

_DIGEST = re.compile(r'[0-9a-f]{64}')
_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def _open_wav(root: Path, capture_id: str):
    with ExitStack() as stack:
        root_fd = os.open(root, _DIR_FLAGS)
        stack.callback(os.close, root_fd)
        folder_fd = os.open(capture_id, _DIR_FLAGS, dir_fd=root_fd)
        stack.callback(os.close, folder_fd)
        fd = os.open('audio.wav', os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=folder_fd)
    stream = os.fdopen(fd, 'rb')
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError('Invalid audio')
        header = stream.read(12)
        if header[:4] != b'RIFF' or header[8:] != b'WAVE':
            raise ValueError('Invalid audio')
        stream.seek(0)
        return stream
    except BaseException:
        stream.close()
        raise


def open_playback(uid, conversation_id, storage, state, get_conversation):
    """Unimported historical listen WAVs have no owner evidence until STT import."""
    if uid != 'alice' or uid != load_pairing()['owner_uid']:
        return None
    saved = get_conversation(uid, conversation_id)
    digest = capture_key = started_at = None
    if saved is not None:
        if saved.get('deleted') or saved.get('is_locked'):
            return None
        source = (saved.get('external_data') or {}).get('local_transcript') or {}
        key, digest = source.get('result_key'), source.get('audio_sha256')
        if (not isinstance(key, str) or not _DIGEST.fullmatch(key)
                or not isinstance(digest, str) or not _DIGEST.fullmatch(digest)
                or str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + key)) != conversation_id):
            return None
        manifest = _optional_json(state / 'services' / 'local-transcripts' / key / 'manifest.json')
        if manifest.get('result_key') != key or manifest.get('audio_sha256') != digest:
            return None
        capture_key = manifest.get('capture_key')
        started_at = manifest.get('started_at')
        if capture_key is None and not isinstance(started_at, str):
            return None
    elif not any(row['id'] == conversation_id for row in local_recording_rows(uid)):
        return None

    captures = storage / 'listen-captures'
    if captures.is_symlink() or not captures.is_dir():
        return None
    for folder in captures.iterdir():
        try:
            capture_id = str(uuid.UUID(folder.name))
            if folder.name != capture_id or folder.is_symlink():
                continue
            if capture_key is not None and hashlib.sha256(capture_id.encode()).hexdigest() != capture_key:
                continue
            if saved is None and str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-capture:' + capture_id)) != conversation_id:
                continue
            meta = _optional_json(folder / 'metadata.json')
            if meta.get('session_id') != capture_id or meta.get('status') not in {'completed', 'recovered'}:
                continue
            if saved is None:
                delivery = meta.get('delivery')
                if not isinstance(delivery, dict) or delivery.get('id') != capture_id:
                    continue
            elif capture_key is None and meta.get('started_at') != started_at:
                continue
            with closing(_open_wav(captures, capture_id)) as stream:
                if digest is not None and hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
                    continue
                stream.seek(0)
                return os.fdopen(os.dup(stream.fileno()), 'rb')
        except (ValueError, OSError):
            continue
    return None
