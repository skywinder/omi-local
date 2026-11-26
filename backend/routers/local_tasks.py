"""Paired tasks use the canonical store and local recording provenance."""

import hashlib
import json
import math
import uuid
from collections import Counter
from datetime import datetime, timedelta, timezone
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Path, Response
from pydantic import AwareDatetime, BaseModel, Field, ValidationError, model_validator

from database import action_items, local_recording_chat
from models.action_item import ActionItemCreateRequest, ActionItemResponse, EvidenceRef
from models.task_due import TaskDue
from routers.local_recording_chat import ChatProvider, _chat_provider, _library_request
from utils.conversations.local_chat import select_sources
from utils.local_transport_auth import require_paired_owner

router = APIRouter(prefix='/v1/local/action-items', tags=['local'])
_UUID = r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$'
TaskId = Annotated[str, Path(pattern=r'^[A-Za-z0-9_-]{1,128}$')]


class LocalTaskCreate(BaseModel):
    request_id: str = Field(pattern=_UUID)
    description: str = Field(min_length=1, max_length=4096)
    conversation_id: str | None = Field(default=None, pattern=_UUID)
    segment_id: str | None = Field(default=None, min_length=1, max_length=256)
    segment_sha256: str | None = Field(default=None, pattern=r'^[a-f0-9]{64}$')

    @model_validator(mode='after')
    def validate_source(self):
        if self.segment_id and not self.conversation_id:
            raise ValueError('A segment requires a recording')
        if self.segment_sha256 and not self.segment_id:
            raise ValueError('A source digest requires a segment')
        return self


class LocalTaskDescription(BaseModel):
    field: Literal['description']
    expected: str = Field(pattern=r'^[a-f0-9]{64}$')
    value: str = Field(min_length=1, max_length=4096)


class LocalTaskCompletion(BaseModel):
    field: Literal['completed']
    expected: bool = Field(strict=True)
    value: bool = Field(strict=True)


class LocalTaskDue(BaseModel):
    field: Literal['due']
    expected: TaskDue | None
    value: TaskDue | None

    @model_validator(mode='after')
    def validate_edit(self):
        if self.value and self.value.kind not in {'date', 'instant'}:
            raise ValueError('Choose a date, a time, or remove the reminder')
        return self


class LocalTaskReminder(BaseModel):
    id: str
    description: str
    notify_at: AwareDatetime
    exact_time: bool


def _description(value: str) -> str:
    if not value.strip():
        raise HTTPException(400, 'local_task_empty_description')
    return value.strip()


def _task(uid, task_id):
    row = action_items.get_action_item(uid, task_id)
    if not row or row.get('is_locked') or row.get('deleted') or row.get('status') not in {'active', 'completed'}:
        raise HTTPException(404, 'local_task_unavailable')
    return row


def _evidence(uid, body):
    try:
        version, recording = local_recording_chat.recording(uid, body.conversation_id)
    except local_recording_chat.RecordingUnavailable:
        raise HTTPException(404, 'local_task_source_unavailable') from None
    fields = {'kind': 'conversation', 'scope': 'canonical', 'id': body.conversation_id}
    if body.segment_id is not None:
        segments = recording.get('transcript_segments')
        matches = [
            line for line in segments if isinstance(line, dict) and line.get('id') == body.segment_id
        ] if isinstance(segments, list) else []
        if len(matches) != 1:
            raise HTTPException(409, 'local_task_source_changed')
        if body.segment_sha256 is not None:
            text = matches[0].get('text')
            if not isinstance(text, str) or hashlib.sha256(text.encode()).hexdigest() != body.segment_sha256:
                raise HTTPException(409, 'local_task_source_changed')
        start, end = matches[0].get('start'), matches[0].get('end')
        fields['transcript_segment_ids'] = [body.segment_id]
        if isinstance(start, (int, float)) and math.isfinite(start) and start >= 0:
            fields['start_seconds'] = start
            if isinstance(end, (int, float)) and math.isfinite(end) and end >= start:
                fields['end_seconds'] = end
    return version, EvidenceRef.model_validate(fields)


