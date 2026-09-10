import io
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dev_harness.local_providers import Registry, SettingsError
from dev_harness.local_provider_api import Settings
from dev_harness.local_provider_http import validate_url
from dev_harness.local_provider_probe import probe
from dev_harness.local_library import Library, handler


@pytest.fixture
def cfg(tmp_path):
    state = tmp_path / 'state'
    state.mkdir()
    (state / 'stt-engine.json').write_text(json.dumps({'engine': 'openai-compatible',
        'provider_url': 'http://127.0.0.1:10301/v1', 'model': 'synthetic', 'language': 'auto', 'diarization_model': 'none'}))
    return SimpleNamespace(repo_root=tmp_path, backend_port=20000,
                           layout=SimpleNamespace(state_root=state, services_dir=tmp_path / 'services'))


def summary(name='Synthetic LLM', base='https://llm.example/v1'):
    return {'name': name, 'stage': 'summary', 'kind': 'openai-compatible',
            'settings': {'base_url': base, 'model': 'synthetic-model'}}


def test_drafts_are_separate_and_secrets_keep_pinned_versions(cfg):
    registry = Registry(cfg)
    original = (registry.root / 'stt-engine.json').read_bytes()
    initial = registry.read()
    assert not registry.exists and initial['active']['stt'] == 'current-stt'
    saved = registry.save({'revision': 0, 'profile': summary(), 'api_key': 'test-secret-first'})
    profile = saved['profiles'][-1]
    assert profile['has_key'] and saved['active']['summary'] is None
    assert 'test-secret' not in json.dumps(saved)
    assert 'credential_ref' not in json.dumps(saved)
    assert (os.stat(registry.secrets_path).st_mode & 0o777) == 0o600
    activated = registry.activate({'revision': 1, 'stage': 'summary', 'id': profile['id']},
                                  prepare=lambda _snapshot, publish: publish())
    pinned = registry.pipeline()['summary']
    edited = registry.save({'revision': 2, 'profile': {**profile, 'name': 'Renamed'}, 'api_key': 'test-secret-second'})
    assert edited['effective']['summary']['name'] == 'Synthetic LLM'
    assert registry.key(pinned) == 'test-secret-first'
    draft, key = registry.draft({'profile': edited['profiles'][-1]})
    assert key == 'test-secret-second'
    assert registry.key(draft) == key
    assert (registry.root / 'stt-engine.json').read_bytes() == original


def test_changed_endpoint_never_inherits_saved_key_in_probe_or_save(cfg):
    registry = Registry(cfg)
    profile = registry.save({'revision': 0, 'profile': summary(), 'api_key': 'private-test-key'})['profiles'][-1]
    changed = {**profile, 'settings': {'base_url': 'https://different.example/v1', 'model': 'new'}}
    assert registry.draft({'profile': changed})[1] == ''
    updated = registry.save({'revision': 1, 'profile': changed})
    assert updated['profiles'][-1]['has_key'] is False
    assert registry.draft({'profile': updated['profiles'][-1]})[1] == ''


def test_failed_activation_restores_effective_and_rejects_stale_edits(cfg):
    registry = Registry(cfg)
    saved = registry.save({'revision': 0, 'profile': summary()})
    def fail(_snapshot, publish):
        publish()
        raise SettingsError('Synthetic startup failed', status=409)
    with pytest.raises(SettingsError):
        registry.activate({'revision': 1, 'stage': 'summary', 'id': saved['profiles'][-1]['id']}, prepare=fail)
    assert registry.read() == saved
    with pytest.raises(SettingsError, match='другом окне'):
        registry.save({'revision': 0, 'profile': summary()})
    assert registry.read() == saved


def test_clear_key_keeps_active_and_queued_secret_until_explicit_apply(cfg):
    registry = Registry(cfg)
    saved = registry.save({'revision': 0, 'profile': summary(), 'api_key': 'old-test-key'})
    profile = saved['profiles'][-1]
    registry.activate({'revision': 1, 'stage': 'summary', 'id': profile['id']}, prepare=lambda _, publish: publish())
    pinned = registry.pipeline()['summary']
    cleared = registry.save({'revision': 2, 'profile': profile, 'clear_key': True})
    assert not cleared['profiles'][-1]['has_key'] and cleared['effective']['summary']['has_key']
    assert registry.key(pinned) == 'old-test-key'
    with pytest.raises(SettingsError):
        registry.delete(profile['id'], 3)
    registry.activate({'revision': 3, 'stage': 'summary', 'id': None}, prepare=lambda _, publish: publish())
    registry.delete(profile['id'], 4)
    assert registry.key(pinned) == 'old-test-key'


