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


@pytest.mark.parametrize('library_environment', [False, True])
def test_first_save_preserves_default_managed_live_and_explicit_off(cfg, monkeypatch, library_environment):
    cfg.local_transport = 'tailscale'
    cfg.container_runtime = False
    if library_environment:
        monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'ws://127.0.0.1:18090/asr')
    else:
        monkeypatch.delenv('OMI_LOCAL_LIVE_PREVIEW_URL', raising=False)
    registry = Registry(cfg)
    assert registry.snapshot('live')['kind'] == 'parakeet-local'
    registry.save({'revision': 0, 'profile': summary()})
    assert registry.snapshot('live')['name'] == 'Parakeet на этом Mac'
    registry.activate({'revision': 1, 'stage': 'live', 'id': None}, prepare=lambda _, publish: publish())
    assert registry.snapshot('live') is None
    assert Registry(cfg).snapshot('live') is None


def test_first_save_respects_explicitly_disabled_legacy_live(cfg):
    cfg.local_transport = 'tailscale'
    cfg.container_runtime = False
    (cfg.layout.state_root / 'live-preview.json').write_text('{"enabled": false}')
    registry = Registry(cfg)
    registry.save({'revision': 0, 'profile': summary()})
    assert registry.snapshot('live') is None


def test_translation_defaults_to_applied_summary_and_keeps_credentials_pinned(cfg):
    registry = Registry(cfg)
    # Legacy users with only STT have no text model; never send text to ASR.
    assert registry.snapshot('translation') is None
    saved = registry.save({'revision': 0, 'profile': summary(), 'api_key': 'summary-key'})
    card = saved['profiles'][-1]
    assert registry.snapshot('translation') is None  # A saved draft is not active.
    registry.activate({'revision': 1, 'stage': 'summary', 'id': card['id']},
                      prepare=lambda _, publish: publish())
    inherited = registry.snapshot('translation')
    assert inherited['inherited_from'] == 'summary'
    assert inherited['stage'] == 'translation'
    assert registry.key(inherited) == 'summary-key'
    assert registry.read()['active']['translation'] is None
    assert registry.read()['effective']['translation']['settings'] == card['settings']
    edited = {**card, 'settings': {**card['settings'], 'model': 'draft-only'}}
    registry.save({'revision': 2, 'profile': edited, 'api_key': 'new-key'})
    assert registry.snapshot('translation') == inherited
    assert registry.key(inherited) == 'summary-key'
    assert 'translation' not in registry.pipeline()
    registry.activate({'revision': 3, 'stage': 'summary', 'id': None},
                      prepare=lambda _, publish: publish())
    assert registry.snapshot('translation') is None


def test_explicit_translator_overrides_default_until_returning_to_automatic(cfg):
    registry = Registry(cfg)
    for stage in ('summary', 'translation'):
        saved = registry.save({'revision': registry.read()['revision'],
                               'profile': {**summary(), 'stage': stage}, 'api_key': stage + '-key'})
        registry.activate({'revision': saved['revision'], 'stage': stage, 'id': saved['profiles'][-1]['id']},
                          prepare=lambda _, publish: publish())
    selected = registry.snapshot('translation')
    assert 'inherited_from' not in selected
    assert registry.key(selected) == 'translation-key'
    registry.activate({'revision': registry.read()['revision'], 'stage': 'translation', 'id': None},
                      prepare=lambda _, publish: publish())
    assert registry.key(registry.snapshot('translation')) == 'summary-key'


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


def phone_request(cfg, operation='', **kwargs):
    return http_request(cfg, '/api/processing' + operation,
                        overrides={'X-Omiloc-Request': 'processing'}, **kwargs)


