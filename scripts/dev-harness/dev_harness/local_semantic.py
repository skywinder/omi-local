"""Host-side build and lookup commands for the optional semantic index."""

import argparse
import fcntl
import io
import json
import os
import re
import signal
import socketserver
import sqlite3
import stat
import sys
from dataclasses import asdict
from contextlib import ExitStack
from pathlib import Path
from threading import Thread

from .local_semantic_index import Source, rebuild, search
from .local_semantic_model import LocalSemanticModel


def sources(stream, owner):
    if json.loads(stream.readline()) != {'owner': owner, 'version': 1}:
        raise ValueError('Invalid semantic inventory owner')
    count = 0
    while line := stream.readline(16 * 1024 * 1024 + 1):
        if len(line) > 16 * 1024 * 1024:
            raise ValueError('Semantic inventory row is too large')
        raw = json.loads(line)
        if raw == {'complete': count} and not stream.read(1):
            return
        if not isinstance(raw, dict) or any(not isinstance(raw.get(key), str) or not raw[key] for key in ('id', 'revision')):
            raise ValueError('Invalid canonical recording reference')
        passages = raw.get('passages')
        if not isinstance(passages, list) or any(not isinstance(text, str) for text in passages):
            raise ValueError('Invalid canonical passages')
        yield Source(raw['id'], raw['revision'], enumerate(passages))
        count += 1
    raise ValueError('Incomplete semantic inventory')


class QueryServer(socketserver.UnixStreamServer):
    request_queue_size = 4

    def __init__(self, address, index, owner, model, handler):
        self.index = index
        self.owner = owner
        self.model = model
        super().__init__(address, handler)


class QueryHandler(socketserver.StreamRequestHandler):
    timeout = 6

    def handle(self):
        try:
            request = json.loads(self.rfile.readline(4096))
            if request.get('owner') != self.server.owner or not isinstance(request.get('query'), str):
                raise ValueError('Invalid local semantic request')
            hits = search(self.server.index, self.server.owner, request['query'], self.server.model)
            result = {'hits': [asdict(hit) for hit in hits]}
        except Exception:
            result = {'error': 'semantic_unavailable'}
        _reply(self, result)


class InventoryHandler(socketserver.StreamRequestHandler):
    # Only the local exporter connects. Bound stalls without timing out the entire scan.
    timeout = 45

    def handle(self):
        try:
            with io.TextIOWrapper(self.rfile, encoding='utf-8') as inventory:
                result = rebuild(self.server.index, self.server.owner, sources(inventory, self.server.owner),
                                 self.server.model)
        except Exception:
            result = {'error': 'semantic_refresh_failed'}
        _reply(self, result)

def _reply(handler, result):
    try:
        handler.wfile.write(json.dumps(result, separators=(',', ':')).encode() + b'\n')
    except OSError:
        return


def _open_server(stack, address, index, owner, model, handler):
    path = Path(address)
    if not path.is_absolute() or path.parent.stat().st_mode & 0o077:
        raise ValueError('Semantic socket directory must be private')
    lock = stack.enter_context(open(str(path) + '.lock', 'ab'))
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if path.exists() or path.is_symlink():
        if not stat.S_ISSOCK(path.lstat().st_mode):
            raise ValueError('Invalid semantic socket path')
        path.unlink()
    server = stack.enter_context(QueryServer(str(path), index, owner, model, handler))
    stack.callback(path.unlink, missing_ok=True)
    return server


def serve(address, index, owner, model, refresh_address=None):
    os.umask(0o077)

    def stop(_signo, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    with ExitStack() as stack:
        queries = _open_server(stack, address, index, owner, model, QueryHandler)
        if refresh_address:
            inventory = _open_server(stack, refresh_address, index, owner, model, InventoryHandler)
            Thread(target=inventory.serve_forever, name='semantic-inventory', daemon=True).start()
        queries.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', required=True, help='directory containing the pinned ONNX and tokenizer files')
    parser.add_argument('--index', required=True, help='path to the private, rebuildable SQLite index')
    identity = parser.add_mutually_exclusive_group(required=True)
    identity.add_argument('--owner', help='paired-owner digest stored in the index identity')
    identity.add_argument('--owner-file', help='private file containing the paired-owner digest')
    parser.add_argument('--socket', help='private Unix socket path for paired queries')
    parser.add_argument('--refresh-socket', help='private Unix socket path for complete inventories')
    parser.add_argument('operation', choices=('build', 'search', 'serve'))
    args = parser.parse_args()
    if (args.operation == 'serve') != bool(args.socket) or (args.refresh_socket and not args.socket):
        parser.error('serve requires a private --socket path')
    try:
        owner = args.owner
        if args.owner_file:
            path = Path(args.owner_file)
            if path.is_symlink() or path.stat().st_mode & 0o077:
                raise ValueError('Semantic owner file must be private')
            owner = path.read_text().strip()
            if not re.fullmatch(r'[0-9a-f]{64}', owner):
                raise ValueError('Invalid semantic owner digest')
        model = LocalSemanticModel(args.model)
        if args.operation == 'build':
            result = rebuild(args.index, owner, sources(sys.stdin, owner), model)
        elif args.operation == 'search':
            result = [asdict(hit) for hit in search(args.index, owner, sys.stdin.read(241), model)]
        else:
            serve(args.socket, args.index, owner, model, args.refresh_socket)
            return 0
    except (OSError, ValueError, ImportError, sqlite3.Error):
        # Do not include a private path, an input line or a query in command output.
        print('Local semantic index or model unavailable', file=sys.stderr)
        return 1
    print(json.dumps(result, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    sys.exit(main())
