"""Loopback-only audio library. No browser credentials or content logs."""

from __future__ import annotations

import base64
import hashlib
import hmac
import html
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
import uuid
import wave
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import httpx

from . import config, safety
from .local_capture_wav import read_wave
from .local_library_notes import NoteConflict, NoteStates, valid_change


ASSETS = {'/': ('index.html', 'text/html; charset=utf-8'),
          '/style.css': ('style.css', 'text/css; charset=utf-8'),
          '/app.js': ('app.js', 'text/javascript; charset=utf-8'),
          '/live-tuning.mjs': ('live-tuning.mjs', 'text/javascript; charset=utf-8'),
          '/live.mjs': ('live.mjs', 'text/javascript; charset=utf-8'),
          '/settings.mjs': ('settings.mjs', 'text/javascript; charset=utf-8'),
          '/recording-summary.mjs': ('recording-summary.mjs', 'text/javascript; charset=utf-8'),
          '/recording-processing.mjs': ('recording-processing.mjs', 'text/javascript; charset=utf-8'),
          '/recording-categories.mjs': ('recording-categories.mjs', 'text/javascript; charset=utf-8'),
          '/player.mjs': ('player.mjs', 'text/javascript; charset=utf-8'),
          '/reload.mjs': ('reload.mjs', 'text/javascript; charset=utf-8')}


PASSWORD_ITERATIONS = 600_000


def hash_password(password, *, iterations=PASSWORD_ITERATIONS):
    """Colon-separated so the value survives Compose .env interpolation ("$" would not)."""
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(salt), iterations)
    return f'pbkdf2-sha256:{iterations}:{salt}:{digest.hex()}'


def verify_password(stored, password):
    try:
        scheme, iterations, salt, digest = stored.split(':')
        if scheme != 'pbkdf2-sha256' or not 1 <= int(iterations) <= 10_000_000:
            return False
        computed = hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(salt), int(iterations))
        return hmac.compare_digest(computed, bytes.fromhex(digest))
    except (ValueError, TypeError, AttributeError):
        return False


class Access:
    """Optional remote access to the library through one explicit HTTPS origin.

    Loopback stays the default and is never widened. A remote request is served
    only when its Host/Origin equal the configured origin (Tailscale Serve, which
    strips client-sent Tailscale-User-* headers) and it carries either an allowed
    tailnet login or valid Basic credentials over that TLS origin.
    """

    def __init__(self, *, origin='', logins='', user='', password_hash=''):
        self.origin = ''
        self.host = ''
        self.logins = {v.strip().lower() for v in (logins or '').split(',') if v.strip()}
        self.user = user or ''
        self.password_hash = password_hash or ''
        parsed = urlsplit(origin or '')
        if origin:
            if (parsed.scheme != 'https' or not parsed.hostname or '.' not in parsed.hostname or parsed.path not in {'', '/'}
                    or parsed.query or parsed.fragment or parsed.username or parsed.password):
                raise ValueError('OMI_LIBRARY_PUBLIC_ORIGIN must be an https://host[:port] origin')
            self.origin = f'https://{parsed.netloc}'
            self.host = parsed.netloc
        if self.origin and not (self.logins or (self.user and self.password_hash)):
            raise ValueError('Remote library access needs OMI_LIBRARY_TAILSCALE_LOGIN or a user and password hash')
        if bool(self.user) != bool(self.password_hash):
            raise ValueError('Set OMI_LIBRARY_USER together with OMI_LIBRARY_PASSWORD_HASH')

    @classmethod
    def from_env(cls, environ=None):
        env = os.environ if environ is None else environ
        return cls(origin=env.get('OMI_LIBRARY_PUBLIC_ORIGIN', ''), logins=env.get('OMI_LIBRARY_TAILSCALE_LOGIN', ''),
                   user=env.get('OMI_LIBRARY_USER', ''), password_hash=env.get('OMI_LIBRARY_PASSWORD_HASH', ''))

    @property
    def enabled(self):
        return bool(self.origin)

    @property
    def prompts(self):
        return bool(self.user)

    def identified(self, headers):
        login = (headers.get('Tailscale-User-Login') or '').strip().lower()
        if login and login in self.logins:
            return True
        value = headers.get('Authorization', '')
        if self.user and value.startswith('Basic '):
            try:
                user, _, password = base64.b64decode(value[6:].strip(), validate=True).decode().partition(':')
            except (ValueError, UnicodeDecodeError):
                return False
            ok = hmac.compare_digest(user.encode(), self.user.encode()) & verify_password(self.password_hash, password)
            if not ok:
                time.sleep(0.2)  # Blunt online-guessing brake; the origin is tailnet-only anyway.
            return bool(ok)
        return False


