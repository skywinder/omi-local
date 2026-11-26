"""Owner-reviewed local facts; extraction only creates proposals."""
import hashlib
import json
from collections import Counter
from typing import Annotated, Literal
from uuid import NAMESPACE_URL, uuid5

from fastapi import APIRouter, Depends, HTTPException, Path, Query, Response
from pydantic import BaseModel, Field, StringConstraints, ValidationError

from database import local_memories as memories, local_recording_chat as archive
from models.memory_evidence import MemoryEvidence
from routers.local_recording_chat import ChatProvider, _UUID, library_request
from utils.conversations.local_chat import select_sources
from utils.conversations.semantic_passages import source_revision
from utils.local_transport_auth import require_paired_owner

router = APIRouter(tags=['local'])
Identifier = Annotated[str, Path(pattern=_UUID)]
Text = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=600)]


class Extract(BaseModel):
    request_id: str = Field(pattern=_UUID)
    provider_binding: str = Field(pattern=r'^[a-f0-9]{64}$')


class ProposedFact(BaseModel):
    content: Text
    quote: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]
    source: int = Field(strict=True, ge=1, le=120)


class Proposals(BaseModel):
    proposals: list[ProposedFact] = Field(max_length=12)


class Provider(BaseModel):
    provider: ChatProvider | None


class Review(BaseModel):
    request_id: str = Field(pattern=_UUID)
    revision: str = Field(pattern=_UUID)
    action: Literal['accept', 'edit', 'reject', 'delete']
    content: Text | None = None


def _recording(uid, identifier):
    try:
        return archive.recording(uid, identifier)
    except archive.RecordingUnavailable:
        raise HTTPException(404, 'local_memory_source_unavailable') from None


@router.get('/v1/local/conversations/{conversation_id}/memories', response_model=Provider)
def provider(conversation_id: Identifier, response: Response, uid: str = Depends(require_paired_owner)):
    _recording(uid, conversation_id)
    response.headers['Cache-Control'] = 'no-store'
    try:
        return Provider.model_validate_json(library_request('memory-proposals', None, timeout=6, size_limit=4096))
    except (ValidationError, HTTPException):
        return {'provider': None}


@router.post('/v1/local/conversations/{conversation_id}/memories')
def extract(conversation_id: Identifier, body: Extract, response: Response, uid: str = Depends(require_paired_owner)):
    response.headers['Cache-Control'] = 'no-store'
    expected = memories.fingerprint([conversation_id, body.provider_binding])
    try:
        replay = memories.receipt(uid, body.request_id, expected)
        if replay is not None:
            return replay
        version, recording = _recording(uid, conversation_id)
        segments = recording.get('transcript_segments') or []
        rows = [row for row in segments if isinstance(row, dict) and isinstance(row.get('id'), str)]
        counts = Counter(row['id'] for row in rows)
        unique = {row['id']: row for row in rows if 0 < len(row['id']) <= 256 and counts[row['id']] == 1}
        sources, limited = select_sources(list(unique.values()), '')
        if not sources:
            raise HTTPException(422, 'local_memory_no_sources')
        raw = library_request('memory-proposals', {'binding': body.provider_binding,
                              'sources': [source['text'] for source in sources]}, timeout=72, size_limit=32 * 1024)
        result = Proposals.model_validate_json(raw)
        proposals = {}
        for item in result.proposals:
            if item.source > len(sources) or item.quote not in sources[item.source - 1]['text']:
                raise ValueError('Unsupported quotation')
            source = sources[item.source - 1]
            segment = unique[source['segment_id']]
            digest = hashlib.sha256(segment['text'].encode()).hexdigest()
            identifier = str(uuid5(NAMESPACE_URL, memories.fingerprint([
                uid, conversation_id, segment['id'], digest, item.content, item.quote,
            ])))
            evidence = MemoryEvidence(evidence_id=identifier, source_type='conversation',
                conversation_id=conversation_id, source_id=conversation_id, source_version=source_revision(version),
                content_hash=digest, artifact_preservation='not_applicable',
                quote_refs=[{'segment_id': segment['id'], 'quote': item.quote, 'start_ms': source['start_ms']}])
            proposals[identifier] = {'id': identifier, 'content': item.content,
                                     'evidence': evidence.model_dump(mode='json')}
        return memories.publish(uid, conversation_id, version, list(proposals.values()), body.request_id,
                                expected, limited or len(unique) != len(segments))
    except memories.MemoryConflict:
        raise HTTPException(409, 'local_memory_changed') from None
    except (ValidationError, ValueError, KeyError, TypeError):
        raise HTTPException(502, 'local_memory_invalid_proposals') from None


@router.get('/v1/local/memories')
def list_memories(response: Response, state: Literal['proposed', 'accepted', 'rejected'] = 'accepted',
                  source_id: str | None = Query(default=None, pattern=_UUID),
                  query: str = Query(default='', max_length=160),
                  after: str | None = Query(default=None, pattern=_UUID), uid: str = Depends(require_paired_owner)):
    response.headers['Cache-Control'] = 'no-store'
    return memories.list_page(uid, state=state, source_id=source_id, query=query.strip(), after=after)


@router.post('/v1/local/memories/{memory_id}')
def review(memory_id: Identifier, body: Review, response: Response, uid: str = Depends(require_paired_owner)):
    if body.content is not None and body.action not in {'accept', 'edit'}:
        raise HTTPException(422, 'local_memory_invalid_review')
    response.headers['Cache-Control'] = 'no-store'
    try:
        return memories.mutate(uid, memory_id, body.request_id, body.revision, body.action, body.content)
    except memories.MemoryUnavailable:
        raise HTTPException(404, 'local_memory_unavailable') from None
    except memories.MemoryConflict:
        raise HTTPException(409, 'local_memory_changed') from None
