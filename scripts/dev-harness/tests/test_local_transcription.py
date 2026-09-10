"""First-install model coordination with fake installers and real state/locks."""

import fcntl
import json
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dev_harness import local_live, local_live_install, local_stt, local_transcription as setup, local_whisperkit, safety


@pytest.fixture
def prepared(tmp_path, monkeypatch):
    repo = tmp_path / 'project'
    repo.mkdir()
    cfg = SimpleNamespace(repo_root=repo, instance='ngrok', provider_mode='offline', local_transport='ngrok',
                          layout=safety.layout_for_instance(repo, 'ngrok'), backend_port=20000)
    events, ready = [], {'final': False, 'live': False}
    monkeypatch.delenv('OMI_LOCAL_LIVE_PREVIEW_URL', raising=False)

    def installed(which):
        events.append('check_' + which)
        if not ready[which]:
            error = local_whisperkit.WhisperKitError if which == 'final' else local_live_install.LiveInstallError
            raise error('synthetic missing model')
        return repo / 'synthetic-binary'

    def install(which):
        # The production coordinator owns the actual shared inference lock.
        with (cfg.layout.services_dir / 'local-transcripts/.lock').open('r+') as observer:
            with pytest.raises(BlockingIOError):
                fcntl.flock(observer, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert not (cfg.layout.state_root / 'stt-watch.json').exists()
        events.append('install_' + which)
        ready[which] = True

    monkeypatch.setattr(setup.local_whisperkit, 'installed', lambda _: installed('final'))
    monkeypatch.setattr(setup.local_live_install, 'installed', lambda _: installed('live'))
    monkeypatch.setattr(setup.whisperkit_install, 'preflight', lambda _: events.append('preflight_final'))
    monkeypatch.setattr(setup.local_live_install, 'preflight', lambda _: events.append('preflight_live'))
    monkeypatch.setattr(setup.whisperkit_install, 'install', lambda _, **kwargs: install('final'))
    monkeypatch.setattr(setup.local_live_install, 'install', lambda _, **kwargs: install('live'))
    monkeypatch.setattr(setup.local_stt, 'check_model', lambda engine: events.append(('check_engine', engine.engine)))
    return cfg, events, ready


def create_layout(cfg):
    safety.create_state_layout(cfg.repo_root, cfg.instance)


def write(cfg, name, data):
    local_stt.atomic_json(cfg.layout.state_root / name, data)


def test_fresh_prepare_preflights_both_before_installing_and_defers_defaults(prepared):
    cfg, events, ready = prepared
    setup.prepare(cfg)
    assert events[:4] == ['check_final', 'check_live', 'preflight_final', 'preflight_live']
    assert events[4:] == ['check_final', 'install_final', 'check_final', 'check_live', 'install_live', 'check_live']
    assert ready == {'final': True, 'live': True}
    for name in ('stt-engine.json', 'stt-watch.json', 'live-preview.json'):
        assert not (cfg.layout.state_root / name).exists()
    safety.read_and_validate_sentinel(cfg.layout.state_root, repo_root=cfg.repo_root, instance=cfg.instance)
    setup.configure_defaults(cfg)
    assert json.loads((cfg.layout.state_root / 'stt-engine.json').read_text()) == setup.DEFAULT_ENGINE
    assert json.loads((cfg.layout.state_root / 'stt-watch.json').read_text()) == {'enabled': True, 'excluded': []}
    assert json.loads((cfg.layout.state_root / 'live-preview.json').read_text()) == {'enabled': True}


@pytest.mark.parametrize('stage', ['final', 'live'])
def test_failed_preflight_does_not_install_or_create_state(prepared, monkeypatch, stage):
    cfg, events, ready = prepared
    target = setup.whisperkit_install if stage == 'final' else setup.local_live_install
    # OS/tool failures are normalized to fixed redacted setup diagnostics.
    monkeypatch.setattr(target, 'preflight', lambda _: (_ for _ in ()).throw(OSError('private synthetic path')))
    with pytest.raises(setup.TranscriptionSetupError) as error:
        setup.prepare(cfg)
    assert 'private synthetic path' not in str(error.value)
    assert not cfg.layout.state_root.exists()
    assert not any(item.startswith('install_') for item in events)
    assert ready == {'final': False, 'live': False}


def test_attested_models_are_reused_without_preflight_lock_or_layout_mutation(prepared):
    cfg, events, ready = prepared
    ready.update(final=True, live=True)
    setup.prepare(cfg)
    assert events == ['check_final', ('check_engine', 'whisperkit'), 'check_live']
    assert not cfg.layout.state_root.exists()


def test_managed_receipt_does_not_skip_actual_executable_preflight(prepared, monkeypatch):
    cfg, events, ready = prepared
    ready.update(final=True, live=True)
    def failed_probe(_):
        raise local_stt.TranscriptionError('Synthetic executable failure')
    monkeypatch.setattr(local_stt, 'check_model', failed_probe)
    with pytest.raises(setup.TranscriptionSetupError, match='финальный движок не готов'):
        setup.prepare(cfg)
    assert not cfg.layout.state_root.exists()
    assert not any(str(item).startswith('install_') for item in events)


def test_explicit_disabled_choices_and_existing_queue_are_preserved(prepared):
    cfg, events, _ = prepared
    create_layout(cfg)
    write(cfg, 'stt-engine.json', {'engine': 'parakeet-mlx'})
    write(cfg, 'stt-watch.json', {'enabled': False, 'excluded': ['previous-boundary']})
    write(cfg, 'live-preview.json', {'enabled': False})
    queue = cfg.layout.services_dir / 'local-transcripts/watch-queue.json'
    queue.parent.mkdir()
    queue.write_text('{"synthetic-job":{"state":"failed"}}')
    paths = [cfg.layout.state_root / name for name in ('stt-engine.json', 'stt-watch.json', 'live-preview.json')]
    paths.append(queue)
    before = {path: path.read_bytes() for path in paths}
    setup.prepare(cfg)
    setup.configure_defaults(cfg)
    setup.check_models(cfg)
    assert {path: path.read_bytes() for path in paths} == before
    assert events == []
    assert not (queue.parent / '.lock').exists()


@pytest.mark.parametrize('engine', [
    {'engine': 'parakeet-mlx'},
    {'engine': 'whisperkit', 'assets_path': '/synthetic/external/model'},
])
def test_explicit_engine_is_checked_without_installing_or_replacing_it(prepared, engine):
    cfg, events, _ = prepared
    create_layout(cfg)
    write(cfg, 'stt-engine.json', engine)
    write(cfg, 'live-preview.json', {'enabled': False})
    before = (cfg.layout.state_root / 'stt-engine.json').read_bytes()
    setup.prepare(cfg)
    setup.configure_defaults(cfg)
    assert (cfg.layout.state_root / 'stt-engine.json').read_bytes() == before
    assert events == [('check_engine', engine['engine'])]


def test_unprepared_explicit_engine_stops_before_installing_other_models(prepared, monkeypatch):
    cfg, events, _ = prepared
    create_layout(cfg)
    write(cfg, 'stt-engine.json', {'engine': 'parakeet-mlx'})
    before = (cfg.layout.state_root / 'stt-engine.json').read_bytes()
    def fail(_, **kwargs):
        raise local_stt.TranscriptionError('private synthetic runtime path')
    monkeypatch.setattr(setup.local_stt, 'check_model', fail)
    with pytest.raises(setup.TranscriptionSetupError) as error:
        setup.prepare(cfg)
    assert 'private synthetic runtime path' not in str(error.value)
    assert (cfg.layout.state_root / 'stt-engine.json').read_bytes() == before
    assert not (cfg.layout.state_root / 'stt-watch.json').exists()
    assert events == []


def test_malformed_watcher_choice_does_not_enable_or_prepare_models(prepared):
    cfg, events, _ = prepared
    create_layout(cfg)
    write(cfg, 'stt-watch.json', {'enabled': 'false'})
    before = (cfg.layout.state_root / 'stt-watch.json').read_bytes()
    with pytest.raises(setup.TranscriptionSetupError, match='true или false'):
        setup.prepare(cfg)
    assert (cfg.layout.state_root / 'stt-watch.json').read_bytes() == before
    assert events == []


def test_legacy_ambient_live_endpoint_is_preserved_and_managed_install_skipped(prepared, monkeypatch):
    cfg, events, ready = prepared
    ready['final'] = True
    monkeypatch.setenv('OMI_LOCAL_LIVE_PREVIEW_URL', 'ws://127.0.0.1:18090/asr')
    setup.prepare(cfg)
    assert events == ['check_final', ('check_engine', 'whisperkit')]
    assert not cfg.layout.state_root.exists()
    create_layout(cfg)
    setup.configure_defaults(cfg)
    monkeypatch.delenv('OMI_LOCAL_LIVE_PREVIEW_URL')
    assert local_live.settings(cfg) == {'enabled': True, 'url': 'ws://127.0.0.1:18090/asr'}
    setup.check_models(cfg)
    assert events == ['check_final', ('check_engine', 'whisperkit'), ('check_engine', 'whisperkit')]


def test_first_defaults_preserve_archive_boundary_and_private_file_modes(prepared):
    cfg, _, _ = prepared
    create_layout(cfg)
    root = cfg.layout.services_dir / 'storage/listen-captures'
    for name in ('synthetic-old-recording', 'synthetic-active-recording'):
        (root / name).mkdir(parents=True)
    setup.configure_defaults(cfg)
    first = {path: path.read_bytes() for path in cfg.layout.state_root.glob('*.json')}
    watch = json.loads((cfg.layout.state_root / 'stt-watch.json').read_text())
    assert len(watch['excluded']) == 2
    assert watch['enabled'] is True
    assert b'synthetic-old-recording' not in (cfg.layout.state_root / 'stt-watch.json').read_bytes()
    assert all((cfg.layout.state_root / name).stat().st_mode & 0o777 == 0o600
               for name in ('stt-engine.json', 'stt-watch.json', 'live-preview.json'))
    (root / 'synthetic-new-recording').mkdir()
    setup.configure_defaults(cfg)
    assert {path: path.read_bytes() for path in first} == first


def test_check_models_is_read_only_and_uses_recommended_in_memory_profile(prepared):
    cfg, events, ready = prepared
    ready['live'] = True
    setup.check_models(cfg)
    assert events == [('check_engine', 'whisperkit'), 'check_live']
    assert not cfg.layout.state_root.exists()


def test_busy_shared_inference_lock_prevents_installation(prepared):
    cfg, events, ready = prepared
    create_layout(cfg)
    lock_path = cfg.layout.services_dir / 'local-transcripts/.lock'
    lock_path.parent.mkdir()
    with lock_path.open('w') as active:
        fcntl.flock(active, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with pytest.raises(setup.TranscriptionSetupError, match='занято'):
            setup.prepare(cfg)
    assert not any(item.startswith('install_') for item in events)
    assert ready == {'final': False, 'live': False}


def test_failed_second_install_never_activates_first_install_defaults(prepared, monkeypatch):
    cfg, _, ready = prepared
    def fail(_):
        raise local_live_install.LiveInstallError('private synthetic diagnostic')
    monkeypatch.setattr(setup.local_live_install, 'install', fail)
    with pytest.raises(setup.TranscriptionSetupError) as error:
        setup.prepare(cfg)
    assert 'private synthetic diagnostic' not in str(error.value)
    assert ready == {'final': True, 'live': False}
    assert not any((cfg.layout.state_root / name).exists()
                   for name in ('stt-engine.json', 'stt-watch.json', 'live-preview.json'))


@pytest.mark.parametrize('target', ['state', 'lock'])
def test_redirected_state_or_lock_is_rejected_without_installation(prepared, target):
    cfg, events, _ = prepared
    outside = cfg.repo_root.parent / 'outside'
    outside.mkdir()
    if target == 'state':
        cfg.layout.state_root.parent.mkdir(parents=True)
        cfg.layout.state_root.symlink_to(outside)
    else:
        create_layout(cfg)
        lock = cfg.layout.services_dir / 'local-transcripts/.lock'
        lock.parent.mkdir()
        lock.symlink_to(outside / 'unchanged')
    with pytest.raises(setup.TranscriptionSetupError, match='Небезопасный'):
        setup.prepare(cfg)
    assert not any(item.startswith('install_') for item in events)
    assert list(outside.iterdir()) == []


def test_existing_unowned_state_is_never_adopted(prepared):
    cfg, events, _ = prepared
    cfg.layout.state_root.mkdir(parents=True)
    with pytest.raises(setup.TranscriptionSetupError, match='владелец'):
        setup.prepare(cfg)
    assert events == []
    assert list(cfg.layout.state_root.iterdir()) == []


def test_under_lock_readiness_recheck_avoids_reinstall_after_another_setup(prepared, monkeypatch):
    cfg, events, ready = prepared
    def completed_elsewhere(_):
        ready.update(final=True, live=True)
        events.append('preflight_live')
    monkeypatch.setattr(setup.local_live_install, 'preflight', completed_elsewhere)
    setup.prepare(cfg)
    assert events == ['check_final', 'check_live', 'preflight_final', 'preflight_live', 'check_final', 'check_live']
    assert not (cfg.layout.state_root / 'stt-watch.json').exists()