@pytest.mark.parametrize('managed', [False, True])
def test_first_save_preserves_resolved_legacy_diarization(cfg, monkeypatch, managed):
    from dev_harness.local_stt import EngineConfig
    from dev_harness import stt_install
    legacy = {} if managed else {'engine': 'whisperx', 'model': 'small', 'language': 'ru'}
    (cfg.layout.state_root / 'stt-engine.json').write_text(json.dumps(legacy))
    if managed:
        (cfg.repo_root / '.local/stt').mkdir(parents=True)
        monkeypatch.setattr(stt_install, 'installed', lambda _: Path('/synthetic/whisperx/bin/python'))
    before = EngineConfig.load(cfg)
    registry = Registry(cfg)
    initial = registry.read()
    assert not registry.exists
    registry.save({'revision': 0, 'profile': summary()})
    after = EngineConfig.load(cfg)
    assert after.diarization_model == before.diarization_model
    assert after.python == before.python and after.model == before.model
    assert bool(initial['effective']['diarization']) == (before.diarization_model != 'none')


def test_stt_switch_cannot_silently_discard_or_restore_embedded_diarization(cfg):
    from dev_harness.local_stt import EngineConfig
    (cfg.layout.state_root / 'stt-engine.json').write_text(json.dumps(
        {'engine': 'whisperx', 'model': 'small', 'language': 'ru'}))
    registry = Registry(cfg)
    remote = {'name': 'Remote STT', 'stage': 'stt', 'kind': 'openai-compatible',
              'settings': {'provider_url': 'https://stt.example/v1', 'model': 'test', 'language': 'auto'}}
    saved = registry.save({'revision': 0, 'profile': remote})
    activate = lambda stage, profile_id: registry.activate(
        {'revision': registry.read()['revision'], 'stage': stage, 'id': profile_id},
        prepare=lambda _, publish: publish())
    with pytest.raises(SettingsError, match='отдельного провайдера'):
        activate('stt', saved['profiles'][-1]['id'])
    assert registry.read() == saved
    activate('diarization', None)
    activate('stt', 'current-stt')
    assert EngineConfig.load(cfg).diarization_model == 'none'
    activate('stt', saved['profiles'][-1]['id'])
    with pytest.raises(SettingsError, match='отдельного провайдера'):
        activate('diarization', 'current-diarization')
    assert registry.snapshot('diarization') is None


@pytest.mark.parametrize('model', ['bad\x7fmodel', 'bad\x85model', 'bad\u200bmodel'])
def test_model_control_characters_are_rejected_consistently(cfg, model):
    from dev_harness.local_provider_http import model_ids
    profile = summary()
    profile['settings']['model'] = model
    with pytest.raises(SettingsError):
        Registry(cfg).save({'revision': 0, 'profile': profile})
    assert model_ids({'data': [{'id': model}, {'id': 'namespace:model'}]}) == ['namespace:model']


@pytest.mark.parametrize('endpoint,ws', [
    ('http://8.8.8.8/v1', False), ('ws://8.8.8.8/asr', True),
    ('https://user:key@example.com/v1', False), ('https://example.com/v1?key=secret', False),
    ('http://169.254.169.254/latest', False), ('https://example.com/v1\n', False),
])
def test_endpoint_policy_rejects_plain_public_metadata_and_embedded_keys(endpoint, ws):
    with pytest.raises(ValueError):
        validate_url(endpoint, websocket=ws)


def test_explicit_tls_and_lan_destinations_are_supported():
    assert validate_url('https://example.com/v1/') == 'https://example.com/v1'
    assert validate_url('http://192.168.1.2:8000/v1')
    assert validate_url('ws://100.100.1.2/asr', websocket=True)


def test_probe_never_sends_audio_and_does_not_follow_not_ready_to_health(cfg, monkeypatch):
    seen = []
    def respond(request):
        seen.append(request)
        assert request.method == 'GET' and request.content == b''
        return httpx.Response(503, json={'ready': False, 'private': 'must not reach UI'})
    from dev_harness import local_provider_probe
    monkeypatch.setattr(local_provider_probe.transport, 'client',
                        lambda **kwargs: httpx.Client(transport=httpx.MockTransport(respond)))
    report = probe(cfg, {'stage': 'diarization', 'kind': 'mycelia', 'settings': {'base_url': 'https://test.example'}})
    assert report['state'] == 'unavailable' and len(seen) == 1
    assert seen[0].url.path == '/ready'
    assert 'private' not in json.dumps(report)


