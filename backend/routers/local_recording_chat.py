"""Paired access to one recording and the harness-owned text provider."""

import json
from datetime import datetime
from typing import Annotated

import httpx
from fastapi import APIRouter, Depends, HTTPException, Path, Query, Response
from pydantic import BaseModel, Field, ValidationError

from database import local_recording_chat as chat_db
from models.chat import ChatEvidenceReference
from routers.local_processing import library_origin
from utils.conversations.local_chat import provider_history, select_sources
from utils.local_transport_auth import require_paired_owner
from utils.offline_network_policy import OfflineEgressBlocked

router = APIRouter(tags=['local'])
_UUID = r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$'
RecordingId = Annotated[str, Path(pattern=_UUID)]


class ChatProvider(BaseModel):
    binding: str = Field(pattern=r'^[0-9a-f]{64}$')
    host: str = Field(min_length=1, max_length=255)
    model: str = Field(min_length=1, max_length=300)


class ChatQuestion(BaseModel):
    id: str = Field(pattern=_UUID)
    previous: str | None = Field(default=None, pattern=_UUID)
    provider_binding: str = Field(pattern=r'^[0-9a-f]{64}$')
    question: str = Field(min_length=1, max_length=1400)


class ChatReply(BaseModel):
    answer: str = Field(min_length=1, max_length=2600)
    sources: list[Annotated[int, Field(strict=True, ge=1)]] = Field(max_length=8)


class ChatTurn(BaseModel):
    id: str
    sequence: int
    created_at: datetime
    question: str
    answer: str
    evidence_references: list[ChatEvidenceReference]
    context_limited: bool


class ChatPage(BaseModel):
    turns: list[ChatTurn]
    next_before: int | None
    provider: ChatProvider | None
    has_transcript: bool


def _library_request(body=None):
    origin = library_origin()
    timeout = 5 if body is None else 72
    try:
        with httpx.Client(trust_env=False, follow_redirects=False, timeout=timeout) as client:
            with client.stream(
                'GET' if body is None else 'POST', origin + '/api/processing/recording-chat',
                headers={'Origin': origin, 'X-Omiloc-Request': 'processing'},
                **({'json': body} if body is not None else {}),
            ) as response:
                if response.status_code == 409:
                    raise HTTPException(409, 'recording_chat_provider_changed')
                if response.status_code != 200:
                    raise ValueError()
                data = bytearray()
                for chunk in response.iter_bytes(chunk_size=8192):
                    data.extend(chunk)
                    if len(data) > 24 * 1024:
                        raise ValueError()
                return data
    except (httpx.HTTPError, OfflineEgressBlocked, ValueError, OSError):
        raise HTTPException(503, 'recording_chat_provider_unavailable') from None


def _recording(uid, conversation_id):
    try:
        return chat_db.recording(uid, conversation_id)
    except chat_db.RecordingUnavailable:
        raise HTTPException(404, 'recording_chat_recording_unavailable') from None


@router.get('/v1/local/conversations/{conversation_id}/chat', response_model=ChatPage)
def read_recording_chat(
    conversation_id: RecordingId, response: Response, before: int | None = Query(default=None, ge=1),
    uid: str = Depends(require_paired_owner),
):
    _, recording = _recording(uid, conversation_id)
    turns, next_before = chat_db.history(uid, conversation_id, before=before)
    provider = None
    if before is None:
        try:
            data = json.loads(_library_request())
            if data['provider'] is not None:
                provider = ChatProvider.model_validate(data['provider'])
        except (HTTPException, ValidationError, ValueError, TypeError, KeyError):
            pass  # History remains available when inference is unavailable.
    response.headers['Cache-Control'] = 'no-store'
    return {'turns': turns, 'next_before': next_before, 'provider': provider,
            'has_transcript': bool(recording.get('transcript_segments'))}


@router.post('/v1/local/conversations/{conversation_id}/chat', response_model=ChatTurn)
def ask_recording_chat(
    conversation_id: RecordingId, prompt: ChatQuestion, response: Response, uid: str = Depends(require_paired_owner),
):
    revision, recording = _recording(uid, conversation_id)
    question = prompt.question.strip()
    if not question:
        raise HTTPException(400, 'recording_chat_empty_question')
    response.headers['Cache-Control'] = 'no-store'
    existing = chat_db.turn(uid, conversation_id, prompt.id)
    if existing is not None:
        if existing['question'] != question:
            raise HTTPException(409, 'recording_chat_history_changed')
        return existing
    recent, _ = chat_db.history(uid, conversation_id, limit=3)
    previous = recent[0] if recent else None
    if prompt.previous != (previous['id'] if previous else None):
        raise HTTPException(409, 'recording_chat_history_changed')

    query = question if previous is None else f"{question}\n{previous['question']}"
    sources, limited = select_sources(recording.get('transcript_segments'), query)
    if not sources:
        raise HTTPException(409, 'recording_chat_no_transcript')
    try:
        reply = ChatReply.model_validate_json(_library_request({
            'binding': prompt.provider_binding, 'question': question,
            'sources': [source['text'] for source in sources],
            'history': provider_history(recent),
        }))
        if any(index > len(sources) for index in reply.sources):
            raise ValueError()
    except (ValidationError, ValueError):
        raise HTTPException(502, 'recording_chat_invalid_sources') from None

    references = []
    for index in dict.fromkeys(reply.sources):
        source = sources[index - 1]
        references.append(ChatEvidenceReference(
            id=f'{prompt.id}:{index}', kind='conversation_segment', state='available',
            conversation_id=conversation_id, segment_id=source['segment_id'],
            start_ms=source['start_ms'], end_ms=source['end_ms'], summary=source['text'][:600],
        ).model_dump(exclude_none=True))
    try:
        return chat_db.publish(uid, conversation_id, prompt.id, prompt.previous, revision, {
            'question': question, 'answer': reply.answer, 'evidence_references': references,
            'context_limited': limited,
        })
    except chat_db.RecordingUnavailable:
        raise HTTPException(404, 'recording_chat_recording_unavailable') from None
    except chat_db.RecordingChanged:
        raise HTTPException(409, 'recording_chat_history_changed') from None
