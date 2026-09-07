import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dev_harness import config, safety
from dev_harness.local_mac import endpoint, pairing_data, private_json, prepare_emulator, require_auth_boundary


@pytest.mark.parametrize(
    'url',
    [
        'http://demo.ngrok.app',
        'https://key@demo.ngrok.app',
        'https://demo.ngrok.app/path',
        'https://demo.ngrok.app?key=x',
        'https://demo.ngrok.app:8000',
        'https://127.0.0.1',
    ],
)
def test_bad_endpoint_rejected(url):
    with pytest.raises(ValueError):
        endpoint(url)


def test_endpoint_and_private_pairing(tmp_path):
    assert endpoint(' https://demo.ngrok.app/ ') == 'https://demo.ngrok.app'
    path = tmp_path / 'pairing.json'
    key = 'a' * 43
    private_json(path, pairing_data(key))
    assert path.stat().st_mode & 0o777 == 0o600
    assert key not in path.read_text()
    assert json.loads(path.read_text())['owner_uid'] == 'alice'
    private_json(path, pairing_data('b' * 43))
    assert json.loads(path.read_text()) == pairing_data('b' * 43)


def test_tunnel_requires_loopback_offline_and_disables_admin(monkeypatch, tmp_path):
    repo = Path(__file__).resolve().parents[3]
    source = {'PROVIDER_MODE': 'offline', 'OMI_LOCAL_TRANSPORT': 'ngrok', 'OMI_DEV_BIND_HOST': '127.0.0.1'}
    cfg = config.load_config(repo, source)
    child = config.child_env_for(cfg)
    assert child['OMI_LOCAL_TRANSPORT'] == 'ngrok'
    assert child['ADMIN_KEY_AUTH_ENABLED'] == 'false'
    assert child['OMI_LOCAL_PAIRING_FILE'].endswith('/pairing.json')
    with pytest.raises(safety.SafetyError):
        config.load_config(repo, {**source, 'OMI_DEV_BIND_HOST': '192.168.50.2'})


def test_public_startup_requires_observed_key_rejection(monkeypatch):
    import io
    import urllib.error
    import urllib.request

    monkeypatch.setattr(urllib.request, 'urlopen', lambda *a, **k: io.BytesIO(b'healthy legacy server'))
    with pytest.raises(ValueError, match='key boundary'):
        require_auth_boundary('http://127.0.0.1:20000')
    checked = []

    def denied(request, **kwargs):
        checked.append(bool(request.get_header('Authorization')))
        raise urllib.error.HTTPError(
            request.full_url, 401, 'Unauthorized', {}, io.BytesIO(b'{"detail":"local_auth_required"}')
        )

    monkeypatch.setattr(urllib.request, 'urlopen', denied)
    require_auth_boundary('http://127.0.0.1:20000')
    assert checked == [False, True]


def test_emulator_reuse_checks_actual_archive(monkeypatch, tmp_path):
    import hashlib

    repo = tmp_path / 'repo'
    meta = repo / 'node_modules/firebase-tools/lib/emulator/downloadableEmulatorInfo.json'
    meta.parent.mkdir(parents=True)
    content = b'synthetic emulator archive'
    meta.write_text(
        json.dumps(
            {
                'firestore': {
                    'downloadPathRelativeToCacheDir': 'test.jar',
                    'expectedSize': len(content),
                    'expectedChecksum': hashlib.md5(content).hexdigest(),
                }
            }
        )
    )
    monkeypatch.setattr(Path, 'home', lambda: tmp_path)
    archive = tmp_path / '.cache/firebase/emulators/test.jar'
    archive.parent.mkdir(parents=True)
    archive.write_bytes(content)
    before = archive.stat().st_mtime_ns
    prepare_emulator(repo)
    assert archive.stat().st_mtime_ns == before


def test_wizard_preserves_pairing_on_repeat_and_address_edit(monkeypatch, tmp_path, capsys):
    from types import SimpleNamespace
    from dev_harness import local_mac

    cfg = SimpleNamespace(layout=SimpleNamespace(state_root=tmp_path), backend_port=20000)
    monkeypatch.setattr(sys.stdin, 'isatty', lambda: True)
    monkeypatch.setattr(sys.stdout, 'isatty', lambda: True)
    monkeypatch.setattr(local_mac.cli, '_service_record', lambda *a: None)
    monkeypatch.setattr('builtins.input', lambda *a: 'https://synthetic.ngrok.app')
    monkeypatch.setattr(local_mac.getpass, 'getpass', lambda *a: 'synthetic-token-for-unit-test')
    monkeypatch.setattr(local_mac.secrets, 'token_urlsafe', lambda n: 'a' * 43)
    local_mac.configure(cfg)
    initial = (tmp_path / 'pairing.json').read_bytes()
    assert b'a' * 43 not in initial
    local_mac.configure(cfg)
    monkeypatch.setattr('builtins.input', lambda *a: 'https://changed.ngrok.app')
    monkeypatch.setattr(local_mac.getpass, 'getpass', lambda *a: '')
    local_mac.configure(cfg, edit=True)
    assert (tmp_path / 'pairing.json').read_bytes() == initial
    assert local_mac.read_config(cfg)['url'] == 'https://changed.ngrok.app'
    monkeypatch.setattr(local_mac.secrets, 'token_urlsafe', lambda n: 'b' * 43)
    local_mac.configure(cfg, rotate=True)
    assert json.loads((tmp_path / 'pairing.json').read_text()) == pairing_data('b' * 43)
    assert 'synthetic-token-for-unit-test' not in capsys.readouterr().out
