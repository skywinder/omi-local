"""Reproducible, resumable WhisperX installation; no pairing or recording access."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.request
import zipfile
from pathlib import Path


class InstallError(ValueError):
    pass


SOURCE = Path(__file__).resolve().parents[1]
INPUTS = ('requirements-whisperx-macos.txt', 'whisperx-models.json', 'whisperx-local.patch',
          'dev_harness/stt_install.py', 'dev_harness/local_whisperx.py', 'fixtures/speech-check.wav')


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fingerprint(source: Path = SOURCE) -> str:
    return hashlib.sha256(''.join(digest(source / name) for name in INPUTS).encode()).hexdigest()


def recipe(source: Path = SOURCE) -> dict:
    return json.loads((source / 'whisperx-models.json').read_text())


def atomic_json(path: Path, value: dict) -> None:
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.install-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def file_ok(path: Path, asset: dict) -> bool:
    return path.is_file() and not path.is_symlink() and path.stat().st_size == asset['size'] and digest(path) == asset['sha256']


def download(asset: dict, root: Path, cancelled=None) -> str:
    target = root / asset['path']
    if file_ok(target, asset):
        return 'reused'
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(target.suffix + '.part')
    if target.is_symlink() or partial.is_symlink():
        raise InstallError('Небезопасный путь к файлу модели.')
    offset = partial.stat().st_size if partial.exists() else 0
    if offset >= asset['size']:
        if file_ok(partial, asset):
            os.replace(partial, target)
            return 'completed-part'
        partial.unlink()
        offset = 0
    initial_offset = offset
    # Bounded ranges also handle CDNs that finish a response before the whole object.
    while offset < asset['size']:
        if cancelled is not None and cancelled.is_set():
            raise InstallError('Загрузка остановлена после ошибки другого файла.')
        end = min(offset + 64 * 1024**2, asset['size']) - 1
        headers = {'User-Agent': 'omiloc-installer', 'Accept-Encoding': 'identity',
                   'Range': f'bytes={offset}-{end}'}
        request = urllib.request.Request(asset['url'], headers=headers)
        with urllib.request.urlopen(request, timeout=60) as response:
            append = response.status == 206
            if append:
                span = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', response.headers.get('Content-Range', ''))
                if (not span or int(span[1]) != offset or int(span[3]) != asset['size']
                        or not offset <= int(span[2]) <= end):
                    raise InstallError('Сервер вернул неверный диапазон загрузки; повторите подготовку.')
            with partial.open('ab' if append else 'wb') as stream:
                shutil.copyfileobj(response, stream, length=1024 * 1024)
        received = partial.stat().st_size
        if received <= offset or received > asset['size']:
            raise InstallError('Загрузка модели не продвигается. Повторите подготовку.')
        offset = received
    if not file_ok(partial, asset):
        partial.unlink()
        raise InstallError('Контрольная сумма модели не совпала; повторите подготовку.')
    os.replace(partial, target)
    return f'resumed from {initial_offset} bytes' if initial_offset and append else 'downloaded'


def extract_nltk(assets: Path) -> None:
    with zipfile.ZipFile(assets / 'nltk/punkt_tab.zip') as archive:
        for entry in archive.infolist():
            path = Path(entry.filename)
            if path.is_absolute() or '..' in path.parts or path.parts[0] != 'punkt_tab':
                raise InstallError('Неожиданный путь в архиве NLTK.')
            if not entry.is_dir():
                target = assets / 'nltk/tokenizers' / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))


def asset_receipt(assets: Path, data: dict) -> dict:
    paths = [assets / item['path'] for item in data['assets']]
    paths += sorted((assets / 'nltk/tokenizers/punkt_tab').rglob('*'))
    return {str(path.relative_to(assets)): [path.stat().st_size, path.stat().st_mtime_ns]
            for path in paths if path.is_file()}


def verify_assets(assets: Path, data: dict) -> None:
    """Cheap check of files whose contents were verified during installation."""
    try:
        receipt = json.loads((assets / 'verified.json').read_text())
        expected = {item['path'] for item in data['assets']}
        expected.update('nltk/tokenizers/punkt_tab/russian/' + name for name in (
            'collocations.tab', 'sent_starters.txt', 'abbrev_types.txt', 'ortho_context.tab'))
        if not expected.issubset(receipt):
            raise ValueError('incomplete receipt')
        for name, stat in receipt.items():
            path = assets / name
            if path.is_symlink() or [path.stat().st_size, path.stat().st_mtime_ns] != stat:
                raise ValueError('asset changed')
    except (OSError, ValueError, TypeError):
        raise InstallError('Модели отсутствуют или изменились. Повторите install-local-stt.sh.') from None


def environment(root: Path) -> dict:
    env = {key: os.environ[key] for key in ('HOME', 'PATH', 'TMPDIR', 'LANG') if key in os.environ}
    env.update({'UV_CACHE_DIR': str(root / 'uv-cache'), 'UV_PYTHON_INSTALL_DIR': str(root / 'python'),
                'UV_NO_CONFIG': '1', 'UV_PYTHON_INSTALL_BIN': '0',
                'HF_HUB_DISABLE_TELEMETRY': '1', 'HF_HUB_DISABLE_IMPLICIT_TOKEN': '1',
                'PYANNOTE_METRICS_ENABLED': '0', 'DO_NOT_TRACK': '1'})
    return env


def offline_command(command: list[str], env: dict) -> list[str]:
    if sandbox := shutil.which('sandbox-exec'):
        # macOS strips inherited DYLD_* from its signed system tools. Restore the
        # FFmpeg path after entering the sandbox, before Python's loader starts.
        return [sandbox, '-p', '(version 1)(allow default)(deny network*)',
                '/usr/bin/env', 'DYLD_LIBRARY_PATH=' + env.get('DYLD_LIBRARY_PATH', ''), *command]
    return command


def installed(root: Path, source: Path = SOURCE) -> Path | None:
    try:
        ready = json.loads((root / 'ready.json').read_text())
        revision = fingerprint(source)
        if ready.get('revision') != revision:
            return None
        python = root / 'runtimes' / revision / 'venv/bin/python'
        if not python.is_file():
            return None
        verify_assets(root / 'assets', recipe(source))
        return python
    except (OSError, ValueError):
        return None


def apply_patch(python: Path, data: dict, env: dict, log, source: Path) -> None:
    site = Path(subprocess.check_output([str(python), '-c', 'import sysconfig; print(sysconfig.get_path("purelib"))'], env=env, text=True).strip())
    actual = {name: digest(site / name) for name in data['patches']}
    if all(actual[name] == value['patched'] for name, value in data['patches'].items()):
        return
    if any(actual[name] not in (value['original'], value['patched']) for name, value in data['patches'].items()):
        raise InstallError('Исходники WhisperX отличаются от закреплённой версии.')
    # Publish verified files atomically so an interrupted patch can be retried.
    patch_text = (source / 'whisperx-local.patch').read_text()
    for name, hashes in data['patches'].items():
        if actual[name] == hashes['patched']:
            continue
        section = next('--- ' + part for part in patch_text.split('--- ')[1:] if part.startswith('a/' + name + '\n'))
        with tempfile.TemporaryDirectory(dir=site, prefix='.omiloc-patch-') as temporary:
            target = Path(temporary) / name
            target.parent.mkdir(parents=True)
            shutil.copyfile(site / name, target)
            subprocess.run(['patch', '-p1', '--batch', '--forward'], input=section.encode(), cwd=temporary,
                           env=env, stdout=log, stderr=log, check=True)
            if digest(target) != hashes['patched']:
                raise InstallError('Проверка правок WhisperX не пройдена.')
            os.replace(target, site / name)


def install(root: Path, source: Path = SOURCE) -> None:
    data = recipe(source)
    if digest(source / data['smoke']['path']) != data['smoke']['sha256']:
        raise InstallError('Проверочный аудиофайл отсутствует или изменился.')
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise InstallError('Распознавание рассчитано на Mac с Apple Silicon.')
    if int(platform.mac_ver()[0].split('.')[0]) < data['macos_min']:
        raise InstallError('Этим версиям библиотек нужна macOS 14 или новее.')
    for tool in ('uv', 'brew', 'patch'):
        if shutil.which(tool) is None:
            raise InstallError('Сначала подготовьте Mac через start.command.')
    revision = fingerprint(source)
    if root.is_symlink() or root.parent.is_symlink():
        raise InstallError('Небезопасный путь установки.')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if any((root / name).is_symlink() for name in ('.install.lock', 'install.log', 'ready.json', 'assets', 'runtimes')):
        raise InstallError('Небезопасный путь установки.')
    with (root / '.install.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise InstallError('Подготовка распознавания уже запущена.') from None
        env = environment(root)
        libraries = subprocess.run(['brew', '--prefix', 'ffmpeg@7'], env=env, capture_output=True, text=True)
        if libraries.returncode == 0:
            env['DYLD_LIBRARY_PATH'] = str(Path(libraries.stdout.strip()) / 'lib')
        if existing := installed(root, source):
            command = [str(existing), str(source / 'dev_harness/local_whisperx.py'),
                       '--quick-check', '--assets', str(root / 'assets')]
            probe = subprocess.run(offline_command(command, env), env=env, capture_output=True)
            if probe.returncode == 0:
                print('Распознавание уже подготовлено.')
                return
        # Preserve old runtimes; all writes target this recipe's separate environment.
        if shutil.disk_usage(root).free < 8 * 1024**3:
            raise InstallError('Для подготовки освободите минимум 8 ГБ на диске.')
        (root / 'ready.json').unlink(missing_ok=True)
        runtime = root / 'runtimes' / revision
        runtime.mkdir(parents=True, exist_ok=True)
        python = runtime / 'venv/bin/python'
        with (root / 'install.log').open('a') as log:
            os.chmod(root / 'install.log', 0o600)
            log.write(f'\nInstallation started: {datetime.now(timezone.utc).isoformat()}\n')
            log.flush()
            def run(command):
                log.write('Step: ' + ' '.join(command[:3]) + '\n')
                log.flush()
                # Children retain ownership if their supervising installer is interrupted.
                result = subprocess.run(command, env=env, stdout=log, stderr=log, pass_fds=(lock.fileno(),))
                if result.returncode:
                    log.write(f'Step failed: exit {result.returncode}\n')
                    raise subprocess.CalledProcessError(result.returncode, command)
            print('Готовим окружение распознавания…', flush=True)
            if subprocess.run(['brew', 'list', '--versions', 'ffmpeg@7'], env=env, stdout=log, stderr=log).returncode:
                run(['brew', 'install', 'ffmpeg@7'])
            run(['uv', 'python', 'install', '--no-bin', data['python']])
            run(['uv', 'venv', '--allow-existing', '--managed-python', '--python', data['python'], str(runtime / 'venv')])
            run(['uv', 'pip', 'sync', '--reinstall', '--require-hashes', '--default-index', 'https://pypi.org/simple',
                 '--python', str(python), str(source / 'requirements-whisperx-macos.txt')])
            run(['uv', 'pip', 'check', '--python', str(python)])
            apply_patch(python, data, env, log, source)
            print('Скачиваем модели — около 3 ГБ. Прерванная загрузка продолжится при повторе.', flush=True)
            cancelled = threading.Event()
            log_lock = threading.Lock()
            def fetch(item):
                try:
                    outcome = download(item, root / 'assets', cancelled)
                    with log_lock:
                        log.write(f"Asset {item['path']}: {outcome}\n")
                        log.flush()
                except (OSError, InstallError) as error:
                    cancelled.set()
                    with log_lock:
                        log.write(f"Download failed: {item['path']}; {type(error).__name__}; HTTP {getattr(error, 'code', 'n/a')}\n")
                        log.flush()
                    raise
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(fetch, item) for item in data['assets']]
                try:
                    for future in as_completed(futures):
                        future.result()
                except Exception:
                    cancelled.set()
                    for future in futures:
                        future.cancel()
                    raise
            extract_nltk(root / 'assets')
            atomic_json(root / 'assets/verified.json', asset_receipt(root / 'assets', data))
            libraries = subprocess.check_output(['brew', '--prefix', 'ffmpeg@7'], env=env, text=True).strip()
            env['DYLD_LIBRARY_PATH'] = str(Path(libraries) / 'lib')
            print('Проверяем распознавание и таймкоды без сети…', flush=True)
            command = [str(python), str(source / 'dev_harness/local_whisperx.py'), '--check', '--assets', str(root / 'assets')]
            run(offline_command(command, env))
            if fingerprint(source) != revision:
                raise InstallError('Файлы установщика изменились. Повторите подготовку.')
            atomic_json(root / 'ready.json', {'revision': revision})
            log.write('Installation completed: offline speech and timestamps passed\n')
        print('Распознавание подготовлено. Лог: ' + os.path.relpath(root / 'install.log'))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=SOURCE.parents[1] / '.local/stt')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.check:
            if installed(args.root) is None:
                raise InstallError('Распознавание не подготовлено. Запустите install-local-stt.sh.')
            print('Распознавание: файлы проверены.')
        else:
            install(args.root.absolute())
        return 0
    except (InstallError, OSError, subprocess.SubprocessError) as error:
        print(str(error) if isinstance(error, InstallError) else
              'Подготовка остановлена. Повторите команду; подробности: ' +
              os.path.relpath(args.root / 'install.log'), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
