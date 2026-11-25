import asyncio
import copy
import json
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dev_harness import local_provider_relay as relay
from dev_harness.local_live_tuning import Controls, Session, validate
from dev_harness.local_providers import SettingsError
from test_local_provider_relay import Provider, Registry, profile

CAPABILITY = {'version': 1, 'settings': {'asr_coalesce_min_s': 2.0, 'max_speakers': 2}}


async def capability(*args): return copy.deepcopy(CAPABILITY)


@pytest.fixture
def cfg(tmp_path):
    return SimpleNamespace(repo_root=tmp_path, backend_port=20000, layout=SimpleNamespace(state_root=tmp_path))


def test_stream_controls_preserve_audio_and_acknowledge_new_values_without_reconnect(cfg):
    class TunableProvider(Provider):
        def __init__(self):
            super().__init__()
            self.updates = []
            self.applied = asyncio.Event()

        async def recv(self):
            return json.dumps({'type': 'config', 'useAudioWorklet': True, 'live_tuning': CAPABILITY})

        async def send(self, data):
            if isinstance(data, str):
                control = json.loads(data)
                self.updates.append(control)
                self.incoming.put_nowait(json.dumps({'type': 'live_tuning_ack', 'status': 'applied',
                    'revision': control['revision'], 'settings': control['settings']}))
                self.applied.set()
            else:
                await super().send(data)

    providers = []
    def connect(*args, **kwargs):
        providers.append(TunableProvider())
        return providers[-1]
    registry = Registry(profile(preview_mode='draft'))
    app = relay.create_app(cfg, registry=registry, connector=connect)
    app.state.live_controls.capability_probe = capability
    with TestClient(app, client=('127.0.0.1', 1234)) as client:
        initial = client.get('/tuning').json()
        with client.websocket_connect('/asr') as socket:
            socket.receive_json()
            assert socket.receive_json() == {'type': 'live_tuning_status', 'status': 'applied',
                                              'revision': initial['revision'], 'max_speakers': 2}
            socket.send_bytes(b'\x01\x00')
            assert socket.receive_json()['buffer_transcription'] == 'draft'
            changed = {'revision': initial['revision'], 'settings': {
                'asr_coalesce_min_s': 3.5, 'max_speakers': 3, 'preview_mode': 'stable'}}
            providers[0].applied.clear()
            result = client.post('/tuning', json=changed)
            assert result.status_code == 200
            client.portal.call(asyncio.wait_for, providers[0].applied.wait(), 2)
            assert socket.receive_json() == {'type': 'live_tuning_status', 'status': 'applied',
                                              'revision': result.json()['revision'], 'max_speakers': 3}
            socket.send_bytes(b'\x02\x00')
            assert socket.receive_json()['buffer_transcription'] == ''
            state = client.get('/tuning').json()
            assert state['applied_sessions'] == state['active_sessions'] == 1
            assert state['failed_sessions'] == 0
            assert client.post('/tuning', json=changed).status_code == 409
            socket.send_bytes(b'')
            while socket.receive_json().get('type') != 'ready_to_stop': pass
        assert len(providers) == 1
        assert providers[0].sent == [b'\x01\x00', b'\x02\x00', b'']
        assert providers[0].updates[-1]['settings'] == {'asr_coalesce_min_s': 3.5, 'max_speakers': 3}
        restarted = Controls(cfg, registry, capability_probe=capability)
        assert asyncio.run(restarted.read())['settings'] == changed['settings']
        registry.value = profile('wss://another.example/asr')
        assert asyncio.run(restarted.read())['settings']['asr_coalesce_min_s'] == 2
        assert client.post('/tuning', json=changed, headers={'Origin': 'https://outside.example'}).status_code == 403


def test_unsupported_server_and_invalid_values_do_not_change_saved_state(cfg):
    async def unsupported(*args): return None
    controls = Controls(cfg, Registry(profile()), capability_probe=unsupported)
    assert asyncio.run(controls.read())['available'] is False
    assert controls.attach(profile(), {'live_tuning': 'invalid'}) is None
    assert controls.attach(profile(), {'live_tuning': {'version': 1, 'settings': {'max_speakers': 5}}}) is None
    with pytest.raises(SettingsError):
        asyncio.run(controls.update({'revision': 0, 'settings': {}}))
    assert not controls.path.exists()
    for invalid in [True, float('nan'), -1, 11, '2']:
        with pytest.raises(SettingsError):
            validate({'asr_coalesce_min_s': invalid, 'max_speakers': 2, 'preview_mode': 'stable'})


