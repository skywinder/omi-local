import io
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dev_harness import local_setup, local_mac


class Terminal(io.StringIO):
    def isatty(self):
        return True


def test_start_stops_at_first_failed_precondition(monkeypatch):
    events = []
    monkeypatch.setattr(local_setup.sys, 'stdin', Terminal())
    monkeypatch.setattr(local_setup.sys, 'stdout', Terminal())
    def fail(_cfg):
        raise local_setup.SetupError('preflight failed')
    monkeypatch.setattr(local_setup, 'check', fail)
    monkeypatch.setattr(local_setup.config, 'load_config', lambda *a, **k: events.append('configure'))
    monkeypatch.setattr(local_mac, 'up', lambda *_: events.append('up'))
    with pytest.raises(local_setup.SetupError, match='preflight failed'):
        local_setup.run(SimpleNamespace(repo_root=Path('.')))
    assert events == []


def test_start_uses_existing_lifecycle_and_prints_short_result(monkeypatch):
    output, events = Terminal(), []
    cfg = SimpleNamespace(repo_root=Path('.'), backend_port=20000)
    monkeypatch.setattr(local_setup.sys, 'stdin', Terminal())
    monkeypatch.setattr(local_setup.sys, 'stdout', output)
    monkeypatch.setattr(local_setup, 'check', lambda _: events.append('check'))
    monkeypatch.setattr(local_setup.local_launcher, 'install', lambda _: events.append('install'))
    monkeypatch.setattr(local_setup.config, 'load_config', lambda *a, **k: cfg)
    monkeypatch.setattr(local_mac, 'configure', lambda _: events.append('configure'))
    monkeypatch.setattr(local_mac, 'up', lambda _: events.append('up') or 0)
    monkeypatch.setattr(local_setup.local_library, 'start', lambda _: events.append('library'))
    monkeypatch.setattr(local_setup.local_stt_watch, 'worker_ready', lambda _: True)
    monkeypatch.setattr(local_setup.webbrowser, 'open', lambda _: events.append('open'))
    assert local_setup.run(cfg) == 0
    assert events == ['check', 'install', 'configure', 'up', 'library', 'open']
    assert 'http://127.0.0.1:20001' in output.getvalue()
    assert '┌' in output.getvalue() and 'Терминал можно закрыть' in output.getvalue()
    assert len(output.getvalue().splitlines()) < 18


def test_start_refuses_noninteractive_secret_output(monkeypatch):
    monkeypatch.setattr(local_setup.sys, 'stdin', io.StringIO())
    with pytest.raises(local_setup.SetupError, match='Terminal'):
        local_setup.run(SimpleNamespace())


def test_first_pairing_shows_box_once_and_repeat_preserves_hash(monkeypatch, tmp_path):
    output = Terminal()
    monkeypatch.setattr(local_mac.sys, 'stdin', Terminal())
    monkeypatch.setattr(local_mac.sys, 'stdout', output)
    monkeypatch.setattr('builtins.input', lambda _: 'https://example.ngrok.app')
    monkeypatch.setattr(local_mac.getpass, 'getpass', lambda _: 'synthetic-agent-token-123456')
    monkeypatch.setattr(local_mac.cli, '_service_record', lambda *a: None)
    monkeypatch.setattr(local_mac.secrets, 'token_urlsafe', lambda _: 'x' * 43)
    cfg = SimpleNamespace(layout=SimpleNamespace(state_root=tmp_path), backend_port=20000)
    local_mac.configure(cfg)
    saved = (tmp_path / 'pairing.json').read_bytes()
    assert '┌' in output.getvalue() and 'x' * 43 in output.getvalue()
    assert b'x' * 43 not in saved
    output.seek(0)
    output.truncate()
    local_mac.configure(cfg)
    assert (tmp_path / 'pairing.json').read_bytes() == saved
    assert 'x' * 43 not in output.getvalue()
    assert 'Домен: https://example.ngrok.app' in output.getvalue()
