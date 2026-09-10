import asyncio
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock
import uuid

import httpx
import pytest

from routers.listen import local_status, registry
from utils.local_live_preview import LocalLivePreview, PreviewSegment, preview_url
from utils.offline_audio_capture import OfflineAudioCapture


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
        if send.called:
            break
    send.assert_awaited_once()
    assert send.call_args.args[0][0]['text'] == 'проверка'
    await preview.finish()
    assert socket.sent == [pcm, b'']
    assert preview.eof_ack and not preview.failed
    assert preview.task.done() and preview.segment.text == ''
    preview.feed(pcm)
    assert preview.pending_bytes == 0


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


class StatusSession:
    def __init__(self, uid, sink=None, preview=None):
        self.request = SimpleNamespace(uid=uid)
        self.state = SimpleNamespace(active=True, shutdown_event=asyncio.Event())
        self.capture_sink = sink
        self.local_preview = preview


@pytest.mark.anyio
async def test_local_status_disabled_makes_no_worker_request(monkeypatch):
    monkeypatch.delenv('OMI_LOCAL_LIVE_PREVIEW_URL', raising=False)
    probe = AsyncMock(side_effect=AssertionError('disabled must not probe'))
    monkeypatch.setattr(local_status, '_worker_state', probe)
    assert await local_status.snapshot('synthetic-status-owner') == {
        'backend': 'ready',
        'capture': {'state': 'idle', 'audio_seconds': 0, 'frames_received': 0},
        'live_transcript': {'state': 'disabled', 'updates': 0},
    }
    probe.assert_not_called()


@pytest.mark.parametrize('status,body,expected', [
    (200, {'ready': True, 'active': False}, 'ready'),
    (200, {'ready': True, 'active': True}, 'busy'),
    (200, {'ready': False, 'active': False}, 'unavailable'),
    (200, {'ready': True, 'active': 'false'}, 'unavailable'),
    (200, ['not', 'health'], 'unavailable'),
    (302, {'ready': True, 'active': False}, 'unavailable'),
    (503, {}, 'unavailable'),
    (200, {'oversized': 'x' * 5000}, 'unavailable'),
    (None, None, 'unavailable'),
])
@pytest.mark.anyio
async def test_local_status_probes_only_bounded_loopback_health(monkeypatch, status, body, expected):
    monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'ws://127.0.0.1:18090/asr')
    calls = []

    def respond(request):
        calls.append(request)
        assert str(request.url) == 'http://127.0.0.1:18090/health'
        assert 'authorization' not in request.headers
        if status is None:
            raise httpx.ConnectError('synthetic unavailable')
        return httpx.Response(status, json=body, headers={'location': 'https://example.com/private'})

    async with httpx.AsyncClient(transport=httpx.MockTransport(respond), trust_env=False) as client:
        monkeypatch.setattr(local_status, 'get_local_preview_client', lambda: client)
        result = await local_status.snapshot('synthetic-status-owner')
    assert result['live_transcript'] == {'state': expected, 'updates': 0}
    assert len(calls) == 1


@pytest.mark.anyio
async def test_local_status_invalid_worker_config_is_unavailable_without_network(monkeypatch):
    monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'ws://example.com/asr')
    probe = AsyncMock(side_effect=AssertionError('invalid config must not probe'))
    monkeypatch.setattr(local_status, '_worker_state', probe)
    assert (await local_status.snapshot('synthetic-status-owner'))['live_transcript']['state'] == 'unavailable'
    probe.assert_not_called()


@pytest.mark.anyio
async def test_local_status_uses_active_owner_capture_counters(monkeypatch, tmp_path):
    monkeypatch.delenv('OMI_LOCAL_LIVE_PREVIEW_URL', raising=False)
    sink = OfflineAudioCapture(session_id=str(uuid.uuid4()), input_codec='pcm16', source='phone', root=tmp_path)
    other_sink = OfflineAudioCapture(session_id=str(uuid.uuid4()), input_codec='pcm16', source='phone', root=tmp_path)
    owner = StatusSession('synthetic-status-owner', sink)
    other = StatusSession('synthetic-other-owner', other_sink)
    registry.register(owner)
    registry.register(other)
    try:
        other_sink.record_decoded_frame(encoded_bytes=64000, pcm=b'\0\0' * 32000)
        assert (await local_status.snapshot(owner.request.uid))['capture']['state'] == 'waiting_audio'
        sink.record_decoded_frame(encoded_bytes=32000, pcm=b'\0\0' * 16000)
        assert (await local_status.snapshot(owner.request.uid))['capture'] == {
            'state': 'received', 'audio_seconds': 1.0, 'frames_received': 1,
        }
        sink.record_decode_error(encoded_bytes=1)
        assert (await local_status.snapshot(owner.request.uid))['capture'] == {
            'state': 'decode_error', 'audio_seconds': 1.0, 'frames_received': 2,
        }
        owner.state.active = False
        assert (await local_status.snapshot(owner.request.uid))['capture'] == {
            'state': 'idle', 'audio_seconds': 0, 'frames_received': 0,
        }
    finally:
        registry.unregister(owner)
        registry.unregister(other)
        sink.finalize()
        other_sink.finalize()