def test_shared_summary_catalog_preserves_drafts_and_pins_only_the_applied_default(cfg):
    registry = Registry(cfg)
    assert http_request(cfg, '/api/processing/summary-settings', method='GET')[0] == 403
    code, initial = phone_request(cfg, '/summary-settings', method='GET')
    assert code == 200 and initial['revision'] == 0 and initial['default_template_id'] == 'standard'
    assert initial['default_profile_id'] is None
    prepared = registry.save({'revision': 0, 'profile': summary(), 'api_key': 'fixture-summary-key'})
    identifier = prepared['profiles'][-1]['id']
    registry.activate({'revision': 1, 'stage': 'summary', 'id': identifier},
                      prepare=lambda _, publish: publish())
    before = registry.pipeline()['summary']
    assert 'template' not in before
    custom = {'id': 'decisions', 'name': 'Decisions', 'prompt': 'List decisions.\nInclude owners.'}
    body = {'revision': 2, 'templates': [*initial['templates'], custom], 'default_template_id': 'standard'}
    status, result = phone_request(cfg, '/summary-settings', payload=body)
    assert status == 200 and result['revision'] == 3
    assert result['default_profile_id'] == identifier
    assert 'fixture-summary-key' not in json.dumps(result)
    assert registry.pipeline()['summary'] == before
    assert phone_request(cfg, '/summary-settings', payload=body)[0] == 409
    updated = {**body, 'revision': 3, 'default_template_id': custom['id']}
    assert phone_request(cfg, '/summary-settings', payload={**updated, 'default_template_id': 'missing'})[0] == 400
    assert phone_request(cfg, '/summary-settings', payload=updated)[0] == 200
    after = registry.pipeline()['summary']
    assert after['template'] == custom and registry.key(after) == 'fixture-summary-key'
    assert registry.snapshot('summary') == before
    assert 'template' not in before


def test_summary_regeneration_uses_the_confirmed_model_and_template(cfg, monkeypatch):
    from dev_harness import local_summary_regeneration

    registry = Registry(cfg)
    saved = registry.save({'revision': 0, 'profile': summary(), 'api_key': 'fixture-summary-key'})
    profile = saved['profiles'][-1]
    registry.activate({'revision': 1, 'stage': 'summary', 'id': profile['id']},
                      prepare=lambda _, publish: publish())
    code, data = phone_request(cfg, '/regenerate-summary', method='GET')
    assert code == 200 and 'fixture-summary-key' not in json.dumps(data)
    assert http_request(cfg, '/api/processing/regenerate-summary', method='GET')[0] == 403
    provider, = data['providers']
    template, = data['templates']
    body = {
        'provider_binding': provider['binding'], 'template_id': template['id'],
        'template_digest': '0' * 64, 'transcript': '[1.0] Corrected transcript.', 'prompt': 'Extract decisions.',
    }
    received = []

    def summarize(snapshot, key, transcript, *_args, **_kwargs):
        assert key == 'fixture-summary-key'
        received.append((snapshot, transcript))
        return {'title': 'Generated title', 'overview': 'Generated recap'}

    monkeypatch.setattr(local_summary_regeneration.local_pipeline, 'summarize_text', summarize)
    assert phone_request(cfg, '/regenerate-summary', payload=body)[0] == 409
    assert not received
    body['template_digest'] = template['digest']
    assert phone_request(cfg, '/regenerate-summary', payload=body)[0] == 200
    snapshot, transcript = received.pop()
    assert snapshot['template']['prompt'] == body['prompt'] and transcript == body['transcript']