@router.post('', response_model=ActionItemResponse)
def create_task(body: LocalTaskCreate, response: Response, uid: str = Depends(require_paired_owner)):
    description = _description(body.description)
    inputs = [description, body.conversation_id, body.segment_id]
    if body.segment_sha256 is not None:
        inputs.append(body.segment_sha256)
    fingerprint = hashlib.sha256(json.dumps(inputs, ensure_ascii=False).encode()).hexdigest()
    revision, provenance = None, []
    if body.conversation_id is not None:
        # Fast replay does not require a recording that was deleted after the first write.
        existing = action_items.get_action_item(uid, body.request_id)
        if not existing or existing.get('local_request_fingerprint') != fingerprint:
            version, source = _evidence(uid, body)
            revision = body.conversation_id, version
            provenance = [source]
    payload = ActionItemCreateRequest(
        description=description, conversation_id=body.conversation_id, provenance=provenance,
    ).storage_payload()
    try:
        task_id = action_items.create_action_item(
            uid, payload, document_id=body.request_id, local_source_revision=revision,
            local_request_fingerprint=fingerprint,
        )
    except action_items.TaskRelationshipConflictError:
        raise HTTPException(409, 'local_task_conflict') from None
    response.headers['Cache-Control'] = 'no-store'
    return _task(uid, task_id)


@router.get('/{task_id}', response_model=ActionItemResponse)
def read_task(task_id: TaskId, response: Response, uid: str = Depends(require_paired_owner)):
    response.headers['Cache-Control'] = 'no-store'
    return _task(uid, task_id)


@router.get('/reminders/schedule', response_model=list[LocalTaskReminder])
def task_reminder_schedule(response: Response, uid: str = Depends(require_paired_owner)):
    # A recent alarm can still be pending on Android when precise alarms are unavailable.
    since = datetime.now(timezone.utc) - timedelta(hours=1)
    items = []
    for count, snapshot in enumerate(action_items.local_task_reminder_rows(uid, since), start=1):
        if count > 2000:
            raise HTTPException(503, 'local_task_reminders_incomplete')
        row = snapshot.to_dict()
        if (
            not row
            or row.get('deleted')
            or row.get('is_locked')
            or row.get('completed')
            or row.get('status', 'active') != 'active'
        ):
            continue
        try:
            due = TaskDue.model_validate(row.get('due'))
        except ValidationError:
            continue
        notify_at = due.reminder_at()
        description = row.get('description')
        if notify_at is not None and notify_at >= since and isinstance(description, str) and description.strip():
            items.append(
                LocalTaskReminder(
                    id=snapshot.id, description=description[:200], notify_at=notify_at, exact_time=due.kind == 'instant'
                )
            )
    response.headers['Cache-Control'] = 'no-store'
    now = datetime.now(timezone.utc)
    future = sorted((item for item in items if item.notify_at >= now), key=lambda item: (item.notify_at, item.id))[:48]
    recent = sorted((item for item in items if item.notify_at < now), key=lambda item: (item.notify_at, item.id))[-48:]
    return future + recent


@router.patch('/{task_id}', response_model=ActionItemResponse)
def edit_task(
    task_id: TaskId,
    edit: Annotated[LocalTaskDescription | LocalTaskCompletion | LocalTaskDue, Field(discriminator='field')],
    response: Response,
    uid: str = Depends(require_paired_owner),
):
    expected = edit.expected
    if isinstance(edit, LocalTaskDue):
        value = edit.value.model_dump(mode='python', exclude_none=True) if edit.value else None
        expected = edit.expected.model_dump(mode='python', exclude_none=True) if edit.expected else None
    else:
        value = edit.value if isinstance(edit, LocalTaskCompletion) else _description(edit.value)
    status, row = action_items.patch_local_task(uid, task_id, edit.field, expected, value)
    if status == 'not_found':
        raise HTTPException(404, 'local_task_unavailable')
    if status != 'ok':
        raise HTTPException(409, 'local_task_conflict')
    response.headers['Cache-Control'] = 'no-store'
    return row


