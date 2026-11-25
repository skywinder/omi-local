"""Authenticated access to a WAV through the paired Conversation's public id."""

import os
import re
from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from starlette.responses import Response, StreamingResponse

from routers.listen.local_status import require_local_status
from utils.other.local_storage import local_storage_root_from_env


def get_playback_conversation(uid, conversation_id):
    from database.conversations import get_conversation

    return get_conversation(uid, conversation_id)


def _byte_range(value, size):
    match = re.fullmatch(r'bytes=([0-9]{0,19})-([0-9]{0,19})', value)
    if not match or not any(match.groups()):
        raise ValueError
    first, last = match.groups()
    start = int(first) if first else max(0, size - int(last))
    end = min(int(last), size - 1) if first and last else size - 1
    if end < start:
        raise ValueError
    return start, end


class _RecordingResponse(StreamingResponse):
    def __init__(self, stream, interval, status, headers):
        self.stream = stream
        start, end = interval
        stream.seek(start)

        def chunks():
            remaining = end - start + 1
            while remaining:
                chunk = stream.read(min(65536, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
                yield chunk

        super().__init__(chunks(), status_code=status, media_type='audio/wav', headers=headers)

    async def __call__(self, scope, receive, send):
        try:
            await super().__call__(scope, receive, send)
        finally:
            self.stream.close()


def build_playback_router(authenticate):
    router = APIRouter()

    @router.get('/v1/local/conversations/{conversation_id}/audio', dependencies=[Depends(require_local_status)])
    def playback(conversation_id: UUID, request: Request, uid: str = Depends(authenticate)):
        from utils.local_playback import open_playback

        if uid != 'alice' or request.scope.get('omi.local_uid') != uid:
            raise HTTPException(403, 'Local owner required')
        storage = local_storage_root_from_env()
        if storage is None:
            raise HTTPException(503, 'Local audio storage unavailable')
        stream = open_playback(uid, str(conversation_id), storage, Path(os.environ['OMI_HARNESS_STATE_ROOT']),
                               get_playback_conversation)
        if stream is None:
            raise HTTPException(404, 'Recording unavailable')
        size = os.fstat(stream.fileno()).st_size
        headers = {'Cache-Control': 'private, no-store', 'Accept-Ranges': 'bytes'}
        ranges = request.headers.getlist('range')
        if ranges:
            try:
                if len(ranges) != 1:
                    raise ValueError
                start, end = _byte_range(ranges[0], size)
            except ValueError:
                stream.close()
                return Response(status_code=416, headers={**headers, 'Content-Range': f'bytes */{size}'})
            headers['Content-Range'] = f'bytes {start}-{end}/{size}'
        else:
            start, end = 0, size - 1
        headers['Content-Length'] = str(end - start + 1)
        return _RecordingResponse(stream, (start, end), 206 if ranges else 200, headers)

    return router
