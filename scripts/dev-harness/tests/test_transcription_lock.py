"""Shared exclusion for model installation and local transcription."""

from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dev_harness import local_live_install, safety, transcription_lock, whisperkit_install


def test_shared_lock_excludes_a_second_standalone_operation(tmp_path, monkeypatch):
    repo = tmp_path / 'project'
    repo.mkdir()
    monkeypatch.delenv('OMI_LOCAL_INSTANCE', raising=False)
    monkeypatch.delenv('OMI_LOCAL_STATE_ROOT', raising=False)
    safety.create_state_layout(repo, 'ngrok')

    with transcription_lock.acquire(repo) as active:
        assert active is not None
        with pytest.raises(transcription_lock.TranscriptionLockBusy, match='занято'):
            with transcription_lock.acquire(repo):
                pass
        with transcription_lock.acquire(repo, shared_lock=active) as reused:
            assert reused is active


def test_configured_state_outside_checkout_still_uses_the_owned_lock(tmp_path, monkeypatch):
    repo = tmp_path / 'project'
    state_base = tmp_path / 'separate-state'
    repo.mkdir()
    monkeypatch.setenv('OMI_LOCAL_STATE_ROOT', str(state_base))
    safety.create_state_layout(repo, 'ngrok', {'OMI_LOCAL_STATE_ROOT': str(state_base)})
    with transcription_lock.acquire(repo) as active:
        assert active is not None
        with pytest.raises(transcription_lock.TranscriptionLockBusy):
            with transcription_lock.acquire(repo):
                pass


def test_explicit_lock_path_must_be_owned_canonical_lock(tmp_path, monkeypatch):
    repo = tmp_path / 'project'
    repo.mkdir()
    monkeypatch.delenv('OMI_LOCAL_INSTANCE', raising=False)
    monkeypatch.delenv('OMI_LOCAL_STATE_ROOT', raising=False)
    layout = safety.create_state_layout(repo, 'ngrok')
    with pytest.raises(transcription_lock.TranscriptionLockError, match='Небезопасный'):
        with transcription_lock.acquire(repo, lock_path=layout.services_dir / 'local-transcripts/missing.lock'):
            pass
    with pytest.raises(transcription_lock.TranscriptionLockError, match='Не подтверждён'):
        with transcription_lock.acquire(repo, lock_path=tmp_path / 'missing-state/services/local-transcripts/.lock'):
            pass


def test_whisperkit_cli_requires_binding_for_custom_root(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(sys, 'argv', ['whisperkit-install', '--root', str(tmp_path / 'custom')])
    assert whisperkit_install.main() == 1
    assert 'lock-path' in capsys.readouterr().out


def test_live_install_checks_shared_lock_before_touching_assets(tmp_path, monkeypatch):
    repo = tmp_path / 'project'
    repo.mkdir()
    monkeypatch.delenv('OMI_LOCAL_INSTANCE', raising=False)
    monkeypatch.delenv('OMI_LOCAL_STATE_ROOT', raising=False)
    safety.create_state_layout(repo, 'ngrok')
    root = repo / '.local/parakeet-live'
    smoke_called = []
    monkeypatch.setattr(local_live_install, 'preflight', lambda _: 'synthetic toolchain')
    monkeypatch.setattr(local_live_install, 'runtime_root', lambda _: root)
    monkeypatch.setattr(local_live_install, 'recipe', lambda _: {'assets': []})
    monkeypatch.setattr(local_live_install, 'smoke', lambda *args, **kwargs: smoke_called.append(args))

    with transcription_lock.acquire(repo) as active:
        with pytest.raises(local_live_install.LiveInstallError, match='занято'):
            local_live_install.install(repo)
    assert not root.exists()
    assert smoke_called == []