class SuggestionRequest(BaseModel):
    provider_binding: str = Field(pattern=r'^[a-f0-9]{64}$')


class ProposedTask(BaseModel):
    description: str = Field(min_length=1, max_length=360)
    source: int = Field(strict=True, ge=1, le=120)


class ProviderSuggestions(BaseModel):
    suggestions: list[ProposedTask] = Field(max_length=12)


class TaskSuggestion(BaseModel):
    id: str
    description: str
    segment_id: str
    segment_sha256: str
    excerpt: str
    start_ms: int | None


class TaskSuggestions(BaseModel):
    suggestions: list[TaskSuggestion]
    context_limited: bool


class SuggestionProvider(BaseModel):
    provider: ChatProvider | None


suggestions_router = APIRouter(tags=['local'])
RecordingId = Annotated[str, Path(pattern=_UUID)]


@suggestions_router.get('/v1/local/conversations/{conversation_id}/task-suggestions', response_model=SuggestionProvider)
def task_suggestion_provider(conversation_id: RecordingId, response: Response, uid: str = Depends(require_paired_owner)):
    try:
        local_recording_chat.recording(uid, conversation_id)
    except local_recording_chat.RecordingUnavailable:
        raise HTTPException(404, 'local_task_source_unavailable') from None
    response.headers['Cache-Control'] = 'no-store'
    return {'provider': _chat_provider(suggestions=True)}


@suggestions_router.post('/v1/local/conversations/{conversation_id}/task-suggestions', response_model=TaskSuggestions)
def suggest_tasks(
    conversation_id: RecordingId, body: SuggestionRequest, response: Response, uid: str = Depends(require_paired_owner),
):
    try:
        version, recording = local_recording_chat.recording(uid, conversation_id)
    except local_recording_chat.RecordingUnavailable:
        raise HTTPException(404, 'local_task_source_unavailable') from None
    segments = recording.get('transcript_segments')
    rows = [row for row in segments if isinstance(row, dict)] if isinstance(segments, list) else []
    counts = Counter(row['id'] for row in rows if isinstance(row.get('id'), str))
    unique = {
        row['id']: row for row in rows
        if isinstance(row.get('id'), str) and 0 < len(row['id']) <= 256 and counts[row['id']] == 1
    }
    sources, limited = select_sources(list(unique.values()), '')
    response.headers['Cache-Control'] = 'no-store'
    if not sources:
        return {'suggestions': [], 'context_limited': bool(rows)}
    try:
        result = ProviderSuggestions.model_validate_json(_library_request({
            'binding': body.provider_binding, 'sources': [source['text'] for source in sources],
        }, suggestions=True))
        if any(item.source > len(sources) for item in result.suggestions):
            raise ValueError()
    except (ValidationError, ValueError):
        raise HTTPException(502, 'local_task_invalid_suggestions') from None
    if not local_recording_chat.sources_current(uid, {conversation_id: version}):
        raise HTTPException(409, 'local_task_source_changed')
    suggestions = {}
    for item in result.suggestions:
        description = item.description.strip()
        if not description:
            continue
        source = sources[item.source - 1]
        segment_id = source['segment_id']
        digest = hashlib.sha256(unique[segment_id]['text'].encode()).hexdigest()
        seed = json.dumps([uid, conversation_id, segment_id, digest, description], ensure_ascii=False)
        identifier = str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-task:' + seed))
        suggestions[identifier] = {
            'id': identifier, 'description': description, 'segment_id': segment_id, 'segment_sha256': digest,
            'excerpt': source['text'], 'start_ms': source['start_ms'],
        }
    return {'suggestions': list(suggestions.values()), 'context_limited': limited or len(unique) != len(rows)}
