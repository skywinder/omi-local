"""Owner-scoped, content-free diagnostics for the local listen pipeline."""

from __future__ import annotations

import asyncio
import json
import os
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException

from routers.listen import registry
from utils.env_loader import is_offline_runtime
from utils.http_client import get_local_preview_client, get_local_preview_semaphore
from utils.local_live_preview import preview_url
from utils.offline_audio_capture import OUTPUT_CHANNELS, OUTPUT_SAMPLE_RATE, OUTPUT_SAMPLE_WIDTH_BYTES
from utils.offline_network_policy import OfflineEgressBlocked


def require_local_status() -> None:
    if not is_offline_runtime() or os.environ.get('OMI_LOCAL_TRANSPORT') != 'ngrok':
        raise HTTPException(status_code=404, detail='Local status is unavailable')


async def _worker_state(url: str) -> str:
    health_url = urlsplit(url)._replace(scheme='http', path='/health').geturl()
    try:
        # Bound semaphore wait, connect, and the entire response, including slow
        # chunked bodies. Never follow a worker redirect or inherit proxy env.
        async with asyncio.timeout(1.0):
            async with get_local_preview_semaphore():
                async with get_local_preview_client().stream(
                    'GET', health_url, follow_redirects=False, timeout=0.8
                ) as response:
                    if response.status_code != 200:
                        return 'unavailable'
                    body = bytearray()
                    async for chunk in response.aiter_bytes(chunk_size=4097):
                        body.extend(chunk)
                        if len(body) > 4096:
                            return 'unavailable'
                    health = json.loads(body)
        if not isinstance(health, dict) or health.get('ready') is not True:
            return 'unavailable'
        if type(health.get('active')) is not bool:
            return 'unavailable'
        return 'busy' if health['active'] else 'ready'
    except (TimeoutError, httpx.HTTPError, OSError, ValueError, OfflineEgressBlocked):
        return 'unavailable'


async def snapshot(uid: str) -> dict:
    """Read only this owner's active sessions; counters are not flow liveness."""
    sessions = [
        session for session in registry._sessions_for(uid)
        if session.state.active and not session.state.shutdown_event.is_set()
    ]
    sinks = [session.capture_sink for session in sessions if session.capture_sink is not None]
    frames = sum(sink.frames_received for sink in sinks)
    pcm_bytes = sum(sink.decoded_pcm_bytes for sink in sinks)
    capture_state = 'waiting_audio' if sessions else 'idle'
    if frames:
        capture_state = 'received'
    if any(sink.decode_errors for sink in sinks):
        capture_state = 'decode_error'
    previews = [session.local_preview for session in sessions if session.local_preview is not None]
    updates = sum(preview.updates for preview in previews)
    if any(preview.failed for preview in previews):
        live_state = 'failed'
    elif updates:
        live_state = 'streaming'
    else:
        try:
            url = preview_url()
        except ValueError:
            live_state = 'unavailable'
        else:
            live_state = await _worker_state(url) if url else 'disabled'
    return {
        'backend': 'ready',
        'capture': {
            'state': capture_state,
            'audio_seconds': round(pcm_bytes / (OUTPUT_SAMPLE_RATE * OUTPUT_CHANNELS * OUTPUT_SAMPLE_WIDTH_BYTES), 3),
            'frames_received': frames,
        },
        'live_transcript': {'state': live_state, 'updates': updates},
    }
