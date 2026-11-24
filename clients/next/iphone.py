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
from dev_harness.server_presets import clean_environment


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


def install(app, simulator, device):
    if simulator:
        output(['xcrun', 'simctl', 'install', device, app])
        output(['xcrun', 'simctl', 'launch', device, BUNDLE])
    else:
        for command in (['install', 'app', str(app)], ['process', 'launch', BUNDLE]):
            args = ['xcrun', 'devicectl', 'device', *command[:2], '--device', device['hardwareProperties']['udid'],
                    '--timeout', '120', '--json-output', '/dev/stdout', '--quiet', *command[2:]]
            if json.loads(output(args)).get('info', {}).get('outcome') != 'success':
                raise ValueError('Device did not confirm ' + command[0])


def run(args):
    env = clean_environment(os.environ)
    sim = args.simulator
    config = 'Debug-dev' if sim else 'Profile-dev'
    device = None
    if args.install:
        device = boot_simulator() if sim else select_iphone()
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
        install(product, sim, device)
        print('Omi Local Next installed and launched.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', type=Path, help='local BasedHardware/omi clone')
    parser.add_argument('--simulator', action='store_true')
    parser.add_argument('--install', action='store_true')
    try:
        run(parser.parse_args())
    except (LocalEnvError, ValueError, OSError, subprocess.SubprocessError) as exc:
        # Device IDs can occur in tool command arguments and error output.
        print('Blocked:', str(exc) if isinstance(exc, (LocalEnvError, ValueError)) else type(exc).__name__, file=sys.stderr)
        sys.exit(1)
