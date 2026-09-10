"""Wire/lifecycle tests with synthetic text; Core ML is exercised by local replay."""
import asyncio
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from .serve_parakeet import Worker, create_app


class FakeWorker:
    def __init__(self):
        self.process = SimpleNamespace(returncode=None)
        self.messages = asyncio.Queue()
        self.starts = 0
        self.loads = 0
        self.closed = False
        self.text = ''

    async def start(self):
        self.loads += 1

    async def send(self, kind, pcm=b''):
        if kind == 1:
            self.starts += 1
            self.text = ''
            await self.messages.put({'type': 'started'})
        elif kind == 2:
            self.text += ' phrase'
            await self.messages.put({'type': 'snapshot', 'text': self.text})
        elif kind == 3:
            await self.messages.put({'type': 'finished'})

    async def read(self):
        return await self.messages.get()

    async def close(self):
        self.closed = True
        self.process.returncode = -9


class ParakeetWireTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        lock = Path(self.directory.name) / 'lock'
        lock.touch()
        self.worker = FakeWorker()
        self.client = TestClient(create_app(self.worker, lock, lambda *a, **kw: None))

    def test_updates_stop_and_fresh_session_reuse_loaded_worker(self):
        with self.client as client:
            for _ in range(2):
                with client.websocket_connect('/asr') as ws:
                    self.assertEqual(ws.receive_json()['type'], 'config')
                    ws.send_bytes(b'\0\0')
                    first = ws.receive_json()['lines'][0]['text']
                    self.assertEqual(first, 'phrase')
                    ws.send_bytes(b'\0\0')
                    self.assertEqual(ws.receive_json()['lines'][0]['text'], first + ' phrase')
                    ws.send_bytes(b'')
                    self.assertEqual(ws.receive_json()['type'], 'ready_to_stop')
                health = client.get('/health').json()
                self.assertFalse(health['active'])
                self.assertEqual(health['last']['outcome'], 'passed')
            self.assertEqual(self.worker.loads, 1)
            self.assertEqual(self.worker.starts, 2)

    def test_busy_and_disconnect_drain(self):
        with self.client as client:
            with client.websocket_connect('/asr') as first:
                first.receive_json()
                with client.websocket_connect('/asr') as second:
                    with self.assertRaises(WebSocketDisconnect) as error:
                        second.receive_json()
                    self.assertEqual(error.exception.code, 1013)
                first.send_bytes(b'\0\0')
                first.receive_json()
            # Session context waits for handler cleanup after disconnect.
            self.assertFalse(client.get('/health').json()['active'])
            self.assertFalse(self.worker.closed)

    def test_invalid_pcm_stops_worker_before_new_session(self):
        with self.client as client:
            with client.websocket_connect('/asr') as ws:
                ws.receive_json()
                ws.send_bytes(b'\0')
                self.assertEqual(ws.receive_json()['type'], 'error')
            self.assertTrue(self.worker.closed)
            health = client.get('/health').json()
            self.assertFalse(health['ready'])
            self.assertFalse(health['active'])


class WorkerProcessTests(unittest.IsolatedAsyncioTestCase):
    async def test_large_snapshots_preserve_text_and_following_messages(self):
        worker = Worker(None, None)
        worker.process = await asyncio.create_subprocess_exec(
            sys.executable, '-c',
            'import json; '
            'print(json.dumps({"type":"snapshot","text":"synthetic речь "*12000}, ensure_ascii=False)); '
            'print(json.dumps({"type":"finished"})); '
            'print(json.dumps({"type":"snapshot","text":"fresh session"}))',
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        try:
            message = await asyncio.wait_for(worker.read(), 5)
            self.assertEqual(message, {'type': 'snapshot', 'text': 'synthetic речь ' * 12000})
            self.assertEqual(await worker.read(), {'type': 'finished'})
            self.assertEqual(await worker.read(), {'type': 'snapshot', 'text': 'fresh session'})
            await worker.process.wait()
        finally:
            await worker.close()

    async def test_truncated_message_is_not_accepted_at_eof(self):
        worker = Worker(None, None)
        reader = asyncio.StreamReader()
        reader.feed_data(json.dumps({'type': 'snapshot', 'text': 'synthetic'}).encode())
        reader.feed_eof()
        worker.process = SimpleNamespace(stdout=reader)
        with self.assertRaisesRegex(RuntimeError, 'parakeet_worker_closed'):
            await worker.read()

if __name__ == '__main__':
    unittest.main()
