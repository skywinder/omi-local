"""Bound standalone Omi streams and drain native work before releasing slots."""

import asyncio
import hashlib
import importlib.util
import os
from pathlib import Path


class SessionGate:
    def __init__(self):
        limit = os.environ.get('WLK_MAX_SESSIONS', '2')
        if limit not in ('1', '2'):
            raise ValueError('WLK_MAX_SESSIONS must be 1 or 2')
        self.capacity = int(limit)
        self.active = 0

    async def serve(self, websocket, handler):
        if self.active >= self.capacity:
            await websocket.accept()
            await websocket.send_json({'type': 'error', 'error': 'live session busy'})
            await websocket.close(code=4409, reason='live session busy')
            return
        self.active += 1
        try:
            await handler(websocket)
        finally:
            self.active -= 1


# Faster-Whisper shares one model across the standalone server's processors.
_native_lock = asyncio.Lock()


class TrackedNativeCalls:
    def __init__(self):
        self.pending = set()

    async def run(self, method, *args):
        async def invoke():
            async with _native_lock:
                return await asyncio.to_thread(method, *args)

        task = asyncio.create_task(invoke())
        self.pending.add(task)
        task.add_done_callback(self._complete)
        return await asyncio.shield(task)

    def _complete(self, task):
        self.pending.discard(task)
        if not task.cancelled():
            task.exception()

    async def drain(self):
        while self.pending:
            try:
                await asyncio.shield(asyncio.gather(*self.pending, return_exceptions=True))
            except asyncio.CancelledError:
                continue


def patch_install(package):
    """Apply the overlay only to the two known v0.2.26 modules."""
    server = package / 'basic_server.py'
    processor = package / 'audio_processor.py'

    def checked_source(path, expected):
        contents = path.read_bytes()
        if hashlib.sha256(contents).hexdigest() != expected:
            raise RuntimeError(f'unexpected WhisperLiveKit source: {path.name}')
        return contents.decode('utf-8')

    def replace_once(source, anchor, replacement):
        if source.count(anchor) != 1:
            raise RuntimeError(f'expected one WhisperLiveKit overlay anchor: {anchor.strip()}')
        return source.replace(anchor, replacement, 1)

    server_source = checked_source(server, '3557647e74e76d689f603ff59233502931f1559f4f376805f063a85d2283e999')
    processor_source = checked_source(processor, '5d39b72b877cec20677ef906c81a85be9d4b3c9e0d2569a045a334a7c900623a')
    server_source = replace_once(
        server_source, 'config = parse_args()\n',
        'from whisperlivekit.omi_live import SessionGate\n\nconfig = parse_args()\n_asr_gate = SessionGate()\n',
    )
    server_source = replace_once(
        server_source, '    # Read per-session options from query parameters\n',
        '    await _asr_gate.serve(websocket, _serve_asr)\n\n\n'
        'async def _serve_asr(websocket: WebSocket):\n'
        '    # Read per-session options from query parameters\n',
    )
    server_source = replace_once(
        server_source, '            await audio_processor.process_audio(message)\n',
        '            await audio_processor.process_audio(message)\n'
        '            if not message:  # Empty binary frame is EOF.\n'
        '                await websocket_task\n'
        '                break\n',
    )
    processor_source = replace_once(
        processor_source, 'from whisperlivekit.metrics_collector import SessionMetrics\n',
        'from whisperlivekit.metrics_collector import SessionMetrics\n'
        'from whisperlivekit.omi_live import TrackedNativeCalls\n',
    )
    processor_source = replace_once(
        processor_source, '        self._silent_backend_warned: bool = False\n',
        '        self._silent_backend_warned: bool = False\n'
        '        self._native_calls = TrackedNativeCalls()\n',
    )
    processor_source = replace_once(
        processor_source, '        tokens, processed_upto = await asyncio.to_thread(method, *args)\n',
        '        tokens, processed_upto = await self._native_calls.run(method, *args)\n',
    )
    processor_source = replace_once(
        processor_source,
        '        if created_tasks:\n            await asyncio.gather(*created_tasks, return_exceptions=True)\n',
        '        try:\n'
        '            if created_tasks:\n'
        '                await asyncio.gather(*created_tasks, return_exceptions=True)\n'
        '        finally:\n'
        '            await self._native_calls.drain()\n',
    )
    compile(server_source, str(server), 'exec')
    compile(processor_source, str(processor), 'exec')
    (package / 'omi_live.py').write_bytes(Path(__file__).read_bytes())
    server.write_text(server_source, encoding='utf-8')
    processor.write_text(processor_source, encoding='utf-8')


if __name__ == '__main__':
    package = importlib.util.find_spec('whisperlivekit')
    patch_install(Path(package.origin).parent)
