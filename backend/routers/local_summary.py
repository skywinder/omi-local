"""Owner-scoped summary generation from the latest saved transcript."""

import hashlib
import json

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, Field, ValidationError

from database import local_summary as summaries
from routers.local_recording_chat import ChatProvider, RecordingId, _UUID, library_request
from utils.local_transport_auth import require_paired_owner

router = APIRouter(tags=['local'])
_DIGEST = r'^[a-f0-9]{64}$'
_TEMPLATE = r'^[A-Za-z0-9_-]{1,64}$'


class SummaryProvider(ChatProvider):
    name: str = Field(min_length=1, max_length=100)


class SummaryTemplate(BaseModel):
    id: str = Field(pattern=_TEMPLATE)
    name: str = Field(min_length=1, max_length=100)
    prompt: str = Field(min_length=1, max_length=8000)
    digest: str = Field(pattern=_DIGEST)


class Options(BaseModel):
    providers: list[SummaryProvider]
    templates: list[SummaryTemplate]
    default_provider_binding: str | None
    default_template_id: str


class SummaryOptions(Options):
    source_revision: str


class Regenerate(BaseModel):
    request_id: str = Field(pattern=_UUID)
    source_revision: str = Field(pattern=_DIGEST)
    provider_binding: str = Field(pattern=_DIGEST)
    template_id: str = Field(pattern=_TEMPLATE)
    template_digest: str = Field(pattern=_DIGEST)
    prompt: str = Field(min_length=1, max_length=8000)


class Regenerated(BaseModel):
    request_id: str
    model: str
    template_name: str


class Candidate(BaseModel):
    category: str | None = None
    emoji: str | None = None
    title: str = Field(min_length=1, max_length=300)
    overview: str = Field(min_length=1, max_length=4000)
    sections: list[dict] | None = Field(default=None, max_length=5)
    model: str = Field(min_length=1, max_length=300)
    template_name: str = Field(min_length=1, max_length=100)


def _request(body=None):
    return library_request('regenerate-summary', body, timeout=215, size_limit=1024 * 1024)


def _source(raw, uid):
    source = summaries.source(raw, uid)
    if not source.transcript:
        raise HTTPException(422, 'local_summary_transcript_unavailable')
    return source


@router.get('/v1/local/conversations/{conversation_id}/regenerate-summary', response_model=SummaryOptions)
def options(conversation_id: RecordingId, response: Response, uid: str = Depends(require_paired_owner)):
    try:
        revision = _source(summaries.recording(uid, conversation_id), uid).revision
    except summaries.SummaryUnavailable:
        raise HTTPException(404, 'local_summary_recording_unavailable') from None
    except summaries.SummaryTooLarge:
        raise HTTPException(413, 'local_summary_transcript_too_large') from None
    try:
        options = Options.model_validate_json(_request())
    except ValidationError:
        raise HTTPException(503, 'local_summary_options_unavailable') from None
    response.headers['Cache-Control'] = 'no-store'
    return {**options.model_dump(), 'source_revision': revision}


@router.post('/v1/local/conversations/{conversation_id}/regenerate-summary', response_model=Regenerated)
def regenerate(conversation_id: RecordingId, body: Regenerate, response: Response, uid: str = Depends(require_paired_owner)):
    supplied = body.model_dump(exclude={'request_id', 'source_revision'})
    fingerprint = hashlib.sha256(body.model_dump_json().encode()).hexdigest()
    response.headers['Cache-Control'] = 'no-store'
    try:
        raw = summaries.recording(uid, conversation_id)
        previous = summaries.replay(raw, body.request_id, fingerprint)
        if previous is not None:
            return previous
        source = _source(raw, uid)
        if source.revision != body.source_revision:
            raise summaries.SummaryChanged()
        generated = Candidate.model_validate_json(_request({
            **supplied, 'transcript': source.transcript, 'numbered_sources': True,
        }))
        if not generated.title.strip() or not generated.overview.strip():
            raise ValueError()
        publication = {
            'request_id': body.request_id, 'fingerprint': fingerprint, 'model': generated.model,
            'template_name': generated.template_name,
        }
        return summaries.publish(uid, conversation_id, source.revision, generated.model_dump(), publication)
    except summaries.SummaryUnavailable:
        raise HTTPException(404, 'local_summary_recording_unavailable') from None
    except summaries.SummaryTooLarge:
        raise HTTPException(413, 'local_summary_transcript_too_large') from None
    except summaries.SummaryChanged:
        raise HTTPException(409, 'local_summary_recording_changed') from None
    except (ValidationError, ValueError):
        raise HTTPException(502, 'local_summary_invalid_result') from None