@pytest.mark.parametrize(('extra', 'expected'), [
    ({}, None), ({'source_language': 'auto'}, 'auto'), ({'source_language': 'ru'}, 'ru'),
    ({'source_language': 'RU'}, None), ({'source_language': 'private-url'}, None),
    ({'source_language': True}, None),
])
def test_source_language_requires_explicit_bounded_provider_capability(cfg, monkeypatch, extra, expected):
    import httpx
    from dev_harness import local_live_tuning
    async def exercise():
        async def handle(_request):
            return httpx.Response(200, json={'live_tuning': CAPABILITY, **extra})
        original = httpx.AsyncClient
        monkeypatch.setattr(local_live_tuning.httpx, 'AsyncClient',
                            lambda **kwargs: original(transport=httpx.MockTransport(handle), **kwargs))
        controls = Controls(cfg, Registry(profile()))
        assert (await controls.read())['source_language'] == expected
    asyncio.run(exercise())


def test_conflicting_source_language_capabilities_are_not_reported(cfg, monkeypatch):
    import httpx
    from dev_harness import local_live_tuning
    async def exercise():
        async def handle(_request):
            return httpx.Response(200, json={'source_language': 'auto',
                'live_tuning': {**CAPABILITY, 'source_language': 'en'}})
        original = httpx.AsyncClient
        monkeypatch.setattr(local_live_tuning.httpx, 'AsyncClient',
                            lambda **kwargs: original(transport=httpx.MockTransport(handle), **kwargs))
        assert (await Controls(cfg, Registry(profile())).read())['source_language'] is None
    asyncio.run(exercise())


def test_next_session_setting_reaches_new_stream_and_ack_without_touching_old(cfg):
    class TunableProvider(Provider):
        def __init__(self):
            super().__init__()
            self.updates = []
        async def recv(self):
            return json.dumps({'type': 'config', 'useAudioWorklet': True, 'live_tuning': CAPABILITY})
        async def send(self, data):
            if isinstance(data, str):
                control = json.loads(data)
                self.updates.append(control)
                self.incoming.put_nowait(json.dumps({'type': 'live_tuning_ack', 'status': 'applied',
                    'revision': control['revision'], 'settings': control['settings']}))
            else:
                await super().send(data)

    providers = []
    def connect(*args, **kwargs):
        providers.append(TunableProvider())
        return providers[-1]
    app = relay.create_app(cfg, registry=Registry(profile()), connector=connect)
    app.state.live_controls.capability_probe = capability
    with TestClient(app, client=('127.0.0.1', 1234)) as client:
        with client.websocket_connect('/asr') as old:
            old.receive_json()
            assert old.receive_json() == {'type': 'live_tuning_status', 'status': 'applied',
                                          'revision': 0, 'max_speakers': 2}
            old.send_bytes(b'\x01\x00')
            old.receive_json()
            before = client.get('/tuning').json()
            assert providers[0].updates[-1]['settings']['max_speakers'] == 2
            result = client.post('/tuning/next-session', json={'revision': before['revision'], 'max_speakers': 4})
            assert result.status_code == 200 and len(providers[0].updates) == 1
            pending = result.json()
            admin_settings = {**pending['settings'], 'asr_coalesce_min_s': 3.0}
            admin = client.post('/tuning', json={'revision': pending['revision'], 'settings': admin_settings,
                                                  'changed_fields': ['asr_coalesce_min_s']})
            assert admin.status_code == 200
            assert old.receive_json() == {'type': 'live_tuning_status', 'status': 'applied',
                                          'revision': admin.json()['revision'], 'max_speakers': 2}
            assert providers[0].updates[-1]['settings'] == {'asr_coalesce_min_s': 3.0, 'max_speakers': 2}
            assert client.get('/tuning').json()['pending_sessions'] == 1
            with client.websocket_connect('/asr') as new:
                new.receive_json()
                assert new.receive_json() == {'type': 'live_tuning_status', 'status': 'applied',
                                              'revision': admin.json()['revision'], 'max_speakers': 4}
                new.send_bytes(b'\x02\x00')
                new.receive_json()
                assert providers[1].updates[-1]['settings']['max_speakers'] == 4
                assert providers[1].updates[-1]['revision'] == admin.json()['revision']
                assert client.get('/tuning').json()['applied_sessions'] == 1
                # The admin can explicitly apply the same saved speaker limit now.
                manual = client.post('/tuning', json={'revision': admin.json()['revision'], 'settings': admin_settings,
                                                       'changed_fields': ['max_speakers']})
                assert manual.status_code == 200
                assert old.receive_json() == {'type': 'live_tuning_status', 'status': 'applied',
                                              'revision': manual.json()['revision'], 'max_speakers': 4}
                assert new.receive_json() == {'type': 'live_tuning_status', 'status': 'applied',
                                              'revision': manual.json()['revision'], 'max_speakers': 4}
                assert providers[0].updates[-1]['settings']['max_speakers'] == 4
                assert client.get('/tuning').json()['applied_sessions'] == 2
                new.send_bytes(b'')
                while new.receive_json().get('type') != 'ready_to_stop': pass
            old.send_bytes(b'')
            while old.receive_json().get('type') != 'ready_to_stop': pass


