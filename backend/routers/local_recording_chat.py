"""Paired recording and archive chat with verifiable transcript evidence."""

import json
import math
import re
from datetime import datetime, timezone
from time import monotonic
from typing import Annotated

import httpx
from fastapi import APIRouter, Depends, HTTPException, Path, Query, Response
from google.api_core.exceptions import DeadlineExceeded
from pydantic import BaseModel, Field, ValidationError

from database import local_recording_chat as chat_db
from database.conversations import read_local_search_page, read_local_search_sources
from models.chat import ChatEvidenceReference
from routers.local_processing import library_origin
from utils.conversations import local_semantic_search
from utils.conversations.local_chat import (
    merge_archive_sources, provider_history, rank_archive_sources, select_sources, semantic_archive_source,
)
from utils.local_transcript import hydrate_grouped_transcript, local_transcript_root
from utils.local_transport_auth import require_paired_owner
from utils.observability.fallback import record_fallback
from utils.offline_network_policy import OfflineEgressBlocked

router = APIRouter(tags=['local'])
_UUID = r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$'
# A floor for the deployed multilingual E5 cosine score, not a probability.
_ARCHIVE_SEMANTIC_MIN_SCORE = 0.78
_ARCHIVE_SEMANTIC_LIMIT = 6
_ARCHIVE_HISTORY_SOURCE_LIMIT = 128
RecordingId = Annotated[str, Path(pattern=_UUID)]
ArchiveThreadId = Annotated[str, Path(pattern=_UUID)]


class ChatProvider(BaseModel):
    binding: str = Field(pattern=r'^[0-9a-f]{64}$')
    host: str = Field(min_length=1, max_length=255)
    model: str = Field(min_length=1, max_length=300)


class ChatPrompt(BaseModel):
    id: str = Field(pattern=_UUID)
    provider_binding: str = Field(pattern=r'^[0-9a-f]{64}$')
    question: str = Field(min_length=1, max_length=1400)


class ChatContextTurn(BaseModel):
    question: str = Field(min_length=1, max_length=1400)
    answer: str = Field(min_length=1, max_length=2600)


class ChatQuestion(ChatPrompt):
    previous: str | None = Field(default=None, pattern=_UUID)


class ArchiveQuestion(ChatQuestion):
    history: list[ChatContextTurn] = Field(default_factory=list, max_length=3)
    store: bool = False


class ArchiveThreadDraft(BaseModel):
    id: str = Field(pattern=_UUID)
    title: str = Field(min_length=1, max_length=100)


class ArchiveThread(BaseModel):
    id: str
    title: str
    created_at: datetime


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
    scan_limited: bool = False
    sources_unavailable: bool = False


class ChatPage(BaseModel):
    turns: list[ChatTurn]
    next_before: int | None
    provider: ChatProvider | None
    has_transcript: bool
    stored_history: bool = False
    archive_threads: bool = False


def _library_request(body=None, *, archive=False, suggestions=False):
    operation = 'task-suggestions' if suggestions else ('archive-chat' if archive else 'recording-chat')
    return library_request(
        operation, body, timeout=72, size_limit=(64 if suggestions else 24) * 1024, error_prefix='recording_chat',
    )


def library_request(operation, body, *, timeout, size_limit, error_prefix='local_processing'):
    origin = library_origin()
    path = '/api/processing/' + operation
    timeout = 5 if body is None else timeout
    try:
        with httpx.Client(trust_env=False, follow_redirects=False, timeout=timeout) as client:
            with client.stream(
                'GET' if body is None else 'POST', origin + path,
                headers={'Origin': origin, 'X-Omiloc-Request': 'processing'},
                **({'json': body} if body is not None else {}),
            ) as response:
                if response.status_code == 409:
                    raise HTTPException(409, error_prefix + '_provider_changed')
                if response.status_code != 200:
                    raise ValueError()
                data = bytearray()
                for chunk in response.iter_bytes(chunk_size=8192):
                    data.extend(chunk)
                    if len(data) > size_limit:
                        raise ValueError()
                return data
    except (httpx.HTTPError, OfflineEgressBlocked, ValueError, OSError):
        raise HTTPException(503, error_prefix + '_provider_unavailable') from None


