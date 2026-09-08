"""Coordinated local deletion, serialized with the existing STT import lock."""

import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys

from . import config, safety
from .local_library import read_json, safe_file


class DeleteError(ValueError):
    pass


def database_delete(cfg, digest, result_keys, *, check_only=False):
    env = config.child_env_for(cfg)
    env['PYTHONPATH'] = str(cfg.repo_root / 'backend')
    outcome = subprocess.run(
        [sys.executable, '-m', 'scripts.delete_local_recording'], cwd=cfg.repo_root / 'backend', env=env,
        input=json.dumps({'digest': digest, 'result_keys': result_keys, 'check_only': check_only}),
        capture_output=True, text=True, timeout=60,
    )
    if outcome.returncode or json.loads(outcome.stdout).get('status') != 'passed':
        raise DeleteError('Не удалось проверить разговоры в приложении. Проверьте, что сервер Omi запущен.')


def delete_recording(cfg, audio, *, delete_database=database_delete):
    safety.read_and_validate_sentinel(cfg.layout.state_root, repo_root=cfg.repo_root, instance=cfg.instance)
    root = cfg.layout.services_dir / 'storage/listen-captures'
    transcripts = cfg.layout.services_dir / 'local-transcripts'
    if (not safe_file(audio, root) or audio.parent.parent != root or audio.parent.is_symlink()
            or (audio.parent / 'audio.pcm.part').exists()
            or read_json(audio.parent / 'metadata.json').get('status') != 'completed'):
        raise DeleteError('Можно удалить только завершённую запись.')
    # No model work is started. The lock stops deletion racing an active import.
    transcripts.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(transcripts / '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise DeleteError('Сейчас идёт распознавание. Дождитесь его завершения и повторите удаление.') from None
        with audio.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        folders, keys = [], []
        for folder in transcripts.iterdir():
            manifest = folder / 'manifest.json'
            if folder.is_symlink() or not safe_file(manifest, transcripts):
                continue
            data = read_json(manifest)
            if data.get('audio_sha256') == digest:
                # Reject unexpected nested/symlink content before database mutation.
                if any(p.is_symlink() for p in folder.rglob('*')):
                    raise DeleteError('Результат распознавания изменён. Удаление остановлено.')
                folders.append(folder)
                keys.append(data['result_key'])
        # Identical audio captures can share one transcript/Conversation. Preserve
        # that shared result while another completed capture still references it.
        shared = False
        for candidate in root.glob('*/audio.wav'):
            if candidate == audio or not safe_file(candidate, root) or candidate.parent.is_symlink():
                continue
            if candidate.stat().st_size != audio.stat().st_size:
                continue
            with candidate.open('rb') as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() == digest:
                    shared = True
                    break
        if not shared:
            try:
                delete_database(cfg, digest, keys)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                if isinstance(error, DeleteError):
                    raise
                raise DeleteError('Связь с приложением не проверена. Удаление остановлено; попробуйте ещё раз.') from None
            for folder in folders:
                shutil.rmtree(folder)
        # Keep the capture until all database and transcript operations succeed.
        # Only known completed capture files are removed.
        audio.unlink()
        (audio.parent / 'metadata.json').unlink()
        if not any(audio.parent.iterdir()):
            audio.parent.rmdir()
        return {'status': 'deleted', 'shared_transcript_preserved': shared}