def asset_versions(assets, *, index_content=None):
    """Fingerprint browser code only; no private files or filesystem identifiers."""
    page = hashlib.sha256()
    for name, _mime in ASSETS.values():
        if name != 'style.css':
            content = index_content if name == 'index.html' and index_content is not None else (assets / name).read_bytes()
            page.update(name.encode() + b'\0' + content)
    return {'styles': hashlib.sha256((assets / 'style.css').read_bytes()).hexdigest(),
            'page': page.hexdigest()}


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


def card_summary(structured):
    if (isinstance(structured, dict)
            and isinstance(structured.get('title'), str) and len(structured['title']) <= 500
            and isinstance(structured.get('overview'), str) and len(structured['overview']) <= 20000):
        return {key: structured[key] for key in ('title', 'overview')}
    return None


def retained_publication(folder, root):
    # Earlier web clients wrote their last published summary beside the imported transcript.
    # A later attempt may also have a candidate; only published content belongs on a card.
    path = folder / 'summary-job.json'
    try:
        if safe_file(path, root):
            job = read_json(path)
            published = job.get('published') if isinstance(job, dict) else None
            if isinstance(published, dict) and (summary := card_summary(published.get('structured'))) is not None:
                provenance = published.get('provenance')
                stage = {'status': 'ready'}
                if isinstance(provenance, dict):
                    for key in ('model', 'provider_name'):
                        value = provenance.get(key)
                        if isinstance(value, str) and 0 < len(value) <= 256:
                            stage[key] = value
                return summary, stage
    except (OSError, ValueError):
        pass  # The imported transcript remains readable if optional history is damaged.
    return None


