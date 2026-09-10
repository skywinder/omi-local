import hashlib
import io
import json
import sys
import wave
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dev_harness.local_library import Library, handler


@pytest.fixture
def library(tmp_path):
    folder = tmp_path / 'storage/listen-captures/synthetic-session'
    folder.mkdir(parents=True)
    audio = folder / 'audio.wav'
    with wave.open(str(audio), 'wb') as wav:
        wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        wav.writeframes(b'\0\0' * 48000)
    (folder / 'metadata.json').write_text(json.dumps({
        'status': 'completed', 'started_at': '2026-09-08T08:00:00+00:00',
        'source': 'omi', 'decode_errors': 0, 'uid': 'synthetic-private-owner',
    }))
    result = tmp_path / 'local-transcripts/result'
    result.mkdir(parents=True)
    (result / 'manifest.json').write_text(json.dumps({'audio_sha256': hashlib.sha256(audio.read_bytes()).hexdigest()}))
    (result / 'audio.json').write_text(json.dumps({'segments': [
        {'start': 1, 'end': 2.5, 'text': 'Синтетическая фраза.', 'speaker': 'SPEAKER_00'},
    ]}))
    return Library(tmp_path)


def request(library, path, *, headers=None, method='GET', delete=None, runtime=None):
    """Exercise the real HTTP handler with in-memory transport; no live server."""
    raw = f'{method} {path} HTTP/1.0\r\n'
    raw += ''.join(f'{k}: {v}\r\n' for k, v in {'Host': '127.0.0.1:20001', **(headers or {})}.items())

    class Socket:
        output = io.BytesIO()

        def makefile(self, *_args):
            return io.BytesIO((raw + '\r\n').encode())

        def sendall(self, data):
            self.output.write(data)

    sock = Socket()
    assets = Path(__file__).resolve().parents[3] / 'web-local'
    handler(library, assets, delete, runtime)(sock, ('127.0.0.1', 1234), SimpleNamespace(server_port=20001))
    head, body = sock.output.getvalue().split(b'\r\n\r\n', 1)
    lines = head.decode().split('\r\n')
    return int(lines[0].split()[1]), dict(line.split(': ', 1) for line in lines[1:]), body


def test_catalogue_detail_and_audio_seek_are_exact_and_read_only(library):
    before = {p: p.read_bytes() for p in library.captures.parent.parent.rglob('*') if p.is_file()}
    status, headers, body = request(library, '/api/recordings')
    assert status == 200 and headers['Cache-Control'] == 'no-store'
    data = json.loads(body)['recordings']
    assert len(data) == 1 and data[0]['status'] == 'ready'
    assert b'synthetic-session' not in body and b'synthetic-private-owner' not in body
    path = '/api/recordings/' + data[0]['id']
    assert json.loads(request(library, path)[2])['segments'][0]['start'] == 1
    audio = library.get(data[0]['id'])['audio'].read_bytes()
    for value, start, end in [('bytes=32044-64043', 32044, 64043), ('bytes=-16', len(audio)-16, len(audio)-1), ('bytes=0-', 0, len(audio)-1)]:
        status, headers, body = request(library, path + '/audio', headers={'Range': value})
        assert status == 206
        assert headers['Content-Range'] == f'bytes {start}-{end}/{len(audio)}'
        assert body == audio[start:end+1]
    assert request(library, path + '/audio', method='HEAD')[2] == b''
    assert request(library, path + '/audio', headers={'Range': 'bytes=999999-'})[0] == 416
    assert before == {p: p.read_bytes() for p in before}


@pytest.mark.parametrize('headers', [
    {'Host': 'attacker.example:20001'}, {'Host': '127.0.0.1:20000'},
    {'Origin': 'https://attacker.example'}, {'Sec-Fetch-Site': 'cross-site'},
    {'X-Forwarded-For': '127.0.0.1'}, {'Forwarded': 'host=example.ngrok.app'},
])
def test_remote_browser_and_proxy_requests_cannot_read_library(library, headers):
    assert request(library, '/api/recordings', headers=headers)[0] == 403


