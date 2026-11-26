"""Build Omi Local Next for an iPhone or iOS Simulator and optionally install it."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

from ios_prepare import BUNDLE, NAME
from prepare import HERE, PIN, ROOT

sys.path.insert(0, str(ROOT / 'scripts/dev-harness'))
from dev_harness.launch_iphone import select_iphone, LocalEnvError
from dev_harness.server_presets import CHILD_ENV, FILE_ENV, clean_environment, launch_environment


def isolate_host_environment():
    """Keep private pairing inputs out of every child, including Xcode's device discovery."""
    preset_file = os.environ.get(FILE_ENV)
    clean = clean_environment(os.environ)
    for name in tuple(os.environ):
        if name not in clean or name == FILE_ENV or name.startswith(('OMI_SERVER_', 'DEVICECTL_CHILD_', 'SIMCTL_CHILD_')):
            del os.environ[name]
    return preset_file


def output(command, **kwargs):
    proc = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if proc.returncode:
        raise ValueError(f'{Path(command[0]).name} failed during {command[1]}')
    return proc.stdout


def hash_files(files, root):
    digest = hashlib.sha256()
    for path in sorted(files):
        if path.is_symlink():
            raise ValueError(f'Unexpected symlink at {path.relative_to(root)}')
        if path.is_file():
            digest.update(str(path.relative_to(root)).encode() + b'\0')
            with path.open('rb') as stream:
                content = hashlib.sha256()
                for block in iter(lambda: stream.read(1 << 20), b''):
                    content.update(block)
                digest.update(content.digest())
    return digest.hexdigest()


def attest(app, simulator, phone=None):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    platform = 'iPhoneSimulator' if simulator else 'iPhoneOS'
    if (info.get('CFBundleIdentifier'), info.get('CFBundleDisplayName')) != (BUNDLE, NAME):
        raise ValueError('Unexpected application identity')
    if platform not in info.get('CFBundleSupportedPlatforms', []):
        raise ValueError('Artifact platform mismatch')
    if info.get('CFBundleURLTypes') or (app / 'Watch').exists() or (app / 'PlugIns').exists():
        raise ValueError('Unexpected URL registration or embedded companion')
    executable = app / info['CFBundleExecutable']
    if executable.parent != app or executable.is_symlink():
        raise ValueError('Invalid app executable')
    opus = app / 'Frameworks/OpusKit.framework/OpusKit'
    if not opus.is_file() or b'OpusKit.framework/OpusKit' not in output(['otool', '-L', executable]):
        raise ValueError('iOS app is missing the linked CV1 calibration decoder')
    output(['codesign', '--verify', '--deep', '--strict', app])
    raw = output(['codesign', '-d', '--entitlements', ':-', app])
    rights = plistlib.loads(raw) if raw.strip() else {}
    allowed = {'application-identifier', 'com.apple.developer.team-identifier', 'keychain-access-groups',
               'get-task-allow', 'com.apple.security.get-task-allow'}
    if rights.keys() - allowed:
        raise ValueError('Unexpected signing entitlements')
    team = rights.get('com.apple.developer.team-identifier')
    expected = team + '.' + BUNDLE if team else None
    if set(rights.get('keychain-access-groups', ())) - ({expected} if expected else set()):
        raise ValueError('Unexpected shared keychain')
    if not simulator:
        if not expected or rights.get('application-identifier') != expected:
            raise ValueError('Signature identity mismatch')
        if (app / 'Frameworks/App.framework/flutter_assets/kernel_blob.bin').exists():
            raise ValueError('Expected a Profile device artifact')
        profile = plistlib.loads(output(['security', 'cms', '-D', '-i', app / 'embedded.mobileprovision']))
        if (team not in profile.get('TeamIdentifier', []) or
                profile['ExpirationDate'].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc) or
                (phone and phone['hardwareProperties']['udid'] not in profile.get('ProvisionedDevices', []))):
            raise ValueError('Incorrect or expired development provisioning')
    return {'bundle': BUNDLE, 'signature': 'passed', 'entitlements': sorted(rights),
            'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
            'artifact_sha256': hash_files(app.rglob('*'), app), 'artifact': str(app)}


