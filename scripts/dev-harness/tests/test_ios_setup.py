"""Native tools are simulated; the production shell checks and terminal retries run."""
import json
import os
import pty
import select
import subprocess
import sys
import time
from pathlib import Path
from datetime import datetime, timedelta, timezone
import plistlib

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts/dev-harness'))
from dev_harness import ios_debug


@pytest.fixture
def ios(tmp_path):
    cert = tmp_path / 'cert.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=Apple Development: Synthetic/OU=ABCDEFGHIJ',
                    '-keyout', str(tmp_path / 'key.pem'), '-out', str(cert)],
                   check=True, capture_output=True)
    fingerprint = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-noout',
                                           '-fingerprint', '-sha1'], text=True).strip().split('=')[1].replace(':', '')
    phone = {'identifier': 'TEST-PHONE', 'platform': 'com.apple.platform.iphoneos',
             'simulator': False, 'available': True, 'operatingSystemVersion': '26.6'}
    (tmp_path / 'phone.json').write_text(json.dumps([phone]))
    (tmp_path / 'details.json').write_text(json.dumps({'result': {
        'connectionProperties': {'pairingState': 'paired'},
        'deviceProperties': {'developerModeStatus': 'enabled', 'ddiServicesAvailable': True}}}))
    (tmp_path / 'lock.json').write_text(json.dumps({'result': {'passcodeRequired': False, 'unlockedSinceBoot': True}}))
    for name in ['tools-ready', 'signing-ready', 'phone-ready']:
        (tmp_path / name).touch()
    env = {**os.environ, 'TEST_ROOT': str(tmp_path), 'TEST_CERT_SHA': fingerprint,
           'OMI_APPLE_TEAM_ID': 'ABCDEFGHIJ', 'OMI_IOS_DEVICE_ID': '', 'NO_COLOR': '1'}
    script = tmp_path / 'check.sh'
    script.write_text('''
source "$1/app/setup.sh"
xcodebuild() {
  echo xcode >>"$TEST_ROOT/events"
  [[ -f "$TEST_ROOT/tools-ready" ]] || return 1
  [[ "$1" != -checkFirstLaunchStatus || "${TEST_FAIL:-}" != license ]] || return 1
  echo 'Xcode 26.6'
}
flutter() {
  if [[ "$1" == --version ]]; then
    [[ "${TEST_FAIL:-}" != flutter ]] || return 1
    echo 'Flutter 3.44.5'
  else
    echo '[{"id":"TEST-PHONE","targetPlatform":"ios","emulator":false,"isSupported":true}]'
  fi
}
pod() { echo 1.16.2; [[ "${TEST_FAIL:-}" != pod ]]; }
security() {
  echo signing >>"$TEST_ROOT/events"
  [[ "${TEST_FAIL:-}" != keychain ]] || return 1
  if [[ "$1" == find-identity ]]; then
    if [[ -f "$TEST_ROOT/signing-ready" ]]; then echo "1) $TEST_CERT_SHA \"Apple Development: Synthetic\""; fi
  else
    [[ "${TEST_FAIL:-}" != missing_certificate ]] || return 44
    cat "$TEST_ROOT/cert.pem"
  fi
}
xcrun() {
  case "$1" in
    --sdk) [[ "${TEST_FAIL:-}" != sdk ]] || return 1; echo "$TEST_ROOT" ;;
    xcdevice)
      echo phone >>"$TEST_ROOT/events"
      [[ -f "$TEST_ROOT/phone-ready" ]] || return 1
      cat "$TEST_ROOT/phone.json" ;;
    devicectl)
      echo "$4" >>"$TEST_ROOT/events"
      [[ "${TEST_FAIL:-}" != coredevice ]] || return 1
      case "$4" in details) cat "$TEST_ROOT/details.json";; lockState) cat "$TEST_ROOT/lock.json";; esac ;;
  esac
}
case "$2" in
  tools) check_ios_prerequisites ;;
  signing) check_ios_signing ;;
  all) prepare_ios_installation ;;
  check-entry)
    # Execute the user-facing check-only branch with the same native seams.
    uname() { case "$1" in -s) echo Darwin;; -m) echo arm64;; esac; }
    brew() { echo "$TEST_ROOT"; }
    export -f xcodebuild flutter pod security xcrun uname brew
    bash "$TEST_ENTRY_ROOT/start.command" --iphone-check ;;
esac
''')
    return tmp_path, script, env


def run(ios, mode='all', **overrides):
    _, script, env = ios
    return subprocess.run(['bash', str(script), str(ROOT), mode], env={**env, **overrides},
                          capture_output=True, text=True, timeout=15)


@pytest.mark.parametrize('failure, message', [('license', 'первый запуск Xcode'), ('sdk', 'iOS SDK'),
    ('flutter', 'Flutter'), ('pod', 'CocoaPods')])