def test_partial_symlink_missing_and_bad_transcript(library, tmp_path):
    folder = next(library.captures.iterdir())
    part = folder / 'audio.pcm.part'
    part.touch()
    assert library.scan() == []

    part.unlink()
    raw = library.transcripts / 'result/audio.json'
    raw.write_text('{broken')
    assert library.scan()[0]['status'] == 'failed'
    raw.unlink()
    assert library.scan()[0]['status'] == 'unavailable'
    assert request(library, '/api/recordings/../../pairing.json')[0] == 404
    audio = folder / 'audio.wav'
    outside = tmp_path / 'outside.wav'
    audio.rename(outside)
    audio.symlink_to(outside)
    assert library.scan() == []


def test_identical_audio_preserves_shared_transcript_until_last_copy(library, monkeypatch):
    import shutil
    from dev_harness import local_library_delete as deletion
    monkeypatch.setattr(deletion.safety, 'read_and_validate_sentinel', lambda *a, **k: None)
    services = library.captures.parent.parent
    cfg = SimpleNamespace(layout=SimpleNamespace(services_dir=services, state_root=services), repo_root=services, instance='fixture')
    audio = next(library.captures.glob('*/audio.wav'))
    duplicate = library.captures / 'synthetic-copy'
    shutil.copytree(audio.parent, duplicate)
    manifest = library.transcripts / 'result/manifest.json'
    manifest.write_text(json.dumps({**json.loads(manifest.read_text()), 'result_key': 'b' * 64}))
    calls = []
    result = deletion.delete_recording(cfg, audio, delete_database=lambda *a: calls.append(a))
    assert result['shared_transcript_preserved'] and not calls and manifest.exists()
    assert library.scan()[0]['status'] == 'ready'
    deletion.delete_recording(cfg, duplicate / 'audio.wav', delete_database=lambda *a: calls.append(a))
    assert len(calls) == 1 and not manifest.exists()


def test_wave_content_change_does_not_reuse_old_transcript(library):
    record = library.scan()[0]
    audio = library.get(record['id'])['audio']
    with audio.open('r+b') as stream:
        stream.seek(44)
        stream.write(b'\1\0')
    assert library.scan()[0]['status'] == 'unavailable'


def test_delete_requires_explicit_same_origin_request(library):
    record = library.scan()[0]
    path = '/api/recordings/' + record['id']
    deleted = []
    delete = lambda audio: deleted.append(audio) or {'status': 'deleted'}
    assert request(library, path, method='DELETE', delete=delete)[0] == 403
    assert not deleted
    headers = {'Origin': 'http://127.0.0.1:20001', 'X-Omiloc-Request': 'delete'}
    assert request(library, path, method='DELETE', headers=headers, delete=delete)[0] == 200
    assert deleted == [library.get(record['id'])['audio']]


def test_open_folders_uses_only_known_directories(library, monkeypatch):
    from dev_harness import local_library
    calls = []
    monkeypatch.setattr(local_library.sys, 'platform', 'darwin')
    monkeypatch.setattr(local_library.subprocess, 'run', lambda args, **kwargs: calls.append((args, kwargs)))
    headers = {'Origin': 'http://127.0.0.1:20001', 'X-Omiloc-Request': 'open-folder'}
    for name, folder in [('audio', library.captures), ('transcripts', library.transcripts)]:
        status, _, body = request(library, f'/api/folders/{name}/open', method='POST', headers=headers)
        assert status == 200 and json.loads(body) == {'status': 'opened'}
        assert calls[-1][0] == ['/usr/bin/open', '-a', 'Finder', str(folder.resolve())]
        assert calls[-1][1]['check'] and calls[-1][1]['timeout'] == 5
        assert str(folder).encode() not in body
    for name in ['../../private', 'unknown', 'audio/open?path=/tmp']:
        assert request(library, f'/api/folders/{name}/open', method='POST', headers=headers)[0] == 404
    assert request(library, '/api/folders/audio/open')[0] == 404
    assert len(calls) == 2


