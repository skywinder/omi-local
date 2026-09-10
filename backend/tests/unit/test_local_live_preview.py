import asyncio
import json
import fcntl
from unittest.mock import AsyncMock

import pytest

from utils.local_live_preview import LocalLivePreview, PreviewSegment, preview_url
from utils import local_transcription_status


@pytest.fixture
def anyio_backend():
    return 'asyncio'


def test_full_snapshots_replace_retract_and_isolate_sessions():
    segment = PreviewSegment()
    first = segment.update({'lines': [], 'buffer_transcription': 'первый черновик'}, 4)
    second = segment.update({'lines': [{'text': 'первый', 'speaker': 1}, {'speaker': -2}],
                             'buffer_transcription': 'исправленный текст'}, 8)
    assert first[0]['id'] == second[0]['id']
    assert second[0]['text'] == 'первый исправленный текст'
    assert segment.update({'lines': [], 'buffer_transcription': ''}, 8)[0]['text'] == ''
    assert segment.update({'lines': [], 'buffer_transcription': ''}, 9) is None
    assert segment.id != PreviewSegment().id


def test_live_endpoint_is_opt_in_and_loopback_only(monkeypatch):
    monkeypatch.delenv('OMI_LOCAL_LIVE_PREVIEW_URL', raising=False)
    assert preview_url() is None
    for value in ['wss://example.com/asr', 'ws://localhost:8000/asr', 'ws://127.0.0.1:8000/asr?language=en']:
        monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', value)
        with pytest.raises(ValueError):
            preview_url()
    monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'ws://127.0.0.1:18090/asr')
    assert preview_url() == 'ws://127.0.0.1:18090/asr'


class Socket:
    def __init__(self):
        self.incoming = asyncio.Queue()
        self.sent = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        pass

    async def recv(self):
        return json.dumps({'type': 'config', 'useAudioWorklet': True})

    async def send(self, data):
        self.sent.append(data)
        message = ({'lines': [], 'buffer_transcription': 'проверка'} if data else {'type': 'ready_to_stop'})
        self.incoming.put_nowait(json.dumps(message))

    def __aiter__(self):
        return self

    async def __anext__(self):
        return await self.incoming.get()


@pytest.mark.anyio
async def test_pcm_preview_stop_drains_eof_and_next_session_is_empty(monkeypatch):
    socket = Socket()
    monkeypatch.setattr('utils.local_live_preview.websockets.connect', lambda *a, **kw: socket)
    send = AsyncMock()
    preview = LocalLivePreview('ws://127.0.0.1:18090/asr', send)
    pcm = b'\x01\x00' * 320
    preview.feed(pcm)
    for _ in range(20):
        await asyncio.sleep(0)
        if any(isinstance(call.args[0], list) for call in send.call_args_list):
            break
    assert send.call_args_list[0].args[0] == {
        'type': 'service_status', 'status': 'ready', 'provider': 'local_live_preview'}
    assert send.call_args.args[0][0]['text'] == 'проверка'
    await preview.finish()
    assert socket.sent == [pcm, b'']
    assert preview.eof_ack and not preview.failed
    assert preview.task.done() and preview.segment.text == ''
    preview.feed(pcm)
    assert preview.pending_bytes == 0


@pytest.mark.anyio
@pytest.mark.parametrize('mode,reason', [
    ('disabled', 'disabled'), ('invalid', 'invalid_configuration'),
    ('refused', 'unavailable'), ('busy', 'busy'), ('protocol', 'protocol_error'),
])
async def test_unavailable_preview_reports_fixed_status_without_stopping_capture(monkeypatch, mode, reason):
    from websockets.exceptions import ConnectionClosedError
    from websockets.frames import Close

    monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'ws://127.0.0.1:18090/asr')
    if mode == 'disabled':
        monkeypatch.delenv('OMI_LOCAL_LIVE_PREVIEW_URL')
    elif mode == 'invalid':
        monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'wss://private.example/asr')

    class BrokenSocket(Socket):
        async def recv(self):
            if mode == 'busy':
                raise ConnectionClosedError(Close(1013, 'live_preview_busy'), None)
            return 'invalid protocol with private content'

    def connect(*args, **kwargs):
        if mode == 'refused':
            raise ConnectionRefusedError('private socket details')
        return BrokenSocket()

    monkeypatch.setattr('utils.local_live_preview.websockets.connect', connect)
    send = AsyncMock()
    preview = LocalLivePreview.from_environment(send)
    preview.feed(b'\x01\x00')
    await preview.task
    await preview.failure_status_task
    assert send.call_args_list == [(({
        'type': 'service_status', 'status': 'stt_failed', 'provider': 'local_live_preview',
        'outcome': 'unavailable', 'reason': reason, 'retryable': False,
    },), {})]
    preview.feed(b'\x02\x00')
    await preview.finish()
    assert preview.pending_bytes == 0