def test_tools_stop_with_remedy_before_signing_or_phone(ios, failure, message):
    root, _, _ = ios
    result = run(ios, TEST_FAIL=failure)
    assert result.returncode != 0 and message in result.stderr
    assert 'signing' not in (root / 'events').read_text()
    assert 'phone' not in (root / 'events').read_text()


@pytest.mark.parametrize('failure', ['missing_key', 'wrong_team', 'missing_certificate', 'keychain'])
def test_signing_requires_identity_and_certificate_ou_without_printing_them(ios, failure):
    root, _, env = ios
    if failure == 'missing_key':
        (root / 'signing-ready').unlink()
    result = run(ios, mode='signing', TEST_FAIL=failure,
                 OMI_APPLE_TEAM_ID='KLMNOPQRST' if failure == 'wrong_team' else env['OMI_APPLE_TEAM_ID'])
    assert result.returncode != 0
    assert 'Связк' in result.stderr
    if failure != 'keychain':
        assert 'Manage Certificates' in result.stderr
    assert env['TEST_CERT_SHA'] not in result.stdout + result.stderr
    assert env['OMI_APPLE_TEAM_ID'] not in result.stdout + result.stderr


@pytest.mark.parametrize('failure', ['', 'phone_missing', 'locked', 'developer_mode', 'coredevice', 'old_ios'])
def test_phone_readiness_uses_live_results_and_keeps_older_ios(ios, failure):
    root, _, _ = ios
    if failure == 'phone_missing':
        (root / 'phone-ready').unlink()
    elif failure == 'locked':
        (root / 'lock.json').write_text('{"result":{"passcodeRequired":true,"unlockedSinceBoot":true}}')
    elif failure == 'developer_mode':
        (root / 'details.json').write_text('{"result":{"deviceProperties":{"developerModeStatus":"disabled"}}}')
    elif failure == 'old_ios':
        phones = json.loads((root / 'phone.json').read_text())
        phones[0]['operatingSystemVersion'] = '15.8'
        (root / 'phone.json').write_text(json.dumps(phones))
    result = run(ios, TEST_FAIL=failure)
    assert (result.returncode == 0) == (failure in ['', 'old_ios'])
    assert ('Подготовка к установке на iPhone проверена.' in result.stderr) == (result.returncode == 0)
    assert 'TEST-PHONE' not in result.stdout + result.stderr
    if failure == 'old_ios':
        assert 'details' not in (root / 'events').read_text()


@pytest.mark.parametrize('cancel', [False, True])
def test_interactive_wait_rechecks_each_stage_and_can_cancel(ios, cancel):
    root, script, env = ios
    for name in ['tools-ready', 'signing-ready', 'phone-ready']:
        (root / name).unlink()
    master, slave = pty.openpty()
    process = subprocess.Popen(['bash', str(script), str(ROOT), 'all'], env=env,
                               stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    output = b''
    def until_prompt():
        nonlocal output
        deadline = time.monotonic() + 10
        new = b''
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                new += os.read(master, 65536)
                if 'q — выйти: '.encode() in new:
                    output += new
                    return new.decode()
        raise AssertionError('setup did not wait for user input')
    try:
        assert 'Xcode' in until_prompt()
        assert 'signing' not in (root / 'events').read_text()
        # Enter alone must not bypass the unresolved prerequisite.
        os.write(master, b'\n')
        assert 'Xcode' in until_prompt()
        assert 'signing' not in (root / 'events').read_text()
        (root / 'tools-ready').touch()
        os.write(master, b'\n')
        assert 'Manage Certificates' in until_prompt()
        assert 'phone' not in (root / 'events').read_text()
        (root / 'signing-ready').touch()
        os.write(master, b'\n')
        assert 'готовность телефона' in until_prompt()
        if cancel:
            os.write(master, b'q\n')
            assert process.wait(timeout=5) != 0
            assert 'Подготовка к установке на iPhone проверена.' not in output.decode()
        else:
            (root / 'phone-ready').touch()
            os.write(master, b'\n')
            assert process.wait(timeout=5) == 0
            assert (root / 'events').read_text().splitlines()[-1] == 'lockState'
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


def test_check_only_entry_does_not_build_or_generate_config(ios):
    root, _, _ = ios
    checkout = root / 'clean checkout'
    for name in ['start.command', 'app/setup.sh', 'scripts/macos-runtime.sh']:
        target = checkout / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / name).read_bytes())
    for name in ['backend/.python-version', 'backend/pylock.macos.toml', 'package.json',
                 'package-lock.json', 'firebase.json', 'web-local/index.html']:
        target = checkout / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('source input')
    before = {p: p.read_bytes() for p in checkout.rglob('*') if p.is_file()}
    result = run(ios, mode='check-entry', TEST_ENTRY_ROOT=str(checkout))
    assert result.returncode == 0, result.stderr
    assert 'Сборка и установка не запускались' in result.stdout
    assert 'TEST-PHONE' not in result.stdout + result.stderr
    assert {p: p.read_bytes() for p in checkout.rglob('*') if p.is_file()} == before