def recording_origin_labels(metadata):
    origin = metadata.get('origin')
    origin = origin if isinstance(origin, dict) else {}

    def display_label(field):
        value = origin.get(field)
        return value if isinstance(value, str) and 0 < len(value) <= 80 and value.isprintable() else ''

    platform = {'android': 'Android', 'ios': 'iPhone'}.get(str(origin.get('phone_platform')), '')
    model = display_label('phone_model')
    phone = model if model and model.startswith(platform) else ' · '.join(filter(None, (platform, model)))
    source = 'Микрофон телефона'
    if metadata.get('source') == 'omi':
        wearable = display_label('wearable_name')
        source = f'Omi · {wearable}' if wearable else 'Omi CV1'
    return {'source': source, 'phone': phone}


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
                manifest = folder / 'manifest.json'
                if folder.is_symlink() or not safe_file(manifest, self.transcripts):
                    continue
                try:
                    data = read_json(manifest)
                    digest = data['audio_sha256']
                    candidates = [folder / name for name in ('audio.json', 'diarized.json', 'asr.json')]
                    raw = next((p for p in candidates if safe_file(p, self.transcripts)), None)
                    progress = folder / 'processing.json'
                    stamp = max(p.stat().st_mtime_ns for p in (manifest, raw, progress)
                                if p is not None and safe_file(p, self.transcripts))
                    if digest not in results or stamp > results[digest][2]:
                        results[digest] = (raw, progress, stamp)
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
                        with audio.open('rb') as source_stream, read_wave(source_stream) as wav:
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
                    segments, summary, processing = [], None, {}
                    summary_recording = note_key = None
                    if digest in results:
                        try:
                            raw_path, progress_path, _stamp = results[digest]
                            transcript = read_json(raw_path) if raw_path else {}
                            progress = (read_json(progress_path) if safe_file(progress_path, self.transcripts)
                                        else transcript.get('processing', {}))
                            if isinstance(progress, dict):
                                for stage in ('stt', 'diarization', 'summary'):
                                    entry = progress.get(stage)
                                    if not isinstance(entry, dict) or entry.get('status') not in {
                                            'ready', 'processing', 'pending', 'failed', 'disabled', 'no_speech'}:
                                        continue
                                    processing[stage] = {'status': entry['status']}
                                    code = entry.get('error_code')
                                    if isinstance(code, str) and re.fullmatch(r'http_[1-5][0-9]{2}|timeout|connection|output_limit|invalid_json|unknown', code):
                                        processing[stage]['error_code'] = code
                                    for field in ('provider_name', 'model'):
                                        value = entry.get(field)
                                        if isinstance(value, str) and len(value) <= 256:
                                            processing[stage][field] = value
                            for item in transcript.get('segments', []):
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
                            if (raw_path is None or raw_path.name != 'audio.json') and processing:
                                states = {entry['status'] for entry in processing.values()}
                                state = 'failed' if 'failed' in states else 'processing' if 'processing' in states else 'pending'
                            if not segments and transcript.get('outcome') == 'no_speech' and transcript.get('segments') == []:
                                state = 'no_speech'
                            if raw_path and raw_path.name == 'audio.json':
                                summary = card_summary(transcript.get('structured'))
                            if (raw_path and raw_path.name == 'audio.json'
                                    and re.fullmatch(r'[a-f0-9]{64}', raw_path.parent.name)
                                    and safe_file(raw_path.parent / 'import.json', self.transcripts)
                                    and read_json(raw_path.parent / 'import.json').get('import') == 'passed'):
                                if retained := retained_publication(raw_path.parent, self.transcripts):
                                    summary, processing['summary'] = retained
                                if segments:
                                    note_key = raw_path.parent.name
                                    summary_recording = str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + note_key))
                        except (OSError, ValueError, KeyError, TypeError, AttributeError):
                            segments, state = [], 'failed'
                    records[token] = {'id': token, 'started_at': started.isoformat(),
                                      **recording_origin_labels(meta),
                                      'duration': duration, 'status': state, 'segments': segments,
                                      'attempts': job.get('attempts', 0),
                                      'summary': summary, 'processing': processing, 'summary_recording': summary_recording,
                                      'note_key': note_key,
                                      'audio_sha256': digest, 'audio': audio, 'decode_warning': bool(meta.get('decode_errors', 0))}
                except (OSError, ValueError, KeyError, TypeError, EOFError, wave.Error):
                    continue
            self.records = records
            self.digests = {p: value for p, value in self.digests.items() if p in {r['audio'] for r in records.values()}}
            self.tokens = {p: token for p, token in self.tokens.items() if token in records}
            return [self.public(r, detail=False) for r in sorted(records.values(), key=lambda r: r['started_at'], reverse=True)]

    @staticmethod
    def public(record, *, detail):
        result = {k: v for k, v in record.items() if k not in {'audio', 'audio_sha256', 'segments', 'summary_recording', 'note_key'}}
        if record.get('summary_recording'):
            result['summary_editable'] = True
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

    def note_keys(self, records):
        with self.lock:
            return {row['id']: key for row in records if (key := self.records.get(row['id'], {}).get('note_key'))}


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