def _recording(uid, conversation_id):
    try:
        return chat_db.recording(uid, conversation_id)
    except chat_db.RecordingUnavailable:
        raise HTTPException(404, 'recording_chat_recording_unavailable') from None


def _chat_provider(*, archive=False, suggestions=False):
    try:
        data = json.loads(_library_request(archive=archive, suggestions=suggestions))
        if data['provider'] is not None:
            return ChatProvider.model_validate(data['provider'])
    except (HTTPException, ValidationError, ValueError, TypeError, KeyError):
        pass  # Chat remains accessible when inference is unavailable.
    return None


def _ask_provider(prompt, question, sources, history, *, recordings=None):
    payload = {
        'binding': prompt.provider_binding, 'question': question,
        'sources': [source['text'] for source in sources],
        'history': provider_history(history),
    }
    if recordings is not None:
        payload['recordings'] = recordings
    try:
        reply = ChatReply.model_validate_json(_library_request(payload, archive=recordings is not None))
        if any(index > len(sources) for index in reply.sources):
            raise ValueError()
        return reply
    except (ValidationError, ValueError):
        raise HTTPException(502, 'recording_chat_invalid_sources') from None


def _references(request_id, reply, sources):
    references = []
    for index in dict.fromkeys(reply.sources):
        source = sources[index - 1]
        references.append(ChatEvidenceReference(
            id=f'{request_id}:{index}', kind='conversation_segment', state='available',
            conversation_id=source['conversation_id'], segment_id=source['segment_id'],
            start_ms=source['start_ms'], end_ms=source['end_ms'], summary=source['text'][:600],
            title=source.get('title'),
        ).model_dump(exclude_none=True))
    return references


