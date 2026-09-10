"""Trial Parakeet /asr: existing PCM16 and full-snapshot wire contract."""

import argparse
import asyncio
from contextlib import asynccontextmanager, suppress
import fcntl
import json
import logging
import os
from pathlib import Path
import struct
import sys
import time

from .serve import deny_network


class Worker:
    def __init__(self, binary, model_dir):
        self.binary = binary
        self.model_dir = model_dir
        self.process = None

    async def start(self):
        self.process = await asyncio.create_subprocess_exec(
            '/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)',
            str(self.binary), str(self.model_dir), stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            env={**os.environ, 'OS_ACTIVITY_MODE': 'disable'},
        )
        if (await asyncio.wait_for(self.read(), 60)).get('type') != 'model_ready':
            raise RuntimeError('parakeet_start_failed')

    async def read(self):
        raw = await self.process.stdout.readline()
        if not raw:
            raise RuntimeError('parakeet_worker_closed')
        message = json.loads(raw)
        if message.get('type') == 'error':
            raise RuntimeError('parakeet_worker_failed')
        return message

    async def send(self, kind, pcm=b''):
        self.process.stdin.write(struct.pack('!I', len(pcm) + 1) + bytes([kind]) + pcm)
        await self.process.stdin.drain()

    async def close(self):
        if self.process is not None and self.process.returncode is None:
            self.process.kill()
            await self.process.wait()  # No inference survives lock release.


def create_app(worker, lock_path, emit):
    from fastapi import FastAPI, WebSocket
    from starlette.websockets import WebSocketDisconnect

    active = False
    ready = False
    completed = 0
    last = None
    lock = lock_path.open('r+')

    @asynccontextmanager
    async def lifespan(app):
        nonlocal ready
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            await worker.start()
            ready = True
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
        emit('model_ready')
        try:
            yield
        finally:
            ready = False
            await worker.close()
            lock.close()

    app = FastAPI(lifespan=lifespan)

    @app.get('/health')
    async def health():
        return {'ready': ready and worker.process.returncode is None, 'active': active,
                'completed': completed, 'last': last, 'profile': 'parakeet-v3-int8-ane-auto',
                'chunk_s': 11, 'left_context_s': 2, 'right_context_s': 2}

    @app.websocket('/asr')
    async def asr(socket: WebSocket):
        nonlocal active, ready, completed, last
        await socket.accept()
        if not ready or active:
            await socket.close(code=1013, reason='live_preview_busy')
            return
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            await socket.close(code=1013, reason='final_transcription_busy')
            return
        active = True
        started = time.monotonic()
        stopped = None
        received = 0
        snapshots = 0
        first_text = None
        disconnected = False
        outcome = 'passed'
        reader = None
        feeder = None
        try:
            await worker.send(1)
            if (await asyncio.wait_for(worker.read(), 3)).get('type') != 'started':
                raise RuntimeError('parakeet_session_start_failed')
            await socket.send_json({'type': 'config', 'useAudioWorklet': True, 'mode': 'full'})

            async def results():
                nonlocal snapshots, first_text, disconnected
                previous = ''
                while True:
                    message = await worker.read()
                    if message.get('type') == 'finished':
                        return
                    if message.get('type') != 'snapshot':
                        raise RuntimeError('parakeet_protocol_error')
                    text = message['text'].strip()
                    if not text or text == previous:
                        continue
                    previous = text
                    snapshots += 1
                    if first_text is None:
                        first_text = round(time.monotonic() - started, 3)
                        emit('first_text', seconds=first_text)
                    if not disconnected:
                        try:
                            await socket.send_json({'lines': [{'text': text, 'speaker': 0}],
                                                    'buffer_transcription': ''})
                        except (WebSocketDisconnect, RuntimeError, OSError):
                            disconnected = True

            async def feed():
                nonlocal received, stopped, disconnected
                try:
                    while True:
                        pcm = await socket.receive_bytes()
                        if len(pcm) % 2:
                            raise ValueError('unaligned_pcm16')
                        if not pcm:
                            break
                        received += len(pcm)
                        await worker.send(2, pcm)
                except WebSocketDisconnect:
                    disconnected = True
                stopped = time.monotonic()
                await worker.send(3)

            reader = asyncio.create_task(results(), name='parakeet-results')
            feeder = asyncio.create_task(feed(), name='parakeet-pcm')
            emit('session_started')
            done, _ = await asyncio.wait([reader, feeder], return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
            if reader in done and not feeder.done():
                raise RuntimeError('parakeet_early_eof')
            await asyncio.wait_for(asyncio.shield(reader), 60)
        except asyncio.TimeoutError:
            outcome = 'indeterminate'
        except (Exception, asyncio.CancelledError):
            outcome = 'failed'
        finally:
            for task in (feeder, reader):
                if task is not None:
                    task.cancel()
                    with suppress(Exception, asyncio.CancelledError):
                        await task
            if outcome != 'passed':
                ready = False
                await worker.close()
            fcntl.flock(lock, fcntl.LOCK_UN)
            active = False
            completed += 1
            last = {'outcome': outcome, 'audio_s': round(received / 32000, 3),
                    'snapshots': snapshots, 'first_text_s': first_text,
                    'stop_drain_s': round(time.monotonic() - stopped, 3) if stopped else None}
            emit('session_finished', **last)
            if not disconnected:
                with suppress(WebSocketDisconnect, RuntimeError, OSError):
                    await socket.send_json({'type': 'ready_to_stop' if outcome == 'passed' else 'error'})
                    await socket.close()

    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--model-dir', type=Path, required=True)
    parser.add_argument('--inference-lock', type=Path, required=True)
    parser.add_argument('--port', type=int, default=18090)
    args = parser.parse_args()
    output = os.fdopen(os.dup(1), 'w', buffering=1)
    null = os.open(os.devnull, os.O_WRONLY)
    os.dup2(null, 1); os.dup2(null, 2); os.close(null)
    logging.disable(logging.CRITICAL)

    def emit(event, **fields):
        output.write(json.dumps({'event': event, **fields}) + '\n')

    try:
        sys.addaudithook(deny_network)
        import uvicorn
        app = create_app(Worker(args.worker.resolve(strict=True), args.model_dir.resolve(strict=True)),
                         args.inference_lock, emit)
        uvicorn.run(app, host='127.0.0.1', port=args.port, access_log=False, log_config=None)
    except Exception as error:
        emit('startup_failed', error_type=type(error).__name__)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