def handler(library, assets, delete=None, runtime=None, settings=None, access=None, summary_jobs=None, notes=None):
    access = access or Access()
    from .local_provider_api import Processing
    processing = Processing(settings.cfg, summary_jobs) if settings is not None else None

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass  # URLs, transcript text and filesystem identifiers never enter logs.

        def allowed(self, *, request=None, origin_required=True, api=True):
            """Same-origin check for loopback or the one configured remote origin."""
            loopback = f'127.0.0.1:{self.server.server_port}'
            host, origin = self.headers.get('Host'), self.headers.get('Origin')
            if (any(k.lower() == 'forwarded' or k.lower().startswith('x-forwarded-') for k in self.headers)
                    or (request is not None and self.headers.get('X-Omiloc-Request') != request)
                    or (api and self.headers.get('Sec-Fetch-Site', 'none') not in {'same-origin', 'none'})):
                return False
            if host == loopback:
                return origin == f'http://{loopback}' or (origin is None and not origin_required)
            if access.enabled and host == access.host:
                if origin == access.origin or (origin is None and not origin_required):
                    return access.identified(self.headers)
            return False

        def reject(self, message, status=403):
            if access.prompts and self.headers.get('Host') == access.host and status == 403:
                self.headers_for(401, 'application/json; charset=utf-8', 0, {'WWW-Authenticate': 'Basic realm="omiloc"'})
                return
            return self.send_json({'error': message}, status)

        def processing_allowed(self):
            return (self.client_address[0] in {'127.0.0.1', '::1'}
                    and self.headers.get('Host') == f'127.0.0.1:{self.server.server_port}')

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

        def enrich_notes(self, records, *, opened=None):
            detail = opened is not None
            if detail:
                key = opened.get('note_key')
                keys = {opened['id']: key} if notes is not None and key else {}
            else:
                keys = library.note_keys(records) if notes is not None else {}
            if not keys:
                return True
            try:
                states = notes.exchange(list(dict.fromkeys(keys.values())), detail=detail)
            except httpx.HTTPStatusError as exc:
                if detail and exc.response.status_code in (401, 403):
                    self.enrich_transcript(records[0], opened, opened['note_key'], None)
                return False
            except (httpx.HTTPError, OSError, ValueError, KeyError):
                return False
            for row in records:
                key = keys.get(row['id'])
                note = states.get(key)
                if detail and key:
                    self.enrich_transcript(row, opened, key, note)
                if note is not None:
                    row['note'] = {field: value for field, value in note.items() if field not in {'card', 'transcript_revision'}}
                    if card := note.get('card'):
                        row['summary'] = {**(row.get('summary') or {}),
                                          **{key: card[key] for key in ('title', 'overview') if key in card}}
                        if detail and 'overview' in card:
                            row['summary_current'] = True
                            if card.get('model'):
                                row['processing'] = {**row['processing'], 'summary': {'status': 'ready', 'model': card['model']}}
            return True

        def enrich_transcript(self, row, opened, key, note):
            # A missing owner projection may mean a deleted or locked recording.
            row['segments'] = []
            row['preview'] = ''
            row['transcript_source'] = 'unavailable'
            if note is None:
                return
            folder = library.transcripts / key
            try:
                segments, missing_names = notes.transcript.read(key, opened['audio_sha256'], opened['duration'],
                    note.get('transcript_revision'), (folder / 'manifest.json', folder / 'audio.json'))
            except (httpx.HTTPError, OSError, ValueError, KeyError, TypeError):
                return
            row['segments'] = segments
            row['preview'] = segments[0]['text'][:180] if segments else ''
            row['transcript_source'] = 'paired'
            if missing_names:
                row['speaker_names_unavailable'] = True

        def do_PATCH(self):
            if not self.allowed(request='notes'):
                return self.reject('Требуется доступ к аудиотеке.')
            match = re.fullmatch(r'/api/recordings/([A-Za-z0-9_-]{24})/notes', self.path)
            try:
                key = library.get(match[1]).get('note_key') if match and notes is not None else None
            except KeyError:
                key = None
            if not key:
                return self.send_json({'error': 'Заметка недоступна.'}, 404)
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if (not 0 < length <= 256 or self.headers.get('Transfer-Encoding')
                        or self.headers.get_content_type() != 'application/json'):
                    raise ValueError()
                self.connection.settimeout(10)
                body = self.rfile.read(length)
                change = json.loads(body)
                if len(body) != length or not valid_change(change):
                    raise ValueError()
            except (OSError, ValueError):
                return self.send_json({'error': 'Некорректное изменение заметки.'}, 400)
            try:
                note = notes.exchange([key], change=change).get(key)
            except NoteConflict:
                return self.send_json({'error': 'Категория уже изменилась. Обновите запись и повторите.'}, 409)
            except (httpx.HTTPError, OSError, ValueError, KeyError):
                return self.send_json({'error': 'Не удалось подтвердить изменение заметки.'}, 503)
            if note is None:
                return self.send_json({'error': 'Заметка недоступна.'}, 404)
            self.send_json({'note': note})

        def settings_request(self):
            from .local_providers import SettingsError
            from .local_stt_services import ActivationIndeterminate
            phone = self.path.startswith('/api/processing/')
            controls = processing if phone else settings
            if (not self.allowed(request='processing' if phone else 'settings')
                    or (phone and not self.processing_allowed())):
                return self.reject('Настройки доступны только на этом Mac.')
            if controls is None:
                return self.send_json({'error': 'Настройки недоступны.'}, 503)
            try:
                length = int(self.headers.get('Content-Length', '0'))
                large_requests = ('/api/processing/summary-settings', '/api/settings/summary-settings',
                                  '/api/processing/regenerate-summary')
                limit = 1024 * 1024 if self.path in large_requests else 64 * 1024
                if (not 0 < length <= limit or self.headers.get('Transfer-Encoding')
                        or self.headers.get_content_type() != 'application/json'):
                    raise SettingsError('Некорректный запрос настроек.')
                if hasattr(self.connection, 'settimeout'):
                    self.connection.settimeout(15)
                body = json.loads(self.rfile.read(length))
                self.send_json(controls.dispatch(self.command, self.path, body))
            except SettingsError as error:
                self.send_json({'error': str(error), **({'field': error.field} if error.field else {})}, error.status)
            except ActivationIndeterminate:
                self.send_json({'error': 'Результат применения Live STT не подтверждён. Обновите настройки и проверьте состояние сервера.',
                                'outcome': 'indeterminate'}, 503)
            except (ValueError, TypeError, KeyError):
                self.send_json({'error': 'Настройки не применены. Проверьте параметры и состояние записи.'}, 409)
            except (OSError, subprocess.SubprocessError):
                self.send_json({'error': 'Не удалось применить настройки. Проверьте готовность сервера.'}, 503)

        def do_POST(self):
            if match := re.fullmatch(r'/api/recordings/([A-Za-z0-9_-]+)/summary', self.path):
                return self.web_summary(match[1], write=True)
            if self.path.startswith(('/api/settings/', '/api/processing/')):
                return self.settings_request()
            if not self.allowed(request='open-folder'):
                return self.reject('Открыть папку можно только на этом Mac.')
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

        def web_summary(self, token, *, write=False):
            from .local_providers import SettingsError
            if write and not self.allowed(request='summary'):
                return self.reject('Доступ к итогам требует сопряжённой библиотеки.')
            try:
                identity = library.get(token).get('summary_recording')
                if summary_jobs is None or not identity:
                    raise SettingsError('Итоги записи недоступны.', status=404)
                body = None
                if write:
                    length = int(self.headers.get('Content-Length', '0'))
                    if (not 0 < length <= 64 * 1024 or self.headers.get('Transfer-Encoding')
                            or self.headers.get_content_type() != 'application/json'):
                        raise SettingsError('Некорректный запрос итогов.')
                    self.connection.settimeout(15)
                    body = json.loads(self.rfile.read(length))
                    if not isinstance(body, dict):
                        raise SettingsError('Некорректный запрос итогов.')
                self.send_json(summary_jobs.web(identity, body))
            except SettingsError as error:
                self.send_json({'error': 'Итоги недоступны. Обновите запись или настройки.'}, error.status)
            except (OSError, ValueError, KeyError, TypeError):
                self.send_json({'error': 'Итоги недоступны. Проверьте запись и повторите.'}, 400 if write else 404)

        def do_DELETE(self):
            if self.path.startswith(('/api/settings/', '/api/processing/')):
                return self.settings_request()
            if not self.allowed(request='delete'):
                return self.reject('Удаление доступно только на этом Mac.')
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
            path = urlsplit(self.path).path
            if not self.allowed(origin_required=False, api=path.startswith('/api/')):
                return self.reject('Доступ только с этого Mac.')
            if path in ASSETS:
                name, mime = ASSETS[path]
                body = (assets / name).read_bytes()
                if path == '/':
                    versions = html.escape(json.dumps(asset_versions(assets, index_content=body)), quote=True).encode()
                    body = body.replace(b'__OMILOC_ASSETS__', versions)
                self.headers_for(200, mime, len(body))
                if self.command != 'HEAD':
                    self.wfile.write(body)
            elif path == '/health':
                self.send_json({'service': 'omi-local-library', 'status': 'ok'})
            elif path == '/api/recordings':
                records = library.scan()
                notes_available = self.enrich_notes(records)
                self.send_json({'recordings': records, **({'notes_unavailable': True} if not notes_available else {})})
            elif path == '/api/assets':
                self.send_json(asset_versions(assets))
            elif path == '/api/runtime' and runtime is not None:
                self.send_json(runtime.snapshot())
            elif path == '/api/settings' and settings is not None:
                self.send_json(settings.read())
            elif path in ('/api/settings/summary-settings', '/api/processing/summary-settings') and settings is not None:
                phone = path.startswith('/api/processing/')
                if phone and (not self.allowed(request='processing') or not self.processing_allowed()):
                    return self.reject('Настройки доступны только через сопряжённый сервер.')
                from .local_providers import SettingsError
                try:
                    self.send_json(settings.registry.summary_settings())
                except SettingsError as error:
                    self.send_json({'error': str(error)}, error.status)
            elif path == '/api/settings/live-tuning' and settings is not None:
                from .local_providers import SettingsError
                try:
                    self.send_json(settings.live_tuning())
                except SettingsError as error:
                    self.send_json({'error': str(error)}, error.status)
            elif path == '/api/processing/live-tuning' and processing is not None:
                if not self.processing_allowed():
                    return self.reject('Настройки доступны только через сопряжённый сервер.')
                from .local_providers import SettingsError
                try:
                    self.send_json(processing.live_tuning())
                except SettingsError as error:
                    self.send_json({'error': str(error)}, error.status)
            elif path == '/api/processing' and processing is not None:
                if not self.processing_allowed():
                    return self.reject('Настройки доступны только через сопряжённый сервер.')
                self.send_json(processing.read())
            elif path == '/api/processing/regenerate-summary' and processing is not None:
                if not self.allowed(request='processing') or not self.processing_allowed():
                    return self.reject('Настройки доступны только через сопряжённый сервер.')
                from .local_providers import SettingsError
                try:
                    self.send_json(processing.summary_regeneration_options())
                except (SettingsError, ValueError, KeyError):
                    self.send_json({'error': 'Summary settings are unavailable.'}, 503)
            elif path in {
                '/api/processing/recording-chat', '/api/processing/archive-chat', '/api/processing/task-suggestions',
                '/api/processing/daily-recap', '/api/processing/classify-categories', '/api/processing/memory-proposals',
            } and processing is not None:
                if not self.allowed(request='processing') or not self.processing_allowed():
                    return self.reject('Доступ только через сопряжённый сервер.')
                from .local_providers import SettingsError
                try:
                    self.send_json(processing.recording_chat_provider())
                except (SettingsError, ValueError, KeyError):
                    self.send_json({'error': 'Recording chat provider is unavailable.'}, 503)
            elif match := re.fullmatch(r'/api/recordings/([A-Za-z0-9_-]+)/summary', path):
                self.web_summary(match[1])
            elif re.fullmatch(r'/api/recordings/[A-Za-z0-9_-]+(?:/audio)?', path):
                parts = path.split('/')
                record = library.get(parts[3])
                if len(parts) == 4:
                    detail = library.public(record, detail=True)
                    if not self.enrich_notes([detail], opened=record):
                        detail['notes_unavailable'] = True
                        detail.setdefault('transcript_source', 'original')
                    return self.send_json(detail)
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
    if not all((assets / name).is_file() for name, _mime in ASSETS.values()):
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
    from .local_library_runtime import Runtime
    from .local_provider_api import Settings
    from .local_summary_queue import SummaryJobs

    if sys.argv[1:] == ['hash-password']:
        import getpass
        password = getpass.getpass('Library password: ')
        if len(password) < 8 or password != getpass.getpass('Repeat: '):
            raise SystemExit('Passwords must match and have at least 8 characters.')
        print('OMI_LIBRARY_PASSWORD_HASH=' + hash_password(password))
        return
    cfg = config.load_config(Path.cwd(), create_layout=False)
    safety.read_and_validate_sentinel(cfg.layout.state_root, repo_root=cfg.repo_root, instance=cfg.instance)
    settings = Settings(cfg)
    summaries = SummaryJobs(cfg, settings.registry)
    server = ThreadingHTTPServer(('127.0.0.1', port(cfg)), handler(
        Library(cfg.layout.services_dir), cfg.repo_root / 'web-local', lambda audio: delete_recording(cfg, audio),
        Runtime(cfg), settings, access=Access.from_env(), summary_jobs=summaries,
        notes=NoteStates(cfg) if cfg.local_transport in config.PAIRED_TRANSPORTS else None))
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        summaries.close()


if __name__ == '__main__':
    main()
