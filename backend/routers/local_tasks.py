"""Paired tasks use the canonical store and local recording provenance."""

import hashlib
import json
import math
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Path, Response
from pydantic import BaseModel, Field, model_validator

from database import action_items, local_recording_chat
from models.action_item import ActionItemCreateRequest, ActionItemResponse, EvidenceRef
from utils.local_transport_auth import require_paired_owner

router = APIRouter(prefix='/v1/local/action-items', tags=['local'])
_UUID = r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$'
TaskId = Annotated[str, Path(pattern=r'^[A-Za-z0-9_-]{1,128}$')]


class LocalTaskCreate(BaseModel):
    request_id: str = Field(pattern=_UUID)
    description: str = Field(min_length=1, max_length=4096)
    conversation_id: str | None = Field(default=None, pattern=_UUID)
    segment_id: str | None = Field(default=None, min_length=1, max_length=256)

    @model_validator(mode='after')
    def validate_source(self):
        if self.segment_id and not self.conversation_id:
            raise ValueError('A segment requires a recording')
        return self


class LocalTaskDescription(BaseModel):
    field: Literal['description']
    expected: str = Field(pattern=r'^[a-f0-9]{64}$')
    value: str = Field(min_length=1, max_length=4096)


class LocalTaskCompletion(BaseModel):
    field: Literal['completed']
    expected: bool = Field(strict=True)
    value: bool = Field(strict=True)


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
    fingerprint = hashlib.sha256(json.dumps(
        [description, body.conversation_id, body.segment_id], ensure_ascii=False,
    ).encode()).hexdigest()
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


@router.patch('/{task_id}', response_model=ActionItemResponse)
def edit_task(
    task_id: TaskId, edit: Annotated[LocalTaskDescription | LocalTaskCompletion, Field(discriminator='field')],
    response: Response, uid: str = Depends(require_paired_owner),
):
    value = edit.value if isinstance(edit, LocalTaskCompletion) else _description(edit.value)
    status, row = action_items.patch_local_task(uid, task_id, edit.field, edit.expected, value)
    if status == 'not_found':
        raise HTTPException(404, 'local_task_unavailable')
    if status != 'ok':
        raise HTTPException(409, 'local_task_conflict')
    response.headers['Cache-Control'] = 'no-store'
    return row
