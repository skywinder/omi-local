"""Shared lock for local final and live transcription installation/inference."""

from __future__ import annotations

from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import stat

from . import safety


class TranscriptionLockError(ValueError):
    """The shared transcription lock cannot be safely acquired."""


class TranscriptionLockBusy(TranscriptionLockError):
    """Another local transcription operation owns the inference slot."""


def _safe_path(repo_root: Path, path: Path) -> None:
    # Harness state may intentionally live outside the checkout via
    # OMI_LOCAL_STATE_ROOT.  Ownership/safe-root validation below supplies the
    # boundary; here we only reject traversal and symlink redirects.
    if '..' in path.parts:
        raise TranscriptionLockError('Небезопасный путь общей блокировки распознавания.')
    for item in (path, *path.parents):
        if item.is_symlink():
            raise TranscriptionLockError('Небезопасный путь общей блокировки распознавания.')


def _layout_for_repo(repo_root: Path, instance: str | None = None):
    """Resolve the same default instance used by scripts/local-mac.sh."""
    repo = repo_root.resolve()
    try:
        name = safety.validate_instance_name(instance or os.environ.get('OMI_LOCAL_INSTANCE') or 'ngrok')
        configured = os.environ.get('OMI_LOCAL_STATE_ROOT')
        raw_base = Path(configured).expanduser() if configured else repo / '.local/dev-harness'
        _safe_path(repo, raw_base / name)
        return safety.layout_for_instance(repo, name, os.environ)
    except (OSError, ValueError, safety.SafetyError):
        raise TranscriptionLockError('Небезопасное локальное окружение распознавания.') from None


def _resolve_lock_path(repo_root: Path, *, cfg=None, lock_path: Path | None = None) -> Path | None:
    explicit = lock_path is not None
    if cfg is not None:
        root = cfg.layout.state_root
        path = lock_path or (cfg.layout.services_dir / 'local-transcripts/.lock')
    elif lock_path is not None:
        root = lock_path.parents[2]
        path = lock_path
    else:
        layout = _layout_for_repo(repo_root)
        root = layout.state_root
        path = layout.services_dir / 'local-transcripts/.lock'

    if not path.is_absolute() or not root.is_absolute():
        raise TranscriptionLockError('Небезопасный путь общей блокировки распознавания.')
    if (path.name, path.parent.name, path.parent.parent.name) != ('.lock', 'local-transcripts', 'services'):
        raise TranscriptionLockError('Небезопасный путь общей блокировки распознавания.')
    if cfg is not None and path != cfg.layout.state_root / 'services/local-transcripts/.lock':
        raise TranscriptionLockError('Небезопасный путь общей блокировки распознавания.')
    _safe_path(repo_root, root)
    _safe_path(repo_root, path)
    if not root.exists():
        # No harness state means no local service can be using this slot yet.
        if explicit:
            raise TranscriptionLockError('Не подтверждён каталог общей блокировки распознавания.')
        return None
    if not root.is_dir():
        raise TranscriptionLockError('Небезопасный каталог локального окружения распознавания.')
    try:
        safety.validate_safe_state_root(root, repo_root.resolve())
        safety.read_and_validate_sentinel(root, repo_root=repo_root.resolve(),
                                          instance=cfg.instance if cfg is not None else None)
    except safety.SafetyError:
        raise TranscriptionLockError('Не подтверждён владелец локального окружения распознавания.') from None
    return path


@contextmanager
def acquire(repo_root: Path, *, cfg=None, shared_lock=None, lock_path: Path | None = None):
    """Hold the instance lock, or reuse the coordinator's already-held handle.

    Standalone installers use the existing harness state when present. The
    coordinator passes its open handle so a second descriptor cannot deadlock
    or accidentally pretend that nested locking provides exclusion.
    """
    if shared_lock is not None:
        yield shared_lock
        return
    path = _resolve_lock_path(repo_root, cfg=cfg, lock_path=lock_path)
    if path is None:
        yield None
        return
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    except OSError:
        raise TranscriptionLockError('Не удалось безопасно открыть общую блокировку распознавания.') from None
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise TranscriptionLockError('Общая блокировка распознавания должна быть обычным файлом.')
        stream = os.fdopen(descriptor, 'r+')
        descriptor = None
        try:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise TranscriptionLockBusy(
                    'Распознавание занято. Дождитесь завершения текущей записи и обработки, затем повторите запуск.'
                ) from None
            yield stream
        finally:
            try:
                fcntl.flock(stream, fcntl.LOCK_UN)
            finally:
                stream.close()
    finally:
        if descriptor is not None:
            os.close(descriptor)