def test_next_session_limit_does_not_update_current_stream_and_shares_revision(cfg):
    async def exercise():
        registry = Registry(profile(preview_mode='draft'))
        controls = Controls(cfg, registry, capability_probe=capability)
        snapshot = registry.snapshot('live')
        current = controls.attach(snapshot, {'live_tuning': CAPABILITY})
        before = await controls.read()
        assert before['source_language'] is None
        current.changed.clear()
        saved = await controls.update_next_session({'revision': before['revision'], 'max_speakers': 4})
        assert saved['settings'] == {**before['settings'], 'max_speakers': 4}
        assert not current.changed.is_set()
        assert current.settings == before['settings']
        future = controls.attach(snapshot, {'live_tuning': CAPABILITY})
        assert future.settings == saved['settings'] and future.revision == saved['revision']
        assert saved['applied_sessions'] == 0
        with pytest.raises(SettingsError) as stale:
            await controls.update({'revision': before['revision'], 'settings': before['settings']})
        assert stale.value.status == 409
        with pytest.raises(SettingsError):
            await controls.update_next_session({'revision': saved['revision'], 'max_speakers': 5})
        with pytest.raises(SettingsError):
            await controls.update_next_session({'revision': saved['revision'], 'max_speakers': True})
        assert (await controls.read())['settings'] == saved['settings']
        admin = await controls.update({'revision': saved['revision'], 'settings': before['settings']})
        assert admin['revision'] == saved['revision'] + 1
        assert current.changed.is_set() and future.changed.is_set()
    asyncio.run(exercise())


def test_next_session_endpoint_rejects_untrusted_origin_and_unsupported_provider(cfg):
    registry = Registry(profile())
    app = relay.create_app(cfg, registry=registry)
    async def unsupported(*args): return None
    app.state.live_controls.capability_probe = unsupported
    with TestClient(app, client=('127.0.0.1', 1234)) as client:
        body = {'revision': 0, 'max_speakers': 3}
        assert client.post('/tuning/next-session', json=body, headers={'Origin': 'https://outside.example'}).status_code == 403
        assert client.post('/tuning/next-session', json=body).status_code == 409
        assert not app.state.live_controls.path.exists()


def test_rejected_and_stale_acks_never_report_applied():
    async def exercise():
        session = Session({'asr_coalesce_min_s': 2, 'max_speakers': 2, 'preview_mode': 'stable'}, 4)
        class RejectingProvider:
            async def send(self, message):
                assert session.acknowledge({'type': 'live_tuning_ack', 'revision': 3, 'status': 'applied'})
                assert not session.ack.done()
                session.acknowledge({'type': 'live_tuning_ack', 'revision': 4, 'status': 'rejected'})
        snapshot = profile(preview_mode='draft')
        task = asyncio.create_task(session.run(RejectingProvider(), snapshot))
        await asyncio.wait_for(session.ready.wait(), 2)
        assert session.error and session.applied_revision is None
        assert snapshot['settings']['preview_mode'] == 'draft'
        task.cancel()
        with pytest.raises(asyncio.CancelledError): await task
    asyncio.run(exercise())