@pytest.mark.parametrize('override', [
    {'Origin': ''}, {'Origin': 'https://example.com'}, {'Host': 'example.com'},
    {'X-Omiloc-Request': ''}, {'Sec-Fetch-Site': 'cross-site'},
    {'Forwarded': 'host=example.com'}, {'X-Forwarded-Host': '127.0.0.1'},
])
def test_open_folder_rejects_nonlocal_requests(library, monkeypatch, override):
    calls = []
    monkeypatch.setattr(library, 'open_folder', calls.append)
    headers = {'Origin': 'http://127.0.0.1:20001', 'X-Omiloc-Request': 'open-folder', **override}
    assert request(library, '/api/folders/audio/open', method='POST', headers=headers)[0] == 403
    assert calls == []


def test_open_folder_failure_and_timeout_are_reported_without_paths(library, monkeypatch):
    from dev_harness import local_library
    headers = {'Origin': 'http://127.0.0.1:20001', 'X-Omiloc-Request': 'open-folder'}
    monkeypatch.setattr(local_library.sys, 'platform', 'darwin')
    for error, expected in [(OSError('private-path'), 503),
                            (local_library.subprocess.CalledProcessError(1, 'private-path'), 503),
                            (local_library.subprocess.TimeoutExpired('private-path', 5), 504)]:
        def fail(*args, **kwargs):
            raise error
        monkeypatch.setattr(local_library.subprocess, 'run', fail)
        status, _, body = request(library, '/api/folders/audio/open', method='POST', headers=headers)
        assert status == expected and b'private-path' not in body
    calls = []
    monkeypatch.setattr(local_library.subprocess, 'run', lambda *a, **k: calls.append(a))
    library.captures = library.captures.parent / 'missing'
    assert request(library, '/api/folders/audio/open', method='POST', headers=headers)[0] == 503
    assert calls == []