@pytest.mark.anyio
async def test_local_status_failed_preview_overrides_ready_worker(monkeypatch):
    monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'ws://127.0.0.1:18090/asr')

    def refused(*args, **kwargs):
        raise ConnectionRefusedError()

    monkeypatch.setattr('utils.local_live_preview.websockets.connect', refused)
    preview = LocalLivePreview('ws://127.0.0.1:18090/asr', AsyncMock())
    await preview.finish()
    probe = AsyncMock(return_value='ready')
    monkeypatch.setattr(local_status, '_worker_state', probe)
    owner = StatusSession('synthetic-status-owner', preview=preview)
    registry.register(owner)
    try:
        assert (await local_status.snapshot(owner.request.uid))['live_transcript'] == {'state': 'failed', 'updates': 0}
        probe.assert_not_called()
    finally:
        registry.unregister(owner)


@pytest.mark.anyio
async def test_local_status_reports_actual_preview_updates_and_forgets_closed_session(monkeypatch):
    monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'ws://127.0.0.1:18090/asr')
    socket = Socket()
    monkeypatch.setattr('utils.local_live_preview.websockets.connect', lambda *args, **kwargs: socket)
    sent = AsyncMock()
    preview = LocalLivePreview('ws://127.0.0.1:18090/asr', sent)
    owner = StatusSession('synthetic-status-owner', preview=preview)
    registry.register(owner)
    probe = AsyncMock(return_value='ready')
    monkeypatch.setattr(local_status, '_worker_state', probe)
    try:
        preview.feed(b'\0\0' * 320)
        for _ in range(20):
            await asyncio.sleep(0)
            if sent.called:
                break
        sent.assert_awaited_once()
        assert (await local_status.snapshot(owner.request.uid))['live_transcript'] == {
            'state': 'streaming', 'updates': 1,
        }
        probe.assert_not_called()
        owner.state.shutdown_event.set()
        assert (await local_status.snapshot(owner.request.uid))['live_transcript'] == {'state': 'ready', 'updates': 0}
        probe.assert_awaited_once()
    finally:
        registry.unregister(owner)
        await preview.finish()


@pytest.mark.anyio
async def test_library_draft_is_owner_scoped_and_disappears_after_stop(monkeypatch, tmp_path):
    monkeypatch.delenv('OMI_LOCAL_LIVE_PREVIEW_URL', raising=False)
    owners = []
    for uid, text in [('synthetic-owner', 'первый черновик'), ('synthetic-other', 'чужая речь')]:
        sink = OfflineAudioCapture(session_id=str(uuid.uuid4()), input_codec='pcm16', source='phone', root=tmp_path)
        sink.record_decoded_frame(encoded_bytes=640, pcm=b'\0\0' * 320)
        segment = PreviewSegment()
        segment.update({'lines': [], 'buffer_transcription': text}, .02)
        preview = SimpleNamespace(segment=segment, updates=1, failed=False)
        owner = StatusSession(uid, sink, preview)
        owners.append(owner)
        registry.register(owner)
    try:
        data = await local_status.preview_snapshot('synthetic-owner')
        assert len(data['sessions']) == 1
        draft = data['sessions'][0]
        assert draft['source'] == 'phone' and draft['codec'] == 'pcm16'
        assert draft['text'] == 'первый черновик' and draft['frames_received'] == 1
        assert owners[0].capture_sink.session_id not in json.dumps(data)
        assert 'чужая речь' not in json.dumps(data, ensure_ascii=False)
        status = await local_status.snapshot('synthetic-owner')
        assert 'sessions' not in status and 'text' not in status['live_transcript']
        owners[0].local_preview.segment.update({'lines': [], 'buffer_transcription': 'исправлено'}, .02)
        assert (await local_status.preview_snapshot('synthetic-owner'))['sessions'][0]['text'] == 'исправлено'
        owners[0].state.shutdown_event.set()
        assert (await local_status.preview_snapshot('synthetic-owner'))['sessions'] == []
    finally:
        for owner in owners:
            registry.unregister(owner)
            owner.capture_sink.finalize()
