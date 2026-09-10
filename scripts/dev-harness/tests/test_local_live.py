import json
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dev_harness import cli, config, local_live, local_live_install


@pytest.fixture
def cfg(tmp_path, monkeypatch):
    monkeypatch.delenv('OMI_LOCAL_LIVE_PREVIEW_URL', raising=False)
    return config.load_config(tmp_path, {
        'PROVIDER_MODE': 'offline', 'OMI_LOCAL_TRANSPORT': 'ngrok',
        'OMI_DEV_BIND_HOST': '127.0.0.1', 'OMI_LOCAL_INSTANCE': 'ngrok',
        'OMI_HARNESS_PORT_OFFSET': '12000',
    }, create_layout=True)


def test_child_backend_gets_managed_url_and_explicit_disable_overrides_parent(cfg, monkeypatch):
    assert config.child_env_for(cfg)['OMI_LOCAL_LIVE_PREVIEW_URL'] == 'ws://127.0.0.1:18090/asr'
    (cfg.layout.state_root / 'live-preview.json').write_text('{"enabled": false}')
    monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'ws://127.0.0.1:19999/asr')
    assert config.child_env_for(cfg)['OMI_LOCAL_LIVE_PREVIEW_URL'] == ''
    assert not local_live.managed(cfg)


@pytest.mark.parametrize('url', ['ws://example.com/asr', 'ws://127.0.0.1:18090/other',
                                'ws://private@127.0.0.1:18090/asr', 'ws://127.0.0.1:18090/asr?secret=x'])
def test_external_live_input_is_strict_loopback_and_redacted(cfg, url):
    (cfg.layout.state_root / 'live-preview.json').write_text(json.dumps({'enabled': True, 'url': url}))
    with pytest.raises(local_live.LocalLiveError) as error:
        local_live.endpoint(cfg)
    assert url not in str(error.value)


def test_repeat_ngrok_start_preserves_live_worker_and_library(cfg, monkeypatch):
    services = ['backend', 'firestore', 'ngrok', 'library', 'stt-worker', 'live-preview', 'typesense']
    monkeypatch.setattr(cli, '_process_records', lambda _: [{'service': name} for name in services])
    stopped = []
    monkeypatch.setattr(cli, '_stop_single_service', lambda _cfg, record: stopped.append(record['service']))
    cli._stop_unused_offline_services(cfg)
    assert stopped == ['typesense']


def test_legacy_backend_configuration_blocks_before_mutations(cfg, monkeypatch):
    monkeypatch.setattr(cli, '_service_record', lambda *_: {'service': 'backend'})
    with pytest.raises(local_live.LocalLiveError, match='earlier live settings'):
        local_live.require_backend_environment(cfg)
    monkeypatch.setattr(cli, '_service_record', lambda *_: {'local_live_preview_url': local_live.endpoint(cfg)})
    local_live.require_backend_environment(cfg)


def test_managed_start_reaches_observed_model_readiness_and_reuses_on_repeat(cfg, monkeypatch):
    records = {}
    started = []
    ready = False
    monkeypatch.setattr(cli, '_service_record', lambda _cfg, name: records.get(name))
    monkeypatch.setattr(cli, '_require_port_available_or_owned', lambda *_: None)
    monkeypatch.setattr(local_live_install, 'installed', lambda _: (Path('/synthetic/worker'), Path('/synthetic/models')))
    monkeypatch.setattr(local_live, 'health', lambda _: {'ready': ready, 'active': False})

    def spawn(_cfg, service, command, **kwargs):
        nonlocal ready
        lock = cfg.layout.services_dir / 'local-transcripts/.lock'
        assert lock.is_file(), 'A prepared model does not imply a per-instance inference lock exists'
        assert lock.stat().st_mode & 0o777 == 0o600
        started.append(command)
        records[service] = {'service': service}
        ready = True

    monkeypatch.setattr(cli, '_start_process', spawn)
    local_live.start(cfg)
    local_live.start(cfg)
    assert len(started) == 1
    assert started[0][1:3] == ['-m', 'local_live_preview.serve_parakeet']
    assert str(cfg.layout.services_dir / 'local-transcripts' / '.lock') in started[0]
    assert started[0][-2:] == ['--port', '18090']


def test_unobservable_existing_live_is_not_restarted(cfg, monkeypatch):
    monkeypatch.setattr(cli, '_service_record', lambda *_: {'service': 'live-preview'})
    monkeypatch.setattr(cli, '_require_port_available_or_owned', lambda *_: None)
    monkeypatch.setattr(local_live, 'health', lambda _: {})
    monkeypatch.setattr(cli, '_start_process', lambda *a, **k: pytest.fail('must not restart unknown process'))
    with pytest.raises(local_live.LocalLiveError, match='indeterminate'):
        local_live.start(cfg)


def test_existing_external_url_is_observed_but_not_managed(cfg, monkeypatch):
    monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'ws://127.0.0.1:19090/asr')
    monkeypatch.setattr(local_live, 'health', lambda _: {'ready': True, 'active': False})
    monkeypatch.setattr(cli, '_start_process', lambda *a, **k: pytest.fail('must not own external runtime'))
    monkeypatch.setattr(local_live_install, 'installed', lambda _: pytest.fail('must not install external runtime'))
    local_live.start(cfg)
    assert not local_live.managed(cfg)