def test_delete_preserves_files_on_db_failure_and_busy_inference(library, monkeypatch):
    import fcntl
    from dev_harness import local_library_delete as deletion
    monkeypatch.setattr(deletion.safety, 'read_and_validate_sentinel', lambda *a, **k: None)
    services = library.captures.parent.parent
    cfg = SimpleNamespace(layout=SimpleNamespace(services_dir=services, state_root=services), repo_root=services, instance='fixture')
    audio = library.get(library.scan()[0]['id'])['audio']
    manifest = library.transcripts / 'result/manifest.json'
    data = json.loads(manifest.read_text())
    data['result_key'] = 'b' * 64
    manifest.write_text(json.dumps(data))
    def unavailable(*_args):
        raise deletion.DeleteError('database unavailable')
    with pytest.raises(deletion.DeleteError, match='database unavailable'):
        deletion.delete_recording(cfg, audio, delete_database=unavailable)
    assert audio.exists() and manifest.exists()
    with (library.transcripts / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with pytest.raises(deletion.DeleteError, match='распознавание'):
            deletion.delete_recording(cfg, audio, delete_database=unavailable)
    calls = []
    deletion.delete_recording(cfg, audio, delete_database=lambda *args: calls.append(args))
    assert len(calls) == 1 and calls[0][2] == ['b' * 64]
    assert not audio.exists() and not manifest.exists()
    assert library.scan() == []


@pytest.mark.parametrize('cached', [False, True])
def test_no_speech_result_keeps_audio_available(library, cached):
    raw = library.transcripts / 'result/audio.json'
    if cached:
        raw.write_text(json.dumps({'outcome': 'no_speech', 'segments': []}))
    else:
        raw.unlink()
        key = hashlib.sha256(next(library.captures.iterdir()).name.encode()).hexdigest()
        (library.transcripts / 'watch-queue.json').write_text(json.dumps({key: {'state': 'no_speech'}}))
    data = json.loads(request(library, '/api/recordings')[2])['recordings']
    assert data[0]['status'] == ('no_speech' if cached else 'unavailable')
    path = '/api/recordings/' + data[0]['id']
    assert json.loads(request(library, path)[2])['segments'] == []
    assert request(library, path + '/audio', headers={'Range': 'bytes=0-43'})[0] == 206


def test_changed_wav_does_not_reuse_no_speech_queue_status(library):
    raw = library.transcripts / 'result/audio.json'
    raw.write_text(json.dumps({'outcome': 'no_speech', 'segments': []}))
    folder = next(library.captures.iterdir())
    key = hashlib.sha256(folder.name.encode()).hexdigest()
    (library.transcripts / 'watch-queue.json').write_text(json.dumps({key: {'state': 'no_speech'}}))
    assert library.scan()[0]['status'] == 'no_speech'
    with (folder / 'audio.wav').open('r+b') as audio:
        audio.seek(44)
        audio.write(b'\1\0')
    assert library.scan()[0]['status'] == 'unavailable'


def test_runtime_read_is_same_origin_and_does_not_return_credentials(library, monkeypatch):
    import httpx
    from dev_harness import local_library_runtime as live
    from dev_harness.local_library_runtime import Runtime
    cfg = SimpleNamespace(repo_root=library.captures.parent.parent, backend_port=20000,
                          layout=SimpleNamespace(state_root=library.captures.parent.parent))
    runtime = Runtime(cfg)
    monkeypatch.setattr(live.local_env, 'read_env', lambda _: {'OMI_LOCAL_APP_KEY': 'synthetic-private-key'})
    def serve(req):
        assert req.headers['authorization'] == 'Bearer synthetic-private-key'
        assert str(req.url) == 'http://127.0.0.1:20000/v1/local/preview'
        return httpx.Response(200, json={'backend': 'ready', 'capture': {'state': 'received', 'frames_received': 1},
            'live_transcript': {'state': 'streaming', 'updates': 1},
            'sessions': [{'preview_id': 'ephemeral-draft', 'source': 'phone', 'text': 'Синтетический черновик'}]})
    factory = httpx.Client
    def client(**kwargs):
        assert kwargs['trust_env'] is False and kwargs['follow_redirects'] is False
        return factory(transport=httpx.MockTransport(serve), **kwargs)
    monkeypatch.setattr(live.httpx, 'Client', client)
    monkeypatch.setattr(runtime, '_final', lambda: {'state': 'ready', 'provider': 'Argmax',
        'jobs': dict.fromkeys(('pending', 'processing', 'completed', 'failed', 'no_speech'), 0)})
    status, headers, body = request(library, '/api/runtime', runtime=runtime)
    assert status == 200 and headers['Cache-Control'] == 'no-store'
    data = json.loads(body)
    assert data['sessions'][0]['text'] == 'Синтетический черновик'
    assert b'synthetic-private-key' not in body
    assert 'Синтетический черновик' not in json.dumps(data['events'], ensure_ascii=False)
    assert 'text' not in runtime.previous['sessions'][0]
    for headers in [{'Host': 'attacker.example'}, {'Origin': 'https://attacker.example'},
                    {'X-Forwarded-For': '127.0.0.1'}, {'Sec-Fetch-Site': 'cross-site'}]:
        assert request(library, '/api/runtime', headers=headers, runtime=runtime)[0] == 403
    def disconnected():
        raise httpx.ConnectError('synthetic-private-error')
    monkeypatch.setattr(runtime, '_preview', disconnected)
    runtime.checked_at = 0
    status, _, body = request(library, '/api/runtime', runtime=runtime)
    assert status == 200 and json.loads(body)['backend'] == 'unavailable'
    assert json.loads(body)['sessions'] == []
    assert b'synthetic-private-error' not in body


def test_runtime_journal_observes_final_completion_without_transcript(library):
    from copy import deepcopy
    from dev_harness.local_library_runtime import Runtime
    runtime = Runtime(None)
    current = {'backend': 'ready', 'sessions': [{'source': 'omi', 'preview_id': 'draft', 'text': 'Синтетическая речь'}],
               'capture': {'state': 'received'}, 'live_transcript': {'state': 'streaming', 'updates': 1},
               'final_stt': {'state': 'ready', 'jobs': dict.fromkeys(('pending', 'processing', 'completed', 'failed', 'no_speech'), 0)}}
    runtime._observe(deepcopy(current))
    current['sessions'] = []
    current['final_stt']['jobs']['processing'] = 1
    runtime._observe(deepcopy(current))
    current['final_stt']['jobs'].update(processing=0, completed=1)
    runtime._observe(deepcopy(current))
    messages = [event['message'] for event in runtime.events]
    assert 'Началось финальное распознавание.' in messages
    assert 'Финальный транскрипт сохранён и доступен в аудиотеке.' in messages
    assert 'Синтетическая речь' not in json.dumps(messages, ensure_ascii=False)
