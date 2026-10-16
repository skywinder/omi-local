"""Live-translation control frames reach the session host without touching audio or transcripts."""

import builtins
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from utils import local_live_preview
from utils.stt import speaker_identity


@pytest.fixture
def anyio_backend():
    return 'asyncio'


class _UnusedDependency:
    def __init__(self, *args, **kwargs):
        pytest.fail('Translation control reached an unrelated cloud/audio dependency')


@pytest.fixture
def listen_modules():
    """Load unchanged production classes without the unrelated cloud pipelines.

    The import override belongs only to these two module namespaces, never to
    builtins or sys.modules. Other tests keep their real modules and bindings.
    The exercised normalization and speaker epoch helpers remain real too.
    """
    real_helpers = {
        'utils.local_live_preview': local_live_preview,
        'utils.stt.speaker_identity': speaker_identity,
    }

    def isolated_import(name, globals=None, locals=None, fromlist=(), level=0):
        if name in real_helpers:
            return real_helpers[name]
        if name in {'lc3', 'opuslib'}:
            raise ModuleNotFoundError(name)
        if level or name.startswith(('database.', 'models.', 'utils.', 'config.')):
            if fromlist:
                return SimpleNamespace(**{symbol: _UnusedDependency for symbol in fromlist})
            # `import database.users as users_db` returns the top-level package.
            result = _UnusedDependency
            for part in reversed(name.split('.')[1:]):
                result = SimpleNamespace(**{part: result})
            return result
        return builtins.__import__(name, globals, locals, fromlist, level)

    def load(name):
        path = Path(__file__).resolve().parents[2] / 'routers' / 'listen' / f'{name}.py'
        spec = importlib.util.spec_from_file_location(f'routers.listen._translation_test_{name}', path)
        module = importlib.util.module_from_spec(spec)
        module.__dict__['__builtins__'] = {**vars(builtins), '__import__': isolated_import}
        spec.loader.exec_module(module)
        return module

    return load('receiver'), load('runtime')


class _FramesWebSocket:
    def __init__(self, frames):
        self.frames = iter(frames)

    async def receive(self):
        return next(self.frames)


@pytest.mark.anyio
async def test_translation_frame_is_dispatched_to_host_and_never_enqueued(listen_modules):
    receiver, _ = listen_modules
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
    await receiver.ListenReceiver(host, [], {}).receive_data()
    assert languages == ['en', None]
    assert received_segments == []
    assert host.state.close_code == 1000
    assert host.state.first_audio_byte_timestamp is None


def test_runtime_normalizes_language_and_updates_an_existing_preview(listen_modules):
    _, module = listen_modules
    calls = []
    runtime = module.ListenSessionRuntime.__new__(module.ListenSessionRuntime)
    runtime.live_translation_language = None
    runtime.local_preview = None
    runtime.set_live_translation(' DE ')
    assert runtime.live_translation_language == 'de'
    runtime.local_preview = SimpleNamespace(set_translation=calls.append)
    runtime.set_live_translation('en-US')
    runtime.set_live_translation('fr')
    assert runtime.live_translation_language == 'fr'
    assert calls == [None, 'fr']