def test_recording_chat_sends_transcript_only_to_the_confirmed_model(cfg, monkeypatch):
    from dev_harness import local_recording_chat

    registry = Registry(cfg)
    assert phone_request(cfg, '/recording-chat', method='GET') == (200, {'provider': None})
    state = registry.save({'revision': 0, 'profile': summary(), 'api_key': 'fixture-chat-key'})
    profile = state['profiles'][-1]
    registry.activate({'revision': 1, 'stage': 'summary', 'id': profile['id']},
                      prepare=lambda _, publish: publish())
    status, data = phone_request(cfg, '/recording-chat', method='GET')
    assert status == 200
    assert data['provider']['host'] == 'llm.example'
    assert 'fixture-chat-key' not in json.dumps(data)
    assert http_request(cfg, '/api/processing/recording-chat', method='GET')[0] == 403

    citations = [1]
    sent = []

    def respond(client, url, **kwargs):
        assert url == 'https://llm.example/v1/chat/completions'
        assert client.headers['Authorization'] == 'Bearer fixture-chat-key'
        sent.append(kwargs['json'])
        return {'choices': [{'finish_reason': 'stop', 'message': {
            'content': json.dumps({'answer': 'The plan was accepted.', 'sources': citations}),
        }}]}

    monkeypatch.setattr(local_recording_chat.transport, 'post_json', respond)
    body = {'binding': '0' * 64, 'question': 'Was the plan accepted?', 'sources': ['We accepted the plan.'], 'history': []}
    assert phone_request(cfg, '/recording-chat', payload=body)[0] == 409
    assert sent == []
    body['binding'] = data['provider']['binding']
    assert phone_request(cfg, '/recording-chat', payload=body) == (200, {
        'answer': 'The plan was accepted.', 'sources': [1],
    })
    assert json.loads(sent[0]['messages'][1]['content'])['transcript'] == [
        {'source': 1, 'text': 'We accepted the plan.'},
    ]
    citations[:] = [2]
    assert phone_request(cfg, '/recording-chat', payload=body)[0] == 502
    assert phone_request(cfg, '/archive-chat', method='GET') == (200, data)
    assert phone_request(cfg, '/archive-chat', payload=body)[0] == 400
    body['sources'] = ['We accepted the plan.', 'We confirmed it later.']
    body['recordings'] = [
        {'recording': 1, 'title': 'First meeting', 'started_at': '2026-05-01T12:00:00+00:00'},
        {'recording': 2, 'title': 'Second meeting', 'started_at': '2026-05-08T12:00:00+00:00'},
    ]
    assert phone_request(cfg, '/archive-chat', payload=body) == (200, {
        'answer': 'The plan was accepted.', 'sources': [2],
    })
    assert json.loads(sent[-1]['messages'][1]['content'])['transcript'] == [
        {'source': index, 'text': line, **recording}
        for index, (line, recording) in enumerate(zip(body['sources'], body['recordings']), 1)
    ]


def test_daily_recap_sends_only_selected_excerpts_to_the_confirmed_model(cfg, monkeypatch):
    from dev_harness import local_recording_chat

    registry = Registry(cfg)
    state = registry.save({'revision': 0, 'profile': summary(), 'api_key': 'fixture-daily-key'})
    registry.activate({'revision': 1, 'stage': 'summary', 'id': state['profiles'][-1]['id']},
                      prepare=lambda _, publish: publish())
    status, data = phone_request(cfg, '/daily-recap', method='GET')
    assert status == 200
    assert http_request(cfg, '/api/processing/daily-recap', method='GET')[0] == 403
    calls = []

    def complete(_registry, profile, payload):
        assert registry.key(profile) == 'fixture-daily-key'
        calls.append(json.loads(payload['messages'][-1]['content']))
        return {'headline': 'A day', 'overview': 'An overview', 'highlights': [], 'decisions': []}

    monkeypatch.setattr(local_recording_chat, '_complete', complete)
    excerpt = {'source': 1, 'title': 'Meeting', 'text': 'Saved evidence.', 'kind': 'recap'}
    request = {'binding': '0' * 64, 'sources': [excerpt]}
    assert phone_request(cfg, '/daily-recap', payload=request)[0] == 409
    assert not calls
    request['binding'] = data['provider']['binding']
    assert phone_request(cfg, '/daily-recap', payload=request)[0] == 200
    assert calls == [[excerpt]]


