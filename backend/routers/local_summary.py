"""Owner-scoped summary generation from the latest saved transcript."""

import hashlib
import json
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, Field, ValidationError

from database import local_summary as summaries
from models.conversation_enums import CategoryEnum
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


class SummaryProvenance(BaseModel):
    model: str | None = None
    template_name: str | None = None


class SummaryOptions(Options):
    source_revision: str
    published: SummaryProvenance | None = None


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


class SummaryJobProgress(BaseModel):
    phase: Literal['waiting', 'reading', 'sections', 'combining', 'saving']
    completed: int | None = Field(default=None, ge=0)
    total: int | None = Field(default=None, gt=0)


class SummaryJob(BaseModel):
    request_id: str = Field(pattern=_UUID)
    state: Literal['queued', 'ready', 'failed', 'missing']
    model: str | None = None
    template_name: str | None = None
    error: str | None = None
    progress: SummaryJobProgress | None = None


class QueuedSummaryOptions(SummaryOptions):
    job: SummaryJob | None = None


class Candidate(BaseModel):
    category: str | None = None
    emoji: str | None = None
    title: str = Field(min_length=1, max_length=300)
    overview: str = Field(min_length=1, max_length=4000)
    sections: list[dict] | None = Field(default=None, max_length=5)
    model: str = Field(min_length=1, max_length=300)
    template_name: str = Field(min_length=1, max_length=100)


class CategoryOptions(BaseModel):
    provider: ChatProvider | None


class ClassifyCategories(BaseModel):
    recording_ids: list[Annotated[str, Field(pattern=_UUID)]] = Field(min_length=1, max_length=8)
    provider_binding: str = Field(pattern=_DIGEST)


class ClassifiedCategory(BaseModel):
    number: Annotated[int, Field(strict=True, ge=1, le=8)]
    category: CategoryEnum


class CategoryModelResult(BaseModel):
    items: list[ClassifiedCategory] = Field(max_length=8)


class CategoryUpdate(BaseModel):
    id: str
    state: Literal['updated', 'already_classified', 'unavailable', 'unclassified', 'changed']


def _category_request(body=None):
    return library_request('classify-categories', body, timeout=72, size_limit=16 * 1024,
                           error_prefix='local_category')


@router.get('/v1/local/conversations/classify-categories', response_model=CategoryOptions)
def category_options(response: Response, _uid: str = Depends(require_paired_owner)):
    response.headers['Cache-Control'] = 'no-store'
    try:
        return CategoryOptions.model_validate_json(_category_request())
    except ValidationError:
        raise HTTPException(503, 'local_category_provider_unavailable') from None


@router.post('/v1/local/conversations/classify-categories', response_model=list[CategoryUpdate])
def classify_categories(batch: ClassifyCategories, response: Response, uid: str = Depends(require_paired_owner)):
    response.headers['Cache-Control'] = 'no-store'
    if len(set(batch.recording_ids)) != len(batch.recording_ids):
        raise HTTPException(400, 'local_category_duplicate_recordings')
    states, pending = {}, []
    for identifier in batch.recording_ids:
        state, excerpt, revision = summaries.category_input(uid, identifier)
        states[identifier] = state
        if state == 'pending':
            pending.append((identifier, excerpt, revision))
    if pending:
        excerpts = [{'number': i, 'text': text} for i, (_, text, _) in enumerate(pending, 1)]
        try:
            result = CategoryModelResult.model_validate_json(_category_request({
                'binding': batch.provider_binding, 'excerpts': excerpts,
            }))
            labels = {item.number: item.category for item in result.items}
            if len(result.items) != len(pending) or labels.keys() != set(range(1, len(pending) + 1)):
                raise ValueError()
        except ValueError:
            raise HTTPException(502, 'local_category_invalid_result') from None
        for i, (identifier, _, revision) in enumerate(pending, 1):
            states[identifier] = summaries.publish_category(uid, identifier, revision, labels[i])
    return [{'id': identifier, 'state': state} for identifier, state in states.items()]


def _request(body=None):
    return library_request('regenerate-summary', body, timeout=215, size_limit=1024 * 1024)


def _source(raw, uid, *, background=False):
    source = summaries.source(raw, uid, background=background)
    if not source.transcript:
        raise HTTPException(422, 'local_summary_transcript_unavailable')
    return source


@router.get('/v1/local/conversations/{conversation_id}/regenerate-summary', response_model=SummaryOptions)
def options(conversation_id: RecordingId, response: Response, uid: str = Depends(require_paired_owner)):
    return _options(conversation_id, response, uid)


def _options(conversation_id, response, uid, *, background=False):
    try:
        raw = summaries.recording(uid, conversation_id)
        revision = _source(raw, uid, background=background).revision
    except summaries.SummaryUnavailable:
        raise HTTPException(404, 'local_summary_recording_unavailable') from None
    except summaries.SummaryTooLarge:
        raise HTTPException(413, 'local_summary_transcript_too_large') from None
    try:
        options = Options.model_validate_json(_request())
    except ValidationError:
        raise HTTPException(503, 'local_summary_options_unavailable') from None
    response.headers['Cache-Control'] = 'no-store'
    return {**options.model_dump(), 'source_revision': revision, 'published': summaries.published_provenance(raw)}


@router.get('/v1/local/conversations/{conversation_id}/summary-jobs', response_model=QueuedSummaryOptions | SummaryJob)
def jobs(conversation_id: RecordingId, response: Response,
         request_id: Annotated[str | None, Query(pattern=_UUID)] = None, uid: str = Depends(require_paired_owner)):
    if request_id is None:
        options = _options(conversation_id, response, uid, background=True)
        try:
            latest = json.loads(_job_request('summary-job-status', conversation_id, uid, {}))
            return QueuedSummaryOptions.model_validate({**options, 'job': latest['job']})
        except (ValueError, KeyError, TypeError):
            raise HTTPException(503, 'local_summary_job_unavailable') from None
    response.headers['Cache-Control'] = 'no-store'
    job = _job('summary-job-status', conversation_id, uid, {'request_id': request_id})
    if job.state == 'missing':
        raise HTTPException(404, 'local_summary_request_unavailable')
    return job


def _job(operation, conversation_id, uid, body):
    try:
        return SummaryJob.model_validate_json(_job_request(operation, conversation_id, uid, body))
    except ValidationError:
        raise HTTPException(503, 'local_summary_job_unavailable') from None


def _job_request(operation, conversation_id, uid, body):
    try:
        summaries.recording(uid, conversation_id)
    except summaries.SummaryUnavailable:
        raise HTTPException(404, 'local_summary_recording_unavailable') from None
    payload = {**body, 'scope': summaries.owner_scope(uid), 'recording_id': conversation_id}
    return library_request(operation, payload, timeout=8, size_limit=32 * 1024)


@router.post('/v1/local/conversations/{conversation_id}/summary-jobs', response_model=SummaryJob)
def queue_summary(conversation_id: RecordingId, body: Regenerate, response: Response,
                  uid: str = Depends(require_paired_owner)):
    response.headers['Cache-Control'] = 'no-store'
    return _job('summary-job', conversation_id, uid, body.model_dump())


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
