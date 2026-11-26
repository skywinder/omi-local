"""Supervised, private archive refresh from the paired runtime to the model worker."""

import argparse
import json
import socket
import subprocess
import sys
import time


INTERVAL = 300
EXPORT = (sys.executable, '-m', 'scripts.export_local_semantic_sources')


def refresh(address, command=EXPORT, *, env=None, cwd=None):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
        peer.settimeout(45)
        peer.connect(str(address))
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=cwd, env=env) as export:
            try:
                last = b''
                for line in export.stdout:
                    if last:
                        peer.sendall(last)
                    last = line
                if export.wait(timeout=5) != 0 or not last:
                    raise ValueError('Local archive exporter failed')
                # Release the completion marker only after the exporter exits successfully.
                peer.sendall(last)
            finally:
                if export.poll() is None:
                    export.kill()
        peer.shutdown(socket.SHUT_WR)
        peer.settimeout(1800)
        with peer.makefile('rb') as stream:
            reply = json.loads(stream.readline(4096))
    keys = ('sources', 'updated', 'passages')
    if not isinstance(reply, dict) or any(type(reply.get(key)) is not int or reply[key] < 0 for key in keys):
        raise ValueError('Semantic worker did not accept the inventory')
    return {key: reply[key] for key in keys}


def refresh_forever(address, *, env=None, cwd=None):
    delay = 10
    while True:
        try:
            counts = refresh(address, env=env, cwd=cwd)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            print('Semantic archive refresh unavailable. The last complete index remains available.', flush=True)
            time.sleep(delay)
            delay = min(INTERVAL, delay * 2)
        else:
            print('Semantic archive refreshed:', json.dumps(counts), flush=True)
            delay = 10
            time.sleep(INTERVAL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('socket')
    refresh_forever(parser.parse_args().socket)


if __name__ == '__main__':
    main()