@pytest.mark.anyio
@pytest.mark.parametrize('close_reason,status_reason', [
    ('live_preview_busy', 'busy'),
    ('final_transcription_busy', 'busy'),
    ('live_preview_recovering', 'recovering'),
    ('live_preview_unavailable', 'unavailable'),
    ('private adapter diagnostic', 'unavailable'),
])
async def test_adapter_1013_reason_uses_only_fixed_availability_values(monkeypatch, close_reason, status_reason):
    from websockets.exceptions import ConnectionClosedError
    from websockets.frames import Close

    class UnavailableSocket(Socket):
        async def recv(self):
            raise ConnectionClosedError(Close(1013, close_reason), None)

    monkeypatch.setattr('utils.local_live_preview.websockets.connect', lambda *args, **kwargs: UnavailableSocket())
    send = AsyncMock()
    preview = LocalLivePreview('ws://127.0.0.1:18090/asr', send)
    await preview.task
    await preview.failure_status_task
    send.assert_awaited_once_with({
        'type': 'service_status', 'status': 'stt_failed', 'provider': 'local_live_preview',
        'outcome': 'unavailable', 'reason': status_reason, 'retryable': False,
    })
    await preview.finish()


@pytest.mark.anyio
async def test_preview_capacity_failure_reports_once_even_before_adapter_task_starts(monkeypatch):
    send = AsyncMock()
    preview = LocalLivePreview('ws://127.0.0.1:18090/asr', send)
    preview.MAX_PENDING_BYTES = 1
    preview.feed(b'\x01\x00')
    preview.feed(b'\x01\x00')
    await preview.failure_status_task
    await preview.finish()
    send.assert_awaited_once()
    assert send.call_args.args[0]['reason'] == 'buffer_full'


def test_final_readiness_requires_enabled_config_and_actual_worker_lock(monkeypatch, tmp_path):
    monkeypatch.setenv('OMI_HARNESS_STATE_ROOT', str(tmp_path))
    assert local_transcription_status.final_status()['status'] == 'unavailable'
    config = tmp_path / 'stt-watch.json'
    config.write_text('{"enabled": false}')
    assert local_transcription_status.final_status()['status'] == 'disabled'
    config.write_text('{"enabled": true}')
    lock = tmp_path / 'services/local-transcripts/.watch.lock'
    lock.parent.mkdir(parents=True)
    lock.touch()
    assert local_transcription_status.final_status()['reason'] == 'worker_stopped'
    with lock.open('r') as worker:
        fcntl.flock(worker, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert local_transcription_status.final_status() == {'status': 'ready', 'reason': None}
    assert local_transcription_status.final_status()['status'] == 'unavailable'


@pytest.mark.parametrize('health,status', [
    ({'ready': True, 'active': False}, 'ready'),
    ({'ready': True, 'active': True}, 'busy'),
    ({'ready': False}, 'unavailable'),
    ({'ready': 'true'}, 'unavailable'),
    ([], 'unavailable'),
])
def test_live_readiness_observes_model_health_without_following_redirects(monkeypatch, health, status):
    from io import BytesIO

    monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'ws://127.0.0.1:18090/asr')
    class Response(BytesIO):
        status = 200
    class Opener:
        def open(self, url, timeout):
            assert url == 'http://127.0.0.1:18090/health' and timeout == 1
            return Response(json.dumps(health).encode())
    def build(*handlers):
        assert handlers[0].proxies == {}
        assert handlers[1].redirect_request(None, None, 302, None, None, 'https://private.example') is None
        return Opener()
    monkeypatch.setattr(local_transcription_status.urllib.request, 'build_opener', build)
    assert local_transcription_status.live_status()['status'] == status


def test_profile_status_is_opt_in_and_rejects_external_live_probe(monkeypatch):
    monkeypatch.setenv('OMI_ENV_STAGE', 'offline')
    monkeypatch.delenv('OMI_LOCAL_TRANSPORT', raising=False)
    assert local_transcription_status.local_transcription_status() is None
    monkeypatch.setenv('OMI_LOCAL_TRANSPORT', 'ngrok')
    monkeypatch.delenv('OMI_HARNESS_STATE_ROOT', raising=False)
    monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'wss://private.example/asr')
    def forbidden(*args, **kwargs):
        raise AssertionError('Invalid endpoint must never reach HTTP')
    monkeypatch.setattr(local_transcription_status.urllib.request, 'build_opener', forbidden)
    result = local_transcription_status.local_transcription_status()
    assert result['live']['status'] == 'unavailable'
    assert result['final']['status'] == 'unavailable'
    assert 'private' not in json.dumps(result)


@pytest.mark.anyio
async def test_connection_failure_does_not_escape_to_wav_capture(monkeypatch):
    def refused(*args, **kwargs):
        raise ConnectionRefusedError()
    monkeypatch.setattr('utils.local_live_preview.websockets.connect', refused)
    preview = LocalLivePreview('ws://127.0.0.1:18090/asr', AsyncMock())
    preview.feed(b'\x01\x00')
    await preview.finish()
    assert preview.failed and preview.task.done()
    assert preview.pending_bytes == 0
