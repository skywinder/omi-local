"""Optional RAM-only WLK preview. Finished-WAV transcription remains separate."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from urllib.parse import urlsplit

import websockets

from utils.async_tasks import create_named_task, drain_tasks
from utils.observability.fallback import record_fallback

logger = logging.getLogger(__name__)


def preview_url() -> str | None:
    value = os.getenv('OMI_LOCAL_LIVE_PREVIEW_URL', '').strip()
    if not value:
        return None
    url = urlsplit(value)
    if (url.scheme != 'ws' or url.hostname != '127.0.0.1' or not url.port
            or url.path != '/asr' or url.query or url.fragment or url.username or url.password):
        raise ValueError('Live preview requires ws://127.0.0.1:<port>/asr')
    return value


class PreviewSegment:
    """Full WLK snapshots -> one replaceable Omi segment per listen session.

    WLK full mode retains committed lines and already removes their prefix from
    buffer_transcription. Do not heuristically deduplicate spoken repetitions.
    """

    def __init__(self):
        self.id = f'local-preview-{uuid.uuid4()}'
        self.text = ''

    def update(self, snapshot: dict, audio_seconds: float) -> list[dict] | None:
        if 'lines' not in snapshot or 'buffer_transcription' not in snapshot:
            return None
        parts = [line.get('text', '').strip() for line in snapshot['lines']
                 if line.get('speaker') != -2]
        parts.append(snapshot['buffer_transcription'].strip())
        text = ' '.join(part for part in parts if part)
        if text == self.text:
            return None
        self.text = text
        return [{'id': self.id, 'text': text, 'start': 0.0, 'end': audio_seconds,
                 'speaker': 'SPEAKER_00', 'is_user': False}]


class LocalLivePreview:
    # Transport limits, not ASR quality/latency acceptance criteria. If a local
    # socket stalls for a whole trial recording, stop preview and preserve WAV.
    MAX_PENDING_BYTES = 60 * 32000
    FINISH_TIMEOUT = 60.0

    def __init__(self, url, send_segments):
        self.url = url
        self.send_segments = send_segments
        self.queue = asyncio.Queue()
        self.pending_bytes = 0
        self.audio_bytes = 0
        self.segment = PreviewSegment()
        self.accepting = True
        self.deliver = True
        self.failed = False
        self.updates = 0
        self.eof_ack = False
        self.task = create_named_task(self._run(), name='local-preview-session')

    def _fail(self, reason):
        if not self.failed:
            self.failed = True
            record_fallback(component='stt_selection', from_mode='local_live_preview',
                            to_mode='offline_capture', reason=reason, outcome='degraded')

    def feed(self, pcm: bytes) -> None:
        if not self.accepting or self.task.done():
            return
        if self.pending_bytes + len(pcm) > self.MAX_PENDING_BYTES:
            self._fail('capacity_full')
            self.accepting = False
            self.task.cancel()
            return
        self.audio_bytes += len(pcm)
        self.pending_bytes += len(pcm)
        self.queue.put_nowait(pcm)

    async def _send(self, socket):
        while True:
            pcm = await self.queue.get()
            if pcm is None:
                await socket.send(b'')  # WLK's explicit end-of-input contract.
                return
            self.pending_bytes -= len(pcm)
            await socket.send(pcm)

    async def _receive(self, socket):
        async for raw in socket:
            message = json.loads(raw)
            if message.get('type') == 'ready_to_stop':
                self.eof_ack = True
                return
            if message.get('type') == 'error' or message.get('status') == 'error':
                raise RuntimeError('local_preview_error')
            segments = self.segment.update(message, self.audio_bytes / 32000)
            if segments is not None and self.deliver:
                try:
                    await self.send_segments(segments)
                    self.updates += 1
                    if self.updates == 1:
                        logger.warning('Local preview: first_segment_sent')
                except Exception:
                    # Phone Stop closes /v4/listen. Still consume /asr to EOF.
                    self.deliver = False
        if not self.eof_ack:
            raise RuntimeError('local_preview_closed_without_eof')

    async def _run(self):
        sender = None
        try:
            async with websockets.connect(self.url, open_timeout=3, close_timeout=2) as socket:
                config = json.loads(await asyncio.wait_for(socket.recv(), 3))
                if config.get('type') != 'config' or config.get('useAudioWorklet') is not True:
                    raise RuntimeError('local_preview_pcm_contract')
                sender = create_named_task(self._send(socket), name='local-preview-send')
                receiver = create_named_task(self._receive(socket), name='local-preview-receive')
                try:
                    done, _ = await asyncio.wait([sender, receiver], return_when=asyncio.FIRST_COMPLETED)
                    for task in done:
                        task.result()
                    if receiver in done and not sender.done():
                        raise RuntimeError('local_preview_early_eof')
                    await receiver
                finally:
                    await drain_tasks([sender, receiver], timeout=2, label='local_preview', cancel=True)
        except asyncio.CancelledError:
            raise
        except Exception:
            self._fail('other')
        finally:
            self.accepting = False
            self.segment.text = ''
            while not self.queue.empty():
                self.queue.get_nowait()
            self.pending_bytes = 0

    def end_input(self) -> None:
        self.deliver = False
        if self.accepting:
            self.accepting = False
            self.queue.put_nowait(None)

    async def finish(self) -> None:
        self.end_input()
        try:
            await asyncio.wait_for(asyncio.shield(self.task), self.FINISH_TIMEOUT)
        except asyncio.TimeoutError:
            self._fail('timeout')
            await drain_tasks([self.task], timeout=2, label='local_preview', cancel=True)
        except asyncio.CancelledError:
            await drain_tasks([self.task], timeout=2, label='local_preview', cancel=True)
            if asyncio.current_task().cancelling():
                raise
        finally:
            logger.warning('Local preview ended updates=%d eof_ack=%s failed=%s',
                        self.updates, self.eof_ack, self.failed)
