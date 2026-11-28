"""Exercise the install guard for the separate Omi Local Next bundle."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from types import SimpleNamespace
from xml.etree import ElementTree as ET

import pytest


ROOT = Path(__file__).resolve().parents[3]
NEXT = ROOT / 'clients/next'
sys.path.insert(0, str(NEXT))
spec = importlib.util.spec_from_file_location('next_iphone', NEXT / 'iphone.py')
iphone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(iphone)
from ios_prepare import prepare_info, prepare_scheme
from dev_harness.server_presets import CHILD_ENV, FILE_ENV, HANDOFF_FIELDS
sys.path.remove(str(NEXT))


def package(tmp_path, bundle):
    app = tmp_path / 'Runner.app'
    app.mkdir()
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': bundle, 'CFBundleName': iphone.NAME, 'CFBundleDisplayName': iphone.NAME,
        'CFBundleExecutable': 'Runner', 'CFBundleVersion': '1', 'CFBundlePackageType': 'APPL',
        'CFBundleSupportedPlatforms': ['iPhoneSimulator'],
    }))
    return app


def test_reject_previous_app_before_inspecting_signature(tmp_path):
    with pytest.raises(ValueError, match='identity'):
        iphone.attest(package(tmp_path, 'org.example.legacy'), simulator=True)


@pytest.mark.parametrize('install,presets', [(False, False), (True, False), (True, True)])
def test_only_opted_in_physical_launch_receives_validated_catalog(tmp_path, monkeypatch, install, presets, capsys):
    key = 'synthetic'.ljust(43, 'x')
    catalog = tmp_path / 'private-fixture.env'
    if presets:
        catalog.write_text('OMI_SERVER_lab_NAME=Fixture\nOMI_SERVER_lab_URL=100.64.0.1:21000\n'
                           f'OMI_SERVER_lab_KEY={key}\n')
        catalog.chmod(0o600)
    # A missing explicit file would fail if either build-only or ordinary install tried to read it.
    environ = {**os.environ, **dict.fromkeys(HANDOFF_FIELDS, 'stale-handoff'), FILE_ENV: str(catalog),
               'OMI_SERVER_lab_KEY': key, 'SIMCTL_CHILD_OMI_LOCAL_SERVER_PRESETS_B64': 'stale-handoff'}
    monkeypatch.setattr(os, 'environ', environ)
    commands = []
    payloads = []

    def observe(command, env):
        args = list(map(str, command))
        commands.append(args)
        env = os.environ if env is None else env
        encoded = env.get(CHILD_ENV)
        assert FILE_ENV not in env and 'OMI_SERVER_lab_KEY' not in env
        assert 'SIMCTL_CHILD_OMI_LOCAL_SERVER_PRESETS_B64' not in env
        assert key not in str(args) and 'stale-handoff' not in env.values()
        if encoded:
            assert args[:5] == ['xcrun', 'devicectl', 'device', 'process', 'launch']
            assert args[-1] == iphone.BUNDLE and encoded not in str(args)
            assert json.loads(base64.b64decode(encoded))['servers'][0]['key'] == key
            payloads.append(encoded)
        return args

    app = tmp_path / 'app'
    app.mkdir()
    def output(command, **kwargs):
        args = observe(command, kwargs.get('env'))
        if args[1:2] == [str(iphone.HERE / 'prepare.py')]:
            return os.fsencode(app)
        if args[:3] == ['flutter', '--version', '--machine']:
            return json.dumps({'frameworkVersion': iphone.PIN['flutter'], 'frameworkRevision': 'fixture'}).encode()
        if args[:2] == ['xcrun', 'devicectl']:
            return b'{"info":{"outcome":"success"}}'
        return b'fixture'

    monkeypatch.setattr(iphone, 'output', output)
    monkeypatch.setattr(iphone.subprocess, 'run', lambda command, **kw: observe(command, kw.get('env')))
    monkeypatch.setattr(iphone, 'select_iphone', lambda: {'hardwareProperties': {'udid': 'fixture-device'}})
    monkeypatch.setattr(iphone, 'attest', lambda *unused: {'bundle': iphone.BUNDLE})
    iphone.run(SimpleNamespace(simulator=False, install=install, with_server_presets=presets,
                               default_server=None, usb=False, repository=tmp_path))
    assert any(args[:3] == ['flutter', 'build', 'ios'] for args in commands)
    assert any(args[:5] == ['xcrun', 'devicectl', 'device', 'install', 'app'] for args in commands) == install
    assert len(payloads) == int(presets)
    proof = (tmp_path / 'ios-device.json').read_text() + capsys.readouterr().out
    assert key not in proof and str(catalog) not in proof and all(payload not in proof for payload in payloads)


def test_device_change_or_invalid_preset_source_prevents_install(tmp_path, monkeypatch):
    phone = {'hardwareProperties': {'udid': 'first-fixture'}}
    monkeypatch.setattr(iphone, 'output', lambda *a, **kw: pytest.fail('unexpected device operation'))
    monkeypatch.setattr(iphone, 'select_iphone', lambda: {'hardwareProperties': {'udid': 'second-fixture'}})
    with pytest.raises(ValueError, match='iPhone changed'):
        iphone.install(tmp_path, False, phone)
    monkeypatch.setattr(iphone, 'select_iphone', lambda: phone)
    with pytest.raises(iphone.LocalEnvError, match='Cannot prepare private server presets'):
        iphone.install(tmp_path, False, phone, with_presets=True, preset_file=str(tmp_path / 'absent'))


def test_usb_install_uploads_default_only_to_next_private_cache(tmp_path, monkeypatch):
    key = 'fixture'.ljust(43, 'x')
    catalog = tmp_path / 'private.env'
    catalog.write_text('OMI_SERVER_lab_NAME=Lab\nOMI_SERVER_lab_URL=100.64.0.1:21000\n'
                       f'OMI_SERVER_lab_KEY={key}\n')
    catalog.chmod(0o600)
    phone = {'hardwareProperties': {'udid': 'fixture-device'}}
    monkeypatch.setattr(iphone, 'select_usb_iphone', lambda: phone)
    commands, temporary = [], []

    def output(command, **kwargs):
        assert key not in ' '.join(command)
        commands.append(command)
        if '--upload' in command:
            path = Path(command[command.index('--upload') + 1])
            temporary.append(path)
            assert path.stat().st_mode & 0o777 == 0o600
            payload = json.loads(base64.b64decode(path.read_bytes()))
            assert payload['default'] == 'lab' and payload['servers'][0]['key'] == key
        return b''

    monkeypatch.setattr(iphone, 'output', output)
    iphone.install_usb(tmp_path / 'Runner.app', phone, preset_file=str(catalog),
                       default_server='lab', with_presets=True)
    assert [command[6] for command in commands] == ['--bundle', '--exists', '--bundle_id']
    assert commands[-1][-1] == '/Library/Caches/omilocal-next-server-preset.b64'
    assert commands[-1][7] == iphone.BUNDLE
    assert len(temporary) == 1 and not temporary[0].exists()


def test_flutter_runner_manifest_drops_upstream_watch_companion(tmp_path):
    manifest = tmp_path / 'Info.plist'
    manifest.write_bytes(plistlib.dumps({
        'WKCompanionAppBundleIdentifier': '$(APP_BUNDLE_IDENTIFIER)',
        'UIApplicationSceneManifest': {'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{}]}},
    }))
    prepare_info(tmp_path)
    actual = plistlib.loads(manifest.read_bytes())
    assert 'WKCompanionAppBundleIdentifier' not in actual
    assert actual['CFBundleDisplayName'] == iphone.NAME
    assert 'bluetooth-central' in actual['UIBackgroundModes']
    assert actual['NSBluetoothAlwaysUsageDescription']


@pytest.mark.skipif(shutil.which('swiftc') is None, reason='Swift toolchain')
def test_cv1_mute_and_stop_fence_queued_notifications(tmp_path):
    main = tmp_path / 'main.swift'
    main.write_text('''import Foundation
      let selected = UUID(), other = UUID()
      var restoration = CV1Restoration<UUID>()
      restoration.remember([other], selected: selected) { $0 }
      precondition(!restoration.isPending)
      restoration.remember([other, selected], selected: selected) { $0 }
      precondition(restoration.isPending && restoration.take() == selected)
      precondition(restoration.take() == nil)
      var subscription = CV1AudioSubscription()
      precondition(subscription.request(true, token: 1) == nil)
      precondition(subscription.emitting == nil)
      subscription.acknowledge(true, token: 1)
      precondition(subscription.emitting == 1)
      precondition(subscription.request(true, token: 2) == "busy")
      precondition(subscription.request(false, token: 1) == nil && subscription.emitting == nil)
      precondition(subscription.request(true, token: 2) == nil)
      subscription.acknowledge(true, token: 1)
      precondition(subscription.emitting == nil)
      subscription.acknowledge(false, token: 1)
      precondition(subscription.emitting == nil)
      subscription.acknowledge(true, token: 2)
      precondition(subscription.emitting == 2)
      precondition(subscription.request(false, token: 1) == "stale" && subscription.emitting == 2)
      precondition(CV1Wire.buttonCode(Data([5, 1, 2, 3, 255])) == 0x03020105)
      precondition(CV1Wire.buttonCode(Data([5])) == nil)
    ''')
    program = tmp_path / 'cv1'
    subprocess.run(['swiftc', '-module-cache-path', str(tmp_path / 'modules'), NEXT / 'ios/CV1Protocol.swift',
                    main, '-o', program], check=True)
    subprocess.run([program], check=True)


def test_scheme_builds_the_runner_it_launches(tmp_path):
    scheme = tmp_path / 'dev.xcscheme'
    scheme.write_text('<Scheme><BuildAction><PreActions/></BuildAction><LaunchAction>'
                      '<BuildableProductRunnable><BuildableReference BlueprintName="Runner" BlueprintIdentifier="A"/>'
                      '</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release-dev"/></Scheme>')
    prepare_scheme(scheme)
    actual = ET.parse(scheme)
    build = actual.find('BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference')
    assert build.attrib == {'BlueprintName': 'Runner', 'BlueprintIdentifier': 'A'}
    assert actual.find('BuildAction/PreActions') is None
    assert actual.find('ProfileAction').get('buildConfiguration') == 'Profile-dev'


@pytest.mark.skipif(sys.platform != 'darwin', reason='macOS signing tools')
def test_signed_simulator_artifact_and_sealed_content(tmp_path):
    app = package(tmp_path, iphone.BUNDLE)
    framework = app / 'Frameworks' / 'OpusKit.framework'
    framework.mkdir(parents=True)
    decoder = tmp_path / 'decoder.c'
    decoder.write_text('int decoder_fixture(void) { return 0; }\n')
    main = tmp_path / 'main.c'
    main.write_text('int decoder_fixture(void); int main(void) { return decoder_fixture(); }\n')
    subprocess.run(['xcrun', 'clang', '-dynamiclib', '-install_name', '@rpath/OpusKit.framework/OpusKit',
                    decoder, '-o', framework / 'OpusKit'], check=True, capture_output=True)
    subprocess.run(['xcrun', 'clang', main, framework / 'OpusKit', '-o', app / 'Runner'],
                   check=True, capture_output=True)
    asset = app / 'Note.txt'
    asset.write_text('fixture')
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', app], check=True, capture_output=True)
    proof = iphone.attest(app, simulator=True)
    assert proof['bundle'] == 'org.omilocal.next'
    assert proof['signature'] == 'passed'
    asset.write_text('modified')
    with pytest.raises(ValueError, match='codesign'):
        iphone.attest(app, simulator=True)


@pytest.mark.skipif(shutil.which('swiftc') is None, reason='Swift toolchain')
def test_cv1_legacy_import_validates_window_and_preserves_received_prefix(tmp_path):
    main = tmp_path / 'main.swift'
    main.write_text('''import Foundation
      func word<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
      }
      let start: UInt64 = 0xAABBCCDD11
      func info(_ count: UInt64) -> Data {
        Data([2]) + word(start) + word(start + count) + word(UInt32(100)) + word(UInt64(0)) + word(UInt16(444))
      }
      func begin(_ n: UInt32) -> Data { Data([5]) + word(start) + word(n) }
      func done(_ n: UInt64) -> Data { Data([4, 0]) + word(start + n) }
      let bounded = CV1LegacyRead(info: info(95), maxRecords: 32)!
      precondition(bounded.command == Data([0x11]) + word(start) + word(UInt32(32)))
      let last = CV1LegacyRead(info: info(95), maxRecords: 12)!
      precondition(last.command == Data([0x11]) + word(start) + word(UInt32(12)))
      precondition(CV1LegacyRead(info: info(95), maxRecords: 0) == nil)
      precondition(CV1LegacyRead(info: info(95), maxRecords: 33) == nil)
      precondition(CV1LegacyRead(info: info(0), maxRecords: 32) == nil && CV1LegacyRead(info: info(101), maxRecords: 32) == nil)
      precondition(CV1LegacyRead(info: info(2) + Data(repeating: 0, count: 10), maxRecords: 32) == nil)
      let identity = word(UInt64(0x1234))
      let modern = info(2) + Data([0x0d, 1]) + identity
      let window = CV1LegacyRead(info: modern, maxRecords: 1)!
      precondition(window.ring == identity && window.start == start && window.count == 1)
      precondition(CV1LegacyRead(info: info(2) + Data([1, 1]) + identity, maxRecords: 1) == nil)
      let data = Data((0..<888).map { UInt8($0 % 251) })
      let read = CV1LegacyRead(info: info(2), maxRecords: 32)!
      precondition(read.receive(begin(2)) == .more)
      precondition(read.receive(Data([3]) + data.prefix(643)) == .more)
      precondition(read.wholeRecords == data.prefix(444))
      precondition(read.receive(Data([3]) + data.suffix(245)) == .more)
      precondition(read.receive(done(2)) == .complete && read.wholeRecords == data)
      let truncated = CV1LegacyRead(info: info(2), maxRecords: 32)!
      precondition(truncated.receive(begin(2)) == .more)
      precondition(truncated.receive(Data([3]) + data.prefix(740)) == .more)
      precondition(truncated.receive(done(2)) == .interrupted && truncated.wholeRecords == data.prefix(444))
      precondition(CV1LegacyRead(info: info(2), maxRecords: 32)!.receive(begin(1)) == .interrupted)
      precondition(CV1LegacyRead(info: info(2), maxRecords: 32)!.receive(Data([3, 0])) == .interrupted)
      let wrongCursor = CV1LegacyRead(info: info(2), maxRecords: 32)!
      precondition(wrongCursor.receive(begin(2)) == .more)
      precondition(wrongCursor.receive(Data([3]) + data) == .more)
      precondition(wrongCursor.receive(done(3)) == .interrupted)
    ''')
    program = tmp_path / 'cv1-archive'
    subprocess.run(['swiftc', '-module-cache-path', str(tmp_path / 'modules'), NEXT / 'ios/CV1Protocol.swift',
                    main, '-o', program], check=True)
    subprocess.run([program], check=True)