def test_task_suggestions_use_only_the_confirmed_model(cfg, monkeypatch):
    from dev_harness import local_recording_chat

    registry = Registry(cfg)
    assert phone_request(cfg, '/task-suggestions', method='GET') == (200, {'provider': None})
    state = registry.save({'revision': 0, 'profile': summary(), 'api_key': 'fixture-task-key'})
    profile = state['profiles'][-1]
    registry.activate({'revision': 1, 'stage': 'summary', 'id': profile['id']},
                      prepare=lambda _, publish: publish())
    status, data = phone_request(cfg, '/task-suggestions', method='GET')
    assert status == 200 and data['provider']['host'] == 'llm.example'
    assert http_request(cfg, '/api/processing/task-suggestions', method='GET')[0] == 403
    sent = []
    reply = {'suggestions': [{'description': 'Send the budget', 'source': 1}]}

    def respond(client, url, **kwargs):
        assert url == 'https://llm.example/v1/chat/completions'
        assert client.headers['Authorization'] == 'Bearer fixture-task-key'
        sent.append(kwargs['json'])
        return {'choices': [{'message': {'content': json.dumps(reply)}}]}

    monkeypatch.setattr(local_recording_chat.transport, 'post_json', respond)
    body = {'binding': '0' * 64, 'sources': ['I will send the budget.']}
    assert phone_request(cfg, '/task-suggestions', payload=body)[0] == 409
    assert not sent
    body['binding'] = data['provider']['binding']
    assert phone_request(cfg, '/task-suggestions', payload=body) == (200, reply)
    assert json.loads(sent[0]['messages'][-1]['content']) == [{'source': 1, 'text': body['sources'][0]}]


def test_phone_remote_profile_roundtrip_reuses_keys_revision_and_activation(cfg, monkeypatch):
    from dev_harness import local_provider_probe
    monkeypatch.setattr(local_provider_probe, 'probe', lambda *_args, **_kwargs: {'state': 'ready'})
    profile = {'name': 'Synthetic server', 'stage': 'diarization', 'kind': 'mycelia',
               'settings': {'base_url': 'https://diarization.example', 'min_speakers': 1}}
    status, saved = phone_request(cfg, '/save', payload={'revision': 0, 'profile': profile, 'api_key': 'synthetic-secret'})
    selected = saved['profiles'][-1]
    assert status == 200 and selected['can_edit'] and selected['has_key']
    assert 'synthetic-secret' not in json.dumps(saved)
    assert phone_request(cfg, '/save', payload={'revision': 0, 'profile': profile})[0] == 409
    status, active = phone_request(cfg, '/activate', payload={'revision': 1, 'stage': 'diarization', 'id': selected['id']})
    assert status == 200 and active['effective']['diarization']['id'] == selected['id']
    status, disabled = phone_request(cfg, '/activate', payload={'revision': 2, 'stage': 'diarization', 'id': None})
    assert status == 200 and disabled['effective']['diarization'] is None
    assert phone_request(cfg, '/profiles/' + selected['id'], method='DELETE', payload={'revision': 3})[0] == 200


def test_phone_can_select_prepared_engines_but_never_edit_host_execution(cfg, monkeypatch):
    from dev_harness import local_provider_probe
    monkeypatch.setattr(local_provider_probe, 'probe', lambda *_args, **_kwargs: {'state': 'available'})
    registry = Registry(cfg)
    native = {'name': 'Prepared local', 'stage': 'stt', 'kind': 'whisperx',
              'settings': {'model': 'small', 'language': 'ru', 'python': '/synthetic/private/bin/python'}}
    saved = registry.save({'revision': 0, 'profile': native})
    native['id'] = saved['profiles'][-1]['id']
    status, public = phone_request(cfg, method='GET')
    assert status == 200 and not public['profiles'][-1]['can_edit']
    assert '/synthetic/private' not in json.dumps(public)
    assert phone_request(cfg, '/save', payload={'revision': 1, 'profile': native})[0] == 403
    assert phone_request(cfg, '/probe', payload={'profile': native})[0] == 403
    assert phone_request(cfg, '/profiles/' + native['id'], method='DELETE', payload={'revision': 1})[0] == 403
    status, selected = phone_request(cfg, '/activate', payload={'revision': 1, 'stage': 'stt', 'id': native['id']})
    assert status == 200 and selected['active']['stt'] == native['id']


