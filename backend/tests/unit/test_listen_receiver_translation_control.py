"""Live-translation control frames reach the session host without touching audio or transcripts."""

import json
from types import SimpleNamespace

import pytest

from routers.listen.receiver import ListenReceiver
from routers.listen.runtime import ListenSessionRuntime
from utils.product_telemetry import set_product_telemetry_client_for_tests


@pytest.fixture
def anyio_backend():
    return 'asyncio'


@pytest.fixture(autouse=True)
def _reset_product_telemetry_client():
    yield
    set_product_telemetry_client_for_tests(None)


class _FramesWebSocket:
    def __init__(self, frames):
        self.frames = iter(frames)

    async def receive(self):
        return next(self.frames)


@pytest.mark.anyio
async def test_translation_frame_is_dispatched_to_host_and_never_enqueued():
    received_segments = []
    languages = []
    websocket = _FramesWebSocket([
        {'text': json.dumps({'type': 'translation', 'language': 'en'})},
        {'text': json.dumps({'type': 'translation'})},
        {'type': 'websocket.disconnect', 'code': 1000},
    ])
    host = SimpleNamespace(
        request=SimpleNamespace(websocket=websocket, codec='pcm16'),
        state=SimpleNamespace(active=True, close_code=1001, last_audio_received_time=None, last_activity_time=None,
                              first_audio_byte_timestamp=None, last_usage_record_timestamp=None,
                              audio_ring_buffer=None),
        limits=SimpleNamespace(ws_receive_timeout=1.0),
        is_multi_channel=False,
        use_custom_stt=True,
        audio_bytes_send=None,
        transcripts=SimpleNamespace(enqueue=received_segments.extend),
        set_live_translation=languages.append,
    )
    await ListenReceiver(host, [], {}).receive_data()
    assert languages == ['en', None]
    assert received_segments == []


def test_runtime_normalizes_language_and_updates_an_existing_preview():
    calls = []
    runtime = ListenSessionRuntime.__new__(ListenSessionRuntime)
    runtime.live_translation_language = None
    runtime.local_preview = None
    runtime.set_live_translation(' DE ')
    assert runtime.live_translation_language == 'de'
    runtime.local_preview = SimpleNamespace(set_translation=calls.append)
    runtime.set_live_translation('en-US')
    runtime.set_live_translation('fr')
    assert runtime.live_translation_language == 'fr'
    assert calls == [None, 'fr']
