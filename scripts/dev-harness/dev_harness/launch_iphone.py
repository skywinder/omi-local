"""Provision the installed local iPhone app without embedding secrets in its binary."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess

from .local_env import LocalEnvError, read_env


def capture(args, *, env=None):
    result = subprocess.run(args, env=env, capture_output=True)
    if result.returncode:
        raise LocalEnvError('iPhone operation failed; check device connection, unlock and signing')
    return result.stdout


def launch(env_file, app):
    values = read_env(env_file)
    app = Path(app)
    capture(['codesign', '--verify', '--deep', '--strict', str(app)])
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    bundle = info['CFBundleIdentifier']
    if not bundle.startswith('com.omi.local.'):
        raise LocalEnvError('Only the separately signed local iPhone app can receive these settings')
    devices = json.loads(capture(['xcrun', 'devicectl', 'list', 'devices',
                                 '--json-output', '/dev/stdout', '--quiet']))['result']['devices']
    phones = [d for d in devices if d['hardwareProperties'].get('deviceType') == 'iPhone'
              and d['connectionProperties'].get('tunnelState') == 'connected']
    if len(phones) != 1:
        raise LocalEnvError('Connect and unlock exactly one iPhone')
    env = {**os.environ,
           'DEVICECTL_CHILD_OMI_LOCAL_MAC_URL': values['OMI_NGROK_URL'],
           'DEVICECTL_CHILD_OMI_LOCAL_MAC_KEY': values['OMI_LOCAL_APP_KEY']}
    # The ngrok agent credential is deliberately not forwarded, even if ambient.
    env.pop('NGROK_AUTHTOKEN', None)
    env.pop('DEVICECTL_CHILD_NGROK_AUTHTOKEN', None)
    result = json.loads(capture([
        'xcrun', 'devicectl', 'device', 'process', 'launch',
        '--device', phones[0]['hardwareProperties']['udid'], '--terminate-existing',
        '--json-output', '/dev/stdout', '--quiet', bundle,
    ], env=env))
    if result.get('info', {}).get('outcome') != 'success':
        raise LocalEnvError('iPhone launch was not confirmed')
    print('Local iPhone app restarted with private pairing settings; ngrok authtoken stayed on Mac')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--env', type=Path, default=Path('.env'))
    parser.add_argument('--app', type=Path, default=Path('app/build/ios/Profile-dev-iphoneos/Runner.app'))
    args = parser.parse_args()
    try:
        launch(args.env, args.app)
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(str(error) if isinstance(error, LocalEnvError) else 'Invalid local app or settings; secrets not displayed')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