@router.get('/v1/local/conversations/{conversation_id}/chat', response_model=ChatPage)
def read_recording_chat(
    conversation_id: RecordingId, response: Response, before: int | None = Query(default=None, ge=1),
    uid: str = Depends(require_paired_owner),
):
    _, recording = _recording(uid, conversation_id)
    turns, next_before = chat_db.history(uid, conversation_id, before=before)
    response.headers['Cache-Control'] = 'no-store'
    return {'turns': turns, 'next_before': next_before, 'provider': _chat_provider() if before is None else None,
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
    for source in sources:
        source['conversation_id'] = conversation_id
    reply = _ask_provider(prompt, question, sources, recent)
    try:
        return chat_db.publish(uid, conversation_id, prompt.id, prompt.previous, revision, {
            'question': question, 'answer': reply.answer, 'evidence_references': _references(prompt.id, reply, sources),
            'context_limited': limited,
        })
    except chat_db.RecordingUnavailable:
        raise HTTPException(404, 'recording_chat_recording_unavailable') from None
    except chat_db.RecordingChanged:
        raise HTTPException(409, 'recording_chat_history_changed') from None


@router.get('/v1/local/conversations/chat', response_model=ChatPage)
def read_archive_chat(response: Response, stored: bool = False, before: int | None = Query(default=None, ge=1),
                      uid: str = Depends(require_paired_owner)):
    return _archive_page(response, uid, stored=stored, before=before)


@router.get('/v1/local/conversations/chat/threads/{thread_id}', response_model=ChatPage)
def read_archive_thread(thread_id: ArchiveThreadId, response: Response, before: int | None = Query(default=None, ge=1),
                        uid: str = Depends(require_paired_owner)):
    return _archive_page(response, uid, stored=True, before=before, thread_id=thread_id)


def _archive_page(response, uid, *, stored, before, thread_id=None):
    response.headers['Cache-Control'] = 'no-store'
    try:
        turns, cursor = chat_db.archive_history(uid, before=before, thread_id=thread_id) if stored else ([], None)
    except chat_db.ArchiveThreadUnavailable:
        raise HTTPException(404, 'archive_chat_thread_unavailable') from None
    return {'turns': turns, 'next_before': cursor, 'provider': _chat_provider(archive=True) if before is None else None,
            'has_transcript': True, 'stored_history': stored, 'archive_threads': stored}


@router.get('/v1/local/conversations/chat/threads', response_model=list[ArchiveThread])
def list_archive_threads(response: Response, uid: str = Depends(require_paired_owner)):
    response.headers['Cache-Control'] = 'no-store'
    return chat_db.archive_threads(uid)


@router.post('/v1/local/conversations/chat/threads', response_model=ArchiveThread, status_code=201)
def create_archive_thread(draft: ArchiveThreadDraft, response: Response, uid: str = Depends(require_paired_owner)):
    title = draft.title.strip()
    if not title or not title.isprintable():
        raise HTTPException(400, 'archive_chat_invalid_title')
    response.headers['Cache-Control'] = 'no-store'
    try:
        return chat_db.create_archive_thread(uid, draft.id, title)
    except chat_db.ArchiveThreadUnavailable:
        raise HTTPException(404, 'archive_chat_thread_unavailable') from None
    except chat_db.ArchiveChatLimit:
        raise HTTPException(409, 'archive_chat_thread_limit') from None
    except chat_db.RecordingChanged:
        raise HTTPException(409, 'recording_chat_history_changed') from None


@router.delete('/v1/local/conversations/chat/threads/{thread_id}', status_code=204)
def delete_archive_thread(thread_id: ArchiveThreadId, uid: str = Depends(require_paired_owner)):
    try:
        chat_db.delete_archive_thread(uid, thread_id)
    except chat_db.ArchiveThreadUnavailable:
        raise HTTPException(404, 'archive_chat_thread_unavailable') from None
    except chat_db.ArchiveChatLimit:
        raise HTTPException(409, 'archive_chat_turn_limit') from None


def _semantic_archive_sources(uid, query, hydrate):
    sources = []
    try:
        hits = [hit for hit in local_semantic_search.rank(uid, query)
                if type(score := hit.get('score')) in {int, float} and math.isfinite(score)
                and _ARCHIVE_SEMANTIC_MIN_SCORE <= score <= 1.001]
        rows = read_local_search_sources(uid, list(dict.fromkeys(hit['id'] for hit in hits)))
        for identifier, row, passage in local_semantic_search.resolve_passages(hits, rows, hydrate):
            if source := semantic_archive_source(identifier, row, passage):
                sources.append(source)
                if len(sources) == _ARCHIVE_SEMANTIC_LIMIT:
                    break
    except (DeadlineExceeded, local_semantic_search.SemanticUnavailable) as error:
        record_fallback(component='other', from_mode='archive_chat_hybrid', to_mode='archive_chat_keyword',
                        reason='timeout' if isinstance(error, DeadlineExceeded) else 'capability_mismatch',
                        outcome='degraded')
    return sources


@router.post('/v1/local/conversations/chat', response_model=ChatTurn)
def ask_archive_chat(prompt: ArchiveQuestion, response: Response, uid: str = Depends(require_paired_owner)):
    return _answer_archive_chat(prompt, response, uid)


@router.post('/v1/local/conversations/chat/threads/{thread_id}', response_model=ChatTurn)
def ask_archive_thread(thread_id: ArchiveThreadId, prompt: ChatQuestion, response: Response,
                       uid: str = Depends(require_paired_owner)):
    return _answer_archive_chat(ArchiveQuestion(**prompt.model_dump(), store=True), response, uid, thread_id=thread_id)


def _answer_archive_chat(prompt, response, uid, *, thread_id=None):
    question = prompt.question.strip()
    if not question:
        raise HTTPException(400, 'recording_chat_empty_question')
    response.headers['Cache-Control'] = 'no-store'
    if prompt.store and prompt.history:
        raise HTTPException(400, 'archive_chat_history_is_server_owned')
    if prompt.store:
        try:
            existing = chat_db.archive_turn(uid, prompt.id, thread_id=thread_id)
            if existing is not None:
                if existing['question'] != question:
                    raise HTTPException(409, 'recording_chat_history_changed')
                return existing
            recent, _ = chat_db.archive_history(uid, limit=3, thread_id=thread_id)
        except chat_db.ArchiveThreadUnavailable:
            raise HTTPException(404, 'archive_chat_thread_unavailable') from None
        if prompt.previous != (recent[0]['id'] if recent else None):
            raise HTTPException(409, 'recording_chat_history_changed')
        if thread_id is not None and recent and chat_db.archive_thread_full(recent[0]['sequence']):
            raise HTTPException(409, 'archive_chat_turn_limit')
        history = [turn for turn in recent if not turn.get('sources_unavailable')]
    else:
        history = [turn.model_dump() for turn in prompt.history]

    deadline = monotonic() + 26
    scan_limited = False
    root = local_transcript_root()

    def hydrate(row):
        return hydrate_grouped_transcript(row, root, uid)

    def archive_rows():
        nonlocal scan_limited
        cursor = None
        while True:
            remaining = deadline - monotonic()
            if remaining <= 0:
                scan_limited = True
                return
            try:
                rows, cursor = read_local_search_page(uid, cursor, 32, timeout=min(8, remaining))
            except DeadlineExceeded:
                scan_limited = True
                return
            for row in rows:
                if monotonic() >= deadline:
                    scan_limited = True
                    return
                if not re.fullmatch(_UUID, row['id']):
                    continue
                try:
                    checked = hydrate(row)
                except (OSError, ValueError):
                    scan_limited = True
                    continue
                yield checked
            if cursor is None:
                return

    previous = history[0]['question'] if history else ''
    semantic_query = '\n'.join(filter(None, (question, previous)))[:240].rstrip()
    semantic = _semantic_archive_sources(uid, semantic_query, hydrate)
    keyword = rank_archive_sources(archive_rows(), question, previous)
    sources = merge_archive_sources(keyword, semantic)
    if not sources:
        reason = 'archive_chat_scan_limited' if scan_limited else 'archive_chat_no_match'
        raise HTTPException(422, reason)

    revisions = {source['conversation_id']: source['revision'] for source in sources}
    if not chat_db.sources_current(uid, revisions):
        raise HTTPException(409, 'recording_chat_history_changed')
    groups = {}
    recordings = []
    for source in sources:
        group = groups.setdefault(source['conversation_id'], len(groups) + 1)
        started = source['started_at']
        title = ''.join(char for char in (source['title'] or '') if char.isprintable())
        recordings.append({
            'recording': group, 'title': title.encode('utf-8')[:260].decode('utf-8', errors='ignore'),
            'started_at': started.isoformat() if isinstance(started, datetime) else '',
        })
    referenced_ids = set(revisions)
    if prompt.store:
        context = []
        for turn in history:
            extended = referenced_ids.union(turn['source_ids'])
            if len(extended) <= _ARCHIVE_HISTORY_SOURCE_LIMIT:
                context.append(turn)
                referenced_ids = extended
        history = context
        if not chat_db.archive_sources_available(uid, referenced_ids):
            raise HTTPException(409, 'recording_chat_history_changed')
    reply = _ask_provider(prompt, question, sources, history, recordings=recordings)

    payload = {
        'question': question,
        'answer': reply.answer, 'evidence_references': _references(prompt.id, reply, sources),
        'context_limited': True, 'scan_limited': scan_limited,
    }
    if prompt.store:
        try:
            return chat_db.publish_archive(uid, prompt.id, prompt.previous, revisions,
                                           {**payload, 'source_ids': sorted(referenced_ids)}, thread_id=thread_id)
        except chat_db.ArchiveThreadUnavailable:
            raise HTTPException(404, 'archive_chat_thread_unavailable') from None
        except chat_db.ArchiveChatLimit:
            raise HTTPException(409, 'archive_chat_turn_limit') from None
        except chat_db.RecordingChanged:
            raise HTTPException(409, 'recording_chat_history_changed') from None
    if not chat_db.sources_current(uid, revisions):
        raise HTTPException(409, 'recording_chat_history_changed')
    return {'id': prompt.id, 'sequence': 0, 'created_at': datetime.now(timezone.utc), **payload}