def test_debug_build_attest_run_and_reuse_order(monkeypatch, tmp_path, capsys):
    events = []
    artifact = tmp_path / 'app/build/ios/Debug-dev-iphoneos/Runner.app'
    monkeypatch.setattr(ios_debug, 'prepare', lambda root: ({}, 'TEAM', 'com.omi.local.test', 'PHONE', [], b'tools'))
    monkeypatch.setattr(ios_debug, 'fingerprint', lambda *args: 'inputs')
    monkeypatch.setattr(ios_debug, 'capture', lambda *args, **kwargs: b'synthetic-commit')
    monkeypatch.setattr(sys.stdin, 'isatty', lambda: True)

    def run(args, *unused):
        events.append(args[1])
        assert '--debug' in args and '--profile' not in args and '--release' not in args
        assert all(define in args for define in ios_debug.DEFINES)
        assert not any('KEY=' in arg for arg in args)
        if args[1] == 'build':
            artifact.mkdir(parents=True)
        else:
            assert '--use-application-binary=' + str(artifact) in args

    def attest(*args):
        events.append('attest')
        assert args[0] == artifact
        return 'digest', ['get-task-allow']

    monkeypatch.setattr(ios_debug, 'run_flutter', run)
    monkeypatch.setattr(ios_debug, 'attest', attest)
    ios_debug.session(tmp_path)
    assert events == ['build', 'attest', 'run']
    events.clear()
    ios_debug.session(tmp_path)
    assert events == ['attest', 'attest', 'run']
    record = tmp_path / '.local/ios-debug.json'
    assert record.stat().st_mode & 0o077 == 0
    assert 'PHONE' not in record.read_text() and 'TEAM' not in record.read_text()
    assert 'Decision: reuse' in capsys.readouterr().out


def test_debug_failed_attestation_never_launches_or_records_success(monkeypatch, tmp_path):
    events = []
    monkeypatch.setattr(ios_debug, 'prepare', lambda root: ({}, 'TEAM', 'bundle', 'PHONE', [], b'tools'))
    monkeypatch.setattr(ios_debug, 'fingerprint', lambda *args: 'inputs')
    monkeypatch.setattr(ios_debug, 'capture', lambda *args, **kwargs: b'commit')
    monkeypatch.setattr(sys.stdin, 'isatty', lambda: True)
    monkeypatch.setattr(ios_debug, 'run_flutter', lambda args, *rest: events.append(args[1]))

    def reject(*args):
        raise ios_debug.LocalEnvError('Invalid signature')

    monkeypatch.setattr(ios_debug, 'attest', reject)
    with pytest.raises(ios_debug.LocalEnvError):
        ios_debug.session(tmp_path)
    assert events == ['build']
    assert not (tmp_path / '.local/ios-debug.json').exists()


@pytest.mark.parametrize('defect', [None, 'locked-entitlement', 'expired', 'wrong-phone', 'profile-build'])
def test_debug_attestation_contract(monkeypatch, tmp_path, defect):
    artifact = tmp_path / 'Runner.app'
    assets = artifact / 'Frameworks/App.framework/flutter_assets'
    assets.mkdir(parents=True)
    if defect != 'profile-build':
        (assets / 'kernel_blob.bin').write_bytes(b'synthetic kernel')
    (artifact / 'Runner').write_bytes(b'synthetic executable')
    (artifact / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'Runner', 'CFBundleIdentifier': 'com.omi.local.test'}))
    ent = {'application-identifier': 'TEAM.com.omi.local.test', 'com.apple.developer.team-identifier': 'TEAM',
           'get-task-allow': defect != 'locked-entitlement'}
    expiry = datetime.now(timezone.utc) + timedelta(days=-1 if defect == 'expired' else 1)
    profile = {'ExpirationDate': expiry.replace(tzinfo=None), 'TeamIdentifier': ['TEAM'],
               'ProvisionedDevices': ['OTHER' if defect == 'wrong-phone' else 'PHONE']}

    def capture(args, **kwargs):
        if args[0] == 'security':
            return plistlib.dumps(profile)
        return plistlib.dumps(ent) if '-d' in args else b''

    monkeypatch.setattr(ios_debug, 'capture', capture)
    if defect:
        with pytest.raises(ios_debug.LocalEnvError):
            ios_debug.attest(artifact, 'TEAM', 'com.omi.local.test', 'PHONE')
    else:
        assert len(ios_debug.attest(artifact, 'TEAM', 'com.omi.local.test', 'PHONE')[0]) == 64


def test_debug_output_redacts_identifiers_and_vm_capability_url():
    text = ios_debug.redact('PHONE TEAM user@example.com ws://127.0.0.1:1234/private-token=/ws', ['PHONE', 'TEAM'])
    assert 'PHONE' not in text and 'TEAM' not in text and 'user@example' not in text
    assert 'private-token' not in text and '127.0.0.1' not in text