def boot_simulator():
    devices = json.loads(output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
    candidates = [d for runtime, items in devices.items() if '.iOS-' in runtime for d in items
                  if d.get('deviceTypeIdentifier', '').split('.')[-1].startswith('iPhone-')]
    if not candidates:
        raise ValueError('No available iPhone simulator')
    device = next((d for d in candidates if d['state'] == 'Booted'), candidates[0])
    identifier = device['udid']
    output(['xcrun', 'simctl', 'bootstatus', identifier, '-b'], timeout=180)
    return identifier


def install(app, simulator, device, *, with_presets=False, preset_file=None, default_server=None):
    if simulator:
        output(['xcrun', 'simctl', 'install', device, app])
        output(['xcrun', 'simctl', 'launch', device, BUNDLE])
        return
    device_id = device['hardwareProperties']['udid']
    if select_iphone()['hardwareProperties']['udid'] != device_id:
        raise ValueError('The selected iPhone changed after attestation')
    runtime = None
    if with_presets:
        source = dict(os.environ)
        if preset_file is not None:
            source[FILE_ENV] = preset_file
        try:
            runtime, _ = launch_environment(ROOT, environ=source, required=True, default_server=default_server)
        except LocalEnvError:
            raise LocalEnvError('Cannot prepare private server presets; check the file and its permissions.') from None
        runtime.pop(FILE_ENV, None)
    for command, env in ((['install', 'app', str(app)], None), (['process', 'launch', BUNDLE], runtime)):
        args = ['xcrun', 'devicectl', 'device', *command[:2], '--device', device_id,
                '--timeout', '120', '--json-output', '/dev/stdout', '--quiet', command[2]]
        if json.loads(output(args, env=env)).get('info', {}).get('outcome') != 'success':
            raise ValueError('Device did not confirm ' + command[0])


def select_usb_iphone():
    events = output(['ios-deploy', '--detect', '--no-wifi', '--timeout', '4', '--json'], timeout=12).decode().strip()
    decoder = json.JSONDecoder()
    phones = set()
    while events:
        event, end = decoder.raw_decode(events)
        events = events[end:].lstrip()
        device = event.get('Device', {})
        identifier = device.get('DeviceIdentifier')
        if (event.get('Event') == 'DeviceDetected' and event.get('Interface') == 'USB'
                and device.get('DeviceClass') == 'iPhone' and identifier):
            phones.add(identifier)
    if len(phones) != 1:
        raise ValueError('Connect exactly one trusted iPhone over USB')
    return {'hardwareProperties': {'udid': phones.pop()}}


def install_usb(app, device, *, preset_file=None, default_server=None, with_presets=False):
    payload = None
    if with_presets:
        source = dict(os.environ)
        if preset_file is not None:
            source[FILE_ENV] = preset_file
        runtime, _ = launch_environment(ROOT, environ=source, required=True, default_server=default_server)
        payload = runtime[CHILD_ENV]
    if select_usb_iphone() != device:
        raise ValueError('The selected USB iPhone changed after attestation')
    args = ['ios-deploy', '--id', device['hardwareProperties']['udid'], '--no-wifi', '--timeout', '15']
    output([*args, '--bundle', str(app)], timeout=120)
    output([*args, '--exists', '--bundle_id', BUNDLE], timeout=30)
    if payload is not None:
        with tempfile.TemporaryDirectory() as work:
            private = Path(work) / 'startup-preset'
            private.touch(mode=0o600)
            private.write_text(payload, encoding='ascii')
            output([*args, '--bundle_id', BUNDLE, '--upload', str(private), '--to',
                    '/Library/Caches/omilocal-next-server-preset.b64'], timeout=30)


def run(args):
    if args.with_server_presets and (not args.install or args.simulator):
        raise ValueError('--with-server-presets requires a physical iPhone --install')
    if args.default_server and not args.with_server_presets:
        raise ValueError('--default-server requires --with-server-presets')
    if args.usb and (not args.install or args.simulator):
        raise ValueError('--usb requires a physical iPhone --install')
    preset_file = isolate_host_environment()
    env = dict(os.environ)
    sim = args.simulator
    config = 'Debug-dev' if sim else 'Profile-dev'
    device = None
    if args.install:
        if sim:
            device = boot_simulator()
        else:
            device = select_usb_iphone() if args.usb else select_iphone()
    app = Path(output([sys.executable, str(HERE / 'prepare.py'), args.repository]).decode().strip())
    version = json.loads(output(['flutter', '--version', '--machine'], env=env))
    if version['frameworkVersion'] != PIN['flutter']:
        raise ValueError('Use Flutter ' + PIN['flutter'])
    subprocess.run(['flutter', 'pub', 'get', '--enforce-lockfile'], cwd=app, env=env, check=True)
    roots = [app / 'lib', app / 'assets', app / 'ios' / 'Runner']
    files = [f for root in roots for f in root.rglob('*') if f.is_file()]
    files += [app / f for f in ('pubspec.yaml', 'pubspec.lock', 'ios/Podfile')]
    # Native inputs originate from the pinned git archive plus this build overlay.
    inputs = [PIN['commit'], version['frameworkRevision'], config, hash_files(files, app),
              hash_files([HERE / 'ios_prepare.py', HERE / 'ios/AppDelegate.swift', HERE / 'ios/Podfile'], HERE),
              output(['xcodebuild', '-version']).decode(), output(['pod', '--version']).decode(),
              hashlib.sha256(env.get('OMI_APPLE_TEAM_ID', '').encode()).hexdigest()]
    state = app.parent / ('ios-simulator.json' if sim else 'ios-device.json')
    product = app / 'build/ios' / ('iphonesimulator' if sim else 'iphoneos') / 'Runner.app'
    try:
        saved = json.loads(state.read_text())
        reuse = saved['inputs'] == inputs and saved['proof'] == attest(product, sim, device if not sim else None)
    except (OSError, KeyError, ValueError):
        reuse = False
    print('Decision:', 'reuse' if reuse else 'build', config, flush=True)
    if not reuse:
        command = ['flutter', 'build', 'ios', '--no-pub', '--flavor', 'dev', '--target', 'lib/main_local_next.dart']
        command += ['--simulator', '--debug'] if sim else ['--profile']
        subprocess.run(command, cwd=app, env=env, check=True)
    proof = attest(product, sim, device if not sim else None)
    commit = saved['commit'] if reuse else output(['git', '-C', ROOT, 'rev-parse', 'HEAD']).decode().strip()
    record = {'inputs': inputs, 'configuration': config, 'commit': commit, 'upstream': PIN['commit'], 'proof': proof}
    with tempfile.NamedTemporaryFile(mode='w', dir=state.parent, delete=False) as temp:
        json.dump(record, temp)
        temp.write('\n')
    Path(temp.name).replace(state)
    print('Local commit', commit, '| upstream', PIN['commit'])
    print(json.dumps(proof, ensure_ascii=False), flush=True)
    if args.install:
        settings = dict(with_presets=args.with_server_presets, preset_file=preset_file,
                        default_server=args.default_server)
        if args.usb:
            install_usb(product, device, **settings)
            print(f'{NAME} installed. Open it on the iPhone to finish startup.')
        else:
            install(product, sim, device, **settings)
            print(f'{NAME} installed and launched.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', type=Path, help='local BasedHardware/omi clone')
    parser.add_argument('--simulator', action='store_true')
    parser.add_argument('--install', action='store_true')
    parser.add_argument('--with-server-presets', action='store_true',
                        help='import private server presets on the separately installed iPhone app’s launch')
    parser.add_argument('--default-server', help='connect a newly imported preset ID on first launch')
    parser.add_argument('--usb', action='store_true', help='install through ios-deploy without starting a debugger')
    try:
        run(parser.parse_args())
    except (LocalEnvError, ValueError, OSError, subprocess.SubprocessError) as exc:
        # Device IDs can occur in tool command arguments and error output.
        print('Blocked:', str(exc) if isinstance(exc, (LocalEnvError, ValueError)) else type(exc).__name__, file=sys.stderr)
        sys.exit(1)