@pytest.mark.parametrize('timeout', [False, True])
def test_session_failure_status_is_for_its_revision_and_does_not_stop_audio(monkeypatch, timeout):
    from dev_harness import local_live_tuning
    async def exercise():
        session = Session({'asr_coalesce_min_s': 2, 'max_speakers': 3, 'preview_mode': 'draft'}, 8)
        statuses = []
        reported = asyncio.Event()
        async def status(message):
            statuses.append(message)
            reported.set()
        class Provider:
            async def send(self, message):
                if not timeout:
                    session.acknowledge({'type': 'live_tuning_ack', 'revision': 8, 'status': 'rejected'})
        if timeout:
            monkeypatch.setattr(local_live_tuning, 'ACK_TIMEOUT_SECONDS', 0)
        task = asyncio.create_task(session.run(Provider(), profile(), status))
        await asyncio.wait_for(session.ready.wait(), 2)
        await asyncio.wait_for(reported.wait(), 2)
        assert statuses == [{'type': 'live_tuning_status', 'status': 'failed', 'revision': 8, 'max_speakers': 3}]
        assert session.error and session.applied_revision is None
        task.cancel()
        with pytest.raises(asyncio.CancelledError): await task
    asyncio.run(exercise())


def test_blocked_tuning_status_does_not_block_audio(monkeypatch):
    from dev_harness import local_live_tuning
    async def exercise():
        session = Session({'asr_coalesce_min_s': 2, 'max_speakers': 2, 'preview_mode': 'draft'}, 1)
        entered, cancelled = asyncio.Event(), asyncio.Event()
        async def status(_message):
            entered.set()
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()
        class Provider:
            async def send(self, message):
                control = json.loads(message)
                session.acknowledge({'type': 'live_tuning_ack', 'revision': 1, 'status': 'applied',
                                     'settings': control['settings']})
        monkeypatch.setattr(local_live_tuning, 'STATUS_SEND_TIMEOUT_SECONDS', 0.05)
        task = asyncio.create_task(session.run(Provider(), profile(), status))
        await asyncio.wait_for(entered.wait(), 2)
        # relay_session.feed waits on this gate before forwarding PCM.
        await asyncio.wait_for(session.ready.wait(), 0.01)
        await asyncio.wait_for(cancelled.wait(), 2)
        task.cancel()
        with pytest.raises(asyncio.CancelledError): await task
    asyncio.run(exercise())


def test_relay_forwards_audio_while_downstream_status_is_blocked(cfg):
    async def exercise():
        entered = asyncio.Event()
        pcm_forwarded = asyncio.Event()
        class BlockingDownstream:
            frames = iter([b'\x01\x00', b''])
            async def send_text(self, raw):
                if json.loads(raw).get('type') == 'live_tuning_status':
                    entered.set()
                    await asyncio.Event().wait()
            async def receive(self):
                await entered.wait()
                return {'type': 'websocket.receive', 'bytes': next(self.frames)}
        class StreamingProvider(Provider):
            async def recv(self):
                return json.dumps({'type': 'config', 'useAudioWorklet': True, 'live_tuning': CAPABILITY})
            async def send(self, data):
                if isinstance(data, str):
                    control = json.loads(data)
                    self.incoming.put_nowait(json.dumps({'type': 'live_tuning_ack', 'status': 'applied',
                        'revision': control['revision'], 'settings': control['settings']}))
                elif data:
                    pcm_forwarded.set()
                else:
                    self.incoming.put_nowait(json.dumps({'type': 'ready_to_stop'}))
        registry = Registry(profile())
        provider = StreamingProvider()
        controls = Controls(cfg, registry, capability_probe=capability)
        await asyncio.wait_for(relay.relay_session(BlockingDownstream(), registry.snapshot('live'), cfg,
            connector=lambda *args, **kwargs: provider, controls=controls), 2)
        assert pcm_forwarded.is_set()
    asyncio.run(exercise())
