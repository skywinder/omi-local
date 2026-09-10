"""Loopback-only audio library. No keys, cloud calls or content logs."""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.request
import wave
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from . import config, safety


def port(cfg):
    return cfg.backend_port + 1


def url(cfg):
    return f'http://127.0.0.1:{port(cfg)}'


def read_json(path):
    if path.is_symlink() or path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError('Invalid library file')
    return json.loads(path.read_text())


def safe_file(path, root):
    return path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root.resolve())


class Library:
    def __init__(self, services):
        self.captures = services / 'storage' / 'listen-captures'
        self.transcripts = services / 'local-transcripts'
        self.lock = threading.RLock()
        self.tokens = {}
        self.digests = {}
        self.records = {}

    def open_folder(self, name):
        path = {'audio': self.captures, 'transcripts': self.transcripts}[name]
        if (sys.platform != 'darwin' or not path.is_dir() or path.is_symlink()
                or not path.resolve().is_relative_to(self.captures.parent.parent.resolve())):
            raise OSError('Folder unavailable')
        subprocess.run(['/usr/bin/open', '-a', 'Finder', str(path.resolve())], check=True, timeout=5,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def scan(self):
        """Match exact WAV content to the newest completed model result in memory."""
        with self.lock:
            results = {}
            for folder in self.transcripts.glob('*'):
                manifest, raw = folder / 'manifest.json', folder / 'audio.json'
                if folder.is_symlink() or not all(safe_file(p, self.transcripts) for p in (manifest, raw)):
                    continue
                try:
                    data = read_json(manifest)
                    digest = data['audio_sha256']
                    if digest not in results or raw.stat().st_mtime_ns > results[digest].stat().st_mtime_ns:
                        results[digest] = raw
                except (OSError, ValueError, KeyError, TypeError):
                    continue
            try:
                queue = read_json(self.transcripts / 'watch-queue.json')
                if not isinstance(queue, dict):
                    queue = {}
            except (OSError, ValueError):
                queue = {}
            records = {}
            for folder in self.captures.glob('*'):
                audio, metadata = folder / 'audio.wav', folder / 'metadata.json'
                if folder.is_symlink() or not all(safe_file(p, self.captures) for p in (audio, metadata)):
                    continue
                try:
                    meta = read_json(metadata)
                    if meta.get('status') != 'completed' or (folder / 'audio.pcm.part').exists():
                        continue
                    stamp = audio.stat()
                    identity = (stamp.st_size, stamp.st_mtime_ns, stamp.st_ino)
                    cached = self.digests.get(audio)
                    if cached is None or cached[0] != identity:
                        with wave.open(str(audio)) as wav:
                            if wav.getcomptype() != 'NONE' or not wav.getframerate():
                                continue
                            duration = wav.getnframes() / wav.getframerate()
                        if not math.isfinite(duration) or duration <= 0:
                            continue
                        with audio.open('rb') as stream:
                            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                        self.digests[audio] = (identity, digest, duration)
                    _, digest, duration = self.digests[audio]
                    started = datetime.fromisoformat(meta['started_at'].replace('Z', '+00:00'))
                    if started.tzinfo is None:
                        continue
                    token = self.tokens.setdefault(audio, secrets.token_urlsafe(18))
                    job = queue.get(hashlib.sha256(folder.name.encode()).hexdigest(), {})
                    state = job.get('state', 'unavailable')
                    state = state if state in {'pending', 'processing', 'failed'} else 'unavailable'
                    segments = []
                    if digest in results:
                        try:
                            for item in read_json(results[digest]).get('segments', []):
                                start, end = float(item['start']), float(item['end'])
                                if (not isinstance(item.get('text'), str) or not item['text'].strip()
                                        or not math.isfinite(start) or not math.isfinite(end)
                                        or not 0 <= start <= end <= duration + .1):
                                    raise ValueError('Invalid transcript')
                                speaker = item.get('speaker', '')
                                speaker = speaker if isinstance(speaker, str) and re.fullmatch(r'SPEAKER_\d+', speaker) else ''
                                segments.append({'start': start, 'end': min(end, duration),
                                                 'text': item['text'].strip(), 'speaker': speaker})
                            segments.sort(key=lambda s: s['start'])
                            state = 'ready' if segments else 'unavailable'
                        except (OSError, ValueError, KeyError, TypeError, AttributeError):
                            segments, state = [], 'failed'
                    records[token] = {'id': token, 'started_at': started.isoformat(),
                                      'source': 'CV1' if meta.get('source') == 'omi' else 'iPhone',
                                      'duration': duration, 'status': state, 'segments': segments,
                                      'audio': audio, 'decode_warning': bool(meta.get('decode_errors', 0))}
                except (OSError, ValueError, KeyError, TypeError, EOFError, wave.Error):
                    continue
            self.records = records
            self.digests = {p: value for p, value in self.digests.items() if p in {r['audio'] for r in records.values()}}
            self.tokens = {p: token for p, token in self.tokens.items() if token in records}
            return [self.public(r, detail=False) for r in sorted(records.values(), key=lambda r: r['started_at'], reverse=True)]

    @staticmethod
    def public(record, *, detail):
        result = {k: v for k, v in record.items() if k not in {'audio', 'segments'}}
        result['preview'] = record['segments'][0]['text'][:180] if record['segments'] else ''
        if detail:
            result['segments'] = record['segments']
        return result

    def get(self, token):
        with self.lock:
            record = self.records.get(token)
            if not record or not safe_file(record['audio'], self.captures):
                raise KeyError('Recording unavailable')
            return record


def byte_range(value, size):
    if not value:
        return 0, size - 1
    match = re.fullmatch(r'bytes=(\d*)-(\d*)', value)
    if not match or not any(match.groups()):
        raise ValueError('Invalid range')
    first, last = match.groups()
    if not first:
        length = int(last)
        if length <= 0:
            raise ValueError('Invalid range')
        return max(0, size - length), size - 1
    start, end = int(first), min(int(last), size - 1) if last else size - 1
    if start > end or start >= size:
        raise ValueError('Invalid range')
    return start, end


def handler(library, assets, delete=None):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass  # URLs, transcript text and filesystem identifiers never enter logs.

        def headers_for(self, status, content_type, length, extra=None):
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(length))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Cross-Origin-Resource-Policy', 'same-origin')
            self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; "
                             "media-src 'self'; connect-src 'self'; img-src 'self'; font-src 'self'; "
                             "frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.end_headers()

        def send_json(self, data, status=200):
            body = json.dumps(data, ensure_ascii=False).encode()
            self.headers_for(status, 'application/json; charset=utf-8', len(body))
            if self.command != 'HEAD':
                self.wfile.write(body)

        def do_HEAD(self):
            self.do_GET()

        def do_POST(self):
            expected = f'127.0.0.1:{self.server.server_port}'
            if (self.headers.get('Host') != expected or self.headers.get('Origin') != f'http://{expected}'
                    or self.headers.get('X-Omiloc-Request') != 'open-folder'
                    or self.headers.get('Sec-Fetch-Site', 'none') not in {'same-origin', 'none'}
                    or any(k.lower() == 'forwarded' or k.lower().startswith('x-forwarded-') for k in self.headers)):
                return self.send_json({'error': 'Открыть папку можно только на этом Mac.'}, 403)
            match = re.fullmatch(r'/api/folders/(audio|transcripts)/open', self.path)
            if not match:
                return self.send_json({'error': 'Папка не найдена.'}, 404)
            try:
                library.open_folder(match[1])
                self.send_json({'status': 'opened'})
            except subprocess.TimeoutExpired:
                self.send_json({'error': 'Ответ задерживается. Проверьте Finder.'}, 504)
            except (OSError, subprocess.CalledProcessError):
                self.send_json({'error': 'Не удалось открыть папку. Проверьте, что она существует и Finder доступен.'}, 503)

        def do_DELETE(self):
            expected = f'127.0.0.1:{self.server.server_port}'
            if (self.headers.get('Host') != expected or self.headers.get('Origin') != f'http://{expected}'
                    or self.headers.get('X-Omiloc-Request') != 'delete'
                    or self.headers.get('Sec-Fetch-Site', 'none') not in {'same-origin', 'none'}
                    or any(k.lower() == 'forwarded' or k.lower().startswith('x-forwarded-') for k in self.headers)):
                return self.send_json({'error': 'Удаление доступно только на этом Mac.'}, 403)
            if not delete or not re.fullmatch(r'/api/recordings/[A-Za-z0-9_-]+', self.path):
                return self.send_json({'error': 'Запись не найдена.'}, 404)
            try:
                with library.lock:
                    record = library.get(self.path.split('/')[-1])
                    result = delete(record['audio'])
                    library.scan()
                self.send_json(result)
            except ValueError as error:
                from .local_library_delete import DeleteError
                message = str(error) if isinstance(error, DeleteError) else 'Удаление не завершено. Обновите список и повторите.'
                self.send_json({'error': message}, 409)
            except (OSError, KeyError):
                self.send_json({'error': 'Удаление не завершено. Обновите список и повторите.'}, 409)

        def do_GET(self):
            try:
                self.serve()
            except (BrokenPipeError, ConnectionResetError):
                pass  # Normal when seeking or switching recordings.
            except (OSError, ValueError, KeyError, TypeError):
                self.send_json({'error': 'Запись недоступна. Обновите список.'}, 404)

        def serve(self):
            expected = f'127.0.0.1:{self.server.server_port}'
            path = urlsplit(self.path).path
            if (self.headers.get('Host') != expected
                    or self.headers.get('Origin', f'http://{expected}') != f'http://{expected}'
                    or any(k.lower() == 'forwarded' or k.lower().startswith('x-forwarded-') for k in self.headers)
                    or (path.startswith('/api/') and self.headers.get('Sec-Fetch-Site', 'none') not in {'same-origin', 'none'})):
                return self.send_json({'error': 'Доступ только с этого Mac.'}, 403)
            assets_map = {'/': ('index.html', 'text/html; charset=utf-8'),
                          '/style.css': ('style.css', 'text/css; charset=utf-8'),
                          '/app.js': ('app.js', 'text/javascript; charset=utf-8'),
                          '/player.mjs': ('player.mjs', 'text/javascript; charset=utf-8')}
            if path in assets_map:
                name, mime = assets_map[path]
                body = (assets / name).read_bytes()
                self.headers_for(200, mime, len(body))
                if self.command != 'HEAD':
                    self.wfile.write(body)
            elif path == '/health':
                self.send_json({'service': 'omi-local-library', 'status': 'ok'})
            elif path == '/api/recordings':
                self.send_json({'recordings': library.scan()})
            elif re.fullmatch(r'/api/recordings/[A-Za-z0-9_-]+(?:/audio)?', path):
                parts = path.split('/')
                record = library.get(parts[3])
                if len(parts) == 4:
                    return self.send_json(library.public(record, detail=True))
                with record['audio'].open('rb') as stream:
                    size = os.fstat(stream.fileno()).st_size
                    try:
                        start, end = byte_range(self.headers.get('Range'), size)
                    except ValueError:
                        self.headers_for(416, 'audio/wav', 0, {'Content-Range': f'bytes */{size}'})
                        return
                    extra = {'Accept-Ranges': 'bytes'}
                    if self.headers.get('Range'):
                        extra['Content-Range'] = f'bytes {start}-{end}/{size}'
                    self.headers_for(206 if 'Content-Range' in extra else 200, 'audio/wav', end - start + 1, extra)
                    if self.command == 'HEAD':
                        return
                    stream.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        chunk = stream.read(min(64 * 1024, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
            else:
                self.send_json({'error': 'Не найдено.'}, 404)
    return Handler


def ready(cfg):
    try:
        with urllib.request.urlopen(url(cfg) + '/health', timeout=2) as response:
            return json.load(response) == {'service': 'omi-local-library', 'status': 'ok'}
    except (OSError, ValueError):
        return False


def start(cfg):
    from . import cli

    safety.read_and_validate_sentinel(cfg.layout.state_root, repo_root=cfg.repo_root, instance=cfg.instance)
    if not 1024 <= port(cfg) <= 65535:
        raise ValueError('Library port outside supported range')
    assets = cfg.repo_root / 'web-local'
    if not all((assets / f).is_file() for f in ('index.html', 'style.css', 'app.js', 'player.mjs')):
        raise ValueError('Library assets missing')
    cli._require_port_available_or_owned(cfg, 'library', port(cfg))
    if cli._service_record(cfg, 'library'):
        if ready(cfg):
            return
        raise ValueError('Library readiness indeterminate; inspect the owned service')
    env = config.child_env_for(cfg)
    env.update({'OMI_LOCAL_STATE_ROOT': str(cfg.layout.state_root.parent), 'OMI_LOCAL_INSTANCE': cfg.instance,
                'OMI_DEV_BIND_HOST': '127.0.0.1', 'OMI_HARNESS_PRIVATE_UMASK': '077',
                'OMI_HARNESS_PORT_OFFSET': str(cfg.backend_port - config.BACKEND_PORT)})
    cli._start_process(cfg, 'library', [sys.executable, '-m', 'dev_harness.local_library'],
                       cwd=cfg.repo_root, log_name='library.log', port=port(cfg), env=env)
    for _ in range(25):
        if ready(cfg):
            return
        time.sleep(.2)
    raise ValueError('Library readiness indeterminate')


def main():
    from .local_library_delete import delete_recording

    cfg = config.load_config(Path.cwd(), create_layout=False)
    safety.read_and_validate_sentinel(cfg.layout.state_root, repo_root=cfg.repo_root, instance=cfg.instance)
    server = ThreadingHTTPServer(('127.0.0.1', port(cfg)), handler(
        Library(cfg.layout.services_dir), cfg.repo_root / 'web-local', lambda audio: delete_recording(cfg, audio)))
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
