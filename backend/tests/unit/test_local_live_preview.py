import asyncio
import json
from unittest.mock import AsyncMock

import pytest

from utils.local_live_preview import LocalLivePreview, PreviewSegment, preview_url


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