def test_model_discovery_accepts_blank_model_but_save_reports_field(cfg, monkeypatch):
    api = Settings(cfg)
    draft = summary()
    draft['settings']['model'] = ''
    from dev_harness import local_provider_probe
    transport = httpx.MockTransport(lambda _: httpx.Response(200, json={'data': [{'id': 'namespace:model'}]}))
    monkeypatch.setattr(local_provider_probe.transport, 'client', lambda **_: httpx.Client(transport=transport))
    result = api.dispatch('POST', '/api/settings/models', {'profile': draft})
    assert result['models'] == ['namespace:model']
    with pytest.raises(SettingsError) as error:
        api.dispatch('POST', '/api/settings/save', {'revision': 0, 'profile': draft})
    assert error.value.field == 'model'
    assert not api.registry.exists


def test_explicit_negative_readiness_cannot_activate_diarization(cfg, monkeypatch):
    registry = Registry(cfg)
    draft = {'name': 'Diarization', 'stage': 'diarization', 'kind': 'mycelia',
             'settings': {'base_url': 'https://diarization.example'}}
    saved = registry.save({'revision': 0, 'profile': draft})
    from dev_harness import local_provider_probe
    transport = httpx.MockTransport(lambda _: httpx.Response(200, json={'ready': False}))
    monkeypatch.setattr(local_provider_probe.transport, 'client', lambda **_: httpx.Client(transport=transport))
    with pytest.raises(SettingsError):
        registry.activate({'revision': 1, 'stage': 'diarization', 'id': saved['profiles'][-1]['id']})
    assert registry.read() == saved


def http_request(cfg, path, *, method='POST', payload=None, overrides=None):
    body = json.dumps(payload or {}).encode()
    headers = {'Host': '127.0.0.1:20001', 'Origin': 'http://127.0.0.1:20001',
               'Content-Type': 'application/json', 'Content-Length': str(len(body)),
               'X-Omiloc-Request': 'settings', **(overrides or {})}
    raw = (f'{method} {path} HTTP/1.0\r\n' + ''.join(f'{k}: {v}\r\n' for k, v in headers.items()) + '\r\n').encode() + body
    class Socket:
        output = io.BytesIO()
        def makefile(self, *_):
            return io.BytesIO(raw)
        def sendall(self, value):
            self.output.write(value)
    sock = Socket()
    handler(Library(cfg.layout.services_dir), Path(__file__).resolve().parents[3] / 'web-local',
            settings=Settings(cfg))(sock, ('127.0.0.1', 1234), SimpleNamespace(server_port=20001))
    head, data = sock.output.getvalue().split(b'\r\n\r\n', 1)
    return int(head.split()[1]), json.loads(data)


def test_actual_http_settings_roundtrip_and_origin_guards(cfg):
    status, initial = http_request(cfg, '/api/settings', method='GET')
    assert status == 200 and initial['revision'] == 0
    payload = {'revision': 0, 'profile': summary(), 'api_key': 'synthetic-test-secret'}
    for invalid in ({'Origin': 'https://hostile.example'}, {'X-Forwarded-Host': '127.0.0.1:20001'},
                    {'X-Omiloc-Request': 'delete'}, {'Sec-Fetch-Site': 'cross-site'}):
        assert http_request(cfg, '/api/settings/save', payload=payload, overrides=invalid)[0] == 403
        assert not Registry(cfg).exists
    status, saved = http_request(cfg, '/api/settings/save', payload=payload)
    assert status == 200 and saved['profiles'][-1]['has_key']
    assert 'synthetic-test-secret' not in json.dumps(saved)
    assert http_request(cfg, '/api/settings/save', payload=payload)[0] == 409
    assert http_request(cfg, '/api/settings/save', payload=payload, overrides={'Content-Length': '999999'})[0] == 400


def test_live_activation_indeterminate_is_distinct_from_ordinary_failure(cfg, monkeypatch):
    from dev_harness import local_stt_services
    def uncertain(*_args, **_kwargs):
        raise local_stt_services.ActivationIndeterminate('synthetic-private-diagnostic')
    monkeypatch.setattr(local_stt_services, 'activate', uncertain)
    status, saved = http_request(cfg, '/api/settings/save', payload={'revision': 0, 'profile': {
        'name': 'Synthetic Live', 'stage': 'live', 'kind': 'external',
        'settings': {'url': 'wss://live.example/asr'}}})
    assert status == 200
    status, result = http_request(cfg, '/api/settings/activate', payload={
        'revision': 1, 'stage': 'live', 'id': saved['profiles'][-1]['id']})
    assert status == 503 and result['outcome'] == 'indeterminate'
    assert 'synthetic-private-diagnostic' not in json.dumps(result)
    assert Registry(cfg).read() == saved