def test_phone_external_live_cannot_install_or_replace_managed_diarization(cfg):
    registry = Registry(cfg)
    profile = {'name': 'Prepared live speakers', 'stage': 'live', 'kind': 'external',
               'settings': {'url': 'wss://live.example/asr', 'diarization': {
                   'enabled': True, 'python': '/synthetic/private/bin/python', 'port': 19091}}}
    saved = registry.save({'revision': 0, 'profile': profile})
    profile['id'] = saved['profiles'][-1]['id']
    assert phone_request(cfg, '/save', payload={'revision': 1, 'profile': profile})[0] == 403
    profile['settings'] = {'url': 'wss://different.example/asr'}
    assert phone_request(cfg, '/save', payload={'revision': 1, 'profile': profile})[0] == 403
    assert registry.read() == saved


def test_phone_request_guards_and_url_validation(cfg):
    profile = {'name': 'Remote', 'stage': 'stt', 'kind': 'openai-compatible',
               'settings': {'provider_url': 'http://public.example/v1', 'model': 'synthetic'}}
    assert phone_request(cfg, '/save', payload={'revision': 0, 'profile': profile})[0] == 400
    profile['settings']['provider_url'] = 'https://stt.example/v1'
    assert http_request(cfg, '/api/processing/save', payload={'revision': 0, 'profile': profile})[0] == 403
    assert phone_request(cfg, '/save', payload={'revision': 0, 'profile': summary()})[0] == 403
    assert phone_request(cfg, '/activate', payload={'revision': 0, 'stage': 'summary', 'id': None})[0] == 400
    assert not Registry(cfg).exists


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


def test_summary_reasoning_option_is_validated(cfg):
    from dev_harness.local_providers import validate_profile, SettingsError
    profile = summary()
    assert 'reasoning' not in validate_profile(profile)['settings']
    profile['settings']['reasoning'] = 'off'
    assert validate_profile(profile)['settings']['reasoning'] == 'off'
    profile['settings']['reasoning'] = 'sometimes'
    with pytest.raises(SettingsError):
        validate_profile(profile)


def translation(name='Synthetic translator', base='https://llm.example/v1'):
    return {'name': name, 'stage': 'translation', 'kind': 'openai-compatible',
            'settings': {'base_url': base, 'model': 'qwen3', 'reasoning': 'off'}}


def test_translation_stage_uses_summary_shape_and_stays_out_of_pipeline(cfg):
    from dev_harness.local_providers import validate_profile, SettingsError
    validated = validate_profile(translation())
    assert validated['settings'] == {'base_url': 'https://llm.example/v1', 'model': 'qwen3', 'reasoning': 'off'}
    with pytest.raises(SettingsError):
        validate_profile({**translation(), 'settings': {'base_url': 'https://llm.example/v1', 'model': 'x', 'language': 'en'}})
    registry = Registry(cfg)
    saved = registry.save({'revision': 0, 'profile': translation(), 'api_key': 'translation-test-key'})
    profile = saved['profiles'][-1]
    registry.activate({'revision': 1, 'stage': 'translation', 'id': profile['id']},
                      prepare=lambda _, publish: publish())
    assert registry.snapshot('translation')['name'] == 'Synthetic translator'
    assert registry.key(registry.snapshot('translation')) == 'translation-test-key'
    assert 'translation' not in registry.pipeline()
    assert registry.read()['active']['translation'] == profile['id']
