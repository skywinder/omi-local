import asyncio
import threading

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.testclient import TestClient
import pytest

from omi_live import SessionGate, TrackedNativeCalls


@pytest.mark.parametrize('override, capacity', [(None, 2), ('1', 1)])
def test_admission_and_reuse(monkeypatch, override, capacity):
    if override is None:
        monkeypatch.delenv('WLK_MAX_SESSIONS', raising=False)
    else:
        monkeypatch.setenv('WLK_MAX_SESSIONS', override)
    gate = SessionGate()
    app = FastAPI()

    async def stream(socket):
        await socket.accept()
        try:
            while pcm := await socket.receive_bytes():
                await socket.send_bytes(pcm)
        except WebSocketDisconnect:
            return
        await socket.send_json({'type': 'ready_to_stop'})

    @app.websocket('/asr')
    async def route(socket: WebSocket):
        await gate.serve(socket, stream)

    def assert_busy(client):
        with client.websocket_connect('/asr') as extra:
            assert extra.receive_json() == {'type': 'error', 'error': 'live session busy'}
            with pytest.raises(WebSocketDisconnect) as stopped:
                extra.receive_json()
            assert stopped.value.code == 4409

    with TestClient(app) as client, client.websocket_connect('/asr') as first:
        first.send_bytes(b'first')
        assert first.receive_bytes() == b'first'
        if capacity == 2:
            with client.websocket_connect('/asr') as second:
                second.send_bytes(b'second')
                assert second.receive_bytes() == b'second'
                assert_busy(client)
                second.send_bytes(b'')
                assert second.receive_json() == {'type': 'ready_to_stop'}
        else:
            assert_busy(client)
        first.send_bytes(b'continued')
        assert first.receive_bytes() == b'continued'
        first.send_bytes(b'')
        assert first.receive_json() == {'type': 'ready_to_stop'}
        with client.websocket_connect('/asr') as reopened:
            reopened.send_bytes(b'new')
            assert reopened.receive_bytes() == b'new'


def test_cancelled_stream_keeps_slot_until_native_inference_finishes(monkeypatch):
    monkeypatch.setenv('WLK_MAX_SESSIONS', '2')

    async def run():
        gate = SessionGate()
        started = threading.Event()
        release = threading.Event()
        first_calls = TrackedNativeCalls()
        second_calls = TrackedNativeCalls()
        draining = asyncio.Event()
        second_waiting = asyncio.Event()
        second_ran = threading.Event()

        def first_inference():
            started.set()
            assert release.wait(3)

        async def first(_socket):
            try:
                await first_calls.run(first_inference)
            finally:
                draining.set()
                await first_calls.drain()

        async def second(_socket):
            second_waiting.set()
            await second_calls.run(second_ran.set)

        first_task = asyncio.create_task(gate.serve(None, first))
        try:
            assert await asyncio.to_thread(started.wait, 2)
            first_task.cancel()
            await draining.wait()
            second_task = asyncio.create_task(gate.serve(None, second))
            await second_waiting.wait()
            assert gate.active == 2
            assert not first_task.done()
            assert not second_ran.is_set()
        finally:
            release.set()
        with pytest.raises(asyncio.CancelledError):
            await first_task
        await second_task
        assert second_ran.is_set()
        assert gate.active == 0

    asyncio.run(asyncio.wait_for(run(), timeout=4))
