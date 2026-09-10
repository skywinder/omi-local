"""Run an existing Argmax binary with loopback-only networking and private temporary audio."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--settings', type=Path, required=True)
    args = parser.parse_args()
    data = json.loads(args.settings.read_text())
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix='argmax-', dir=args.settings.parent) as temporary:
        env = {key: os.environ[key] for key in ('HOME', 'PATH', 'LANG') if key in os.environ}
        env.update(TMPDIR=temporary, OS_ACTIVITY_MODE='disable')
        policy = ('(version 1)(allow default)(deny network*)'
                  '(allow network-inbound (local ip "localhost:*"))'
                  '(allow network-outbound (remote ip "localhost:*"))')
        command = ['/usr/bin/sandbox-exec', '-p', policy, data['binary'], 'serve',
                   '--model', data['model'], '--model-path', data['model_dir'],
                   '--download-tokenizer-path', data['tokenizer_dir'],
                   '--host', '127.0.0.1', '--port', str(data['port']),
                   '--audio-encoder-compute-units', 'cpuAndNeuralEngine',
                   '--text-decoder-compute-units', 'cpuAndNeuralEngine',
                   '--concurrent-worker-count', '1', '--skip-special-tokens']
        process = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def stop(signum, frame):
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        code = process.wait()
        if code:
            print(f"Argmax stopped (exit {code})", flush=True)
        return code


if __name__ == '__main__':
    raise SystemExit(main())
