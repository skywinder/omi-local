"""Paired goal writes use canonical goal events without hosted wakeups."""

from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Path, Response
from pydantic import BaseModel, Field, StringConstraints

from database import goals
from models.action_item import EvidenceRef
from models.goal import (
    GoalCreate,
    GoalHistoryEntryResponse,
    GoalMetric,
    GoalProgressEvent,
    GoalProgressEventCreate,
    GoalResponse,
    GoalRelationshipDisposition,
    GoalStatus,
)
from routers.local_recording_chat import _UUID
from utils.goals_response import normalize_goal_history_entry, normalize_goal_response
from utils.local_transport_auth import require_paired_owner

router = APIRouter(prefix='/v1/local/goals', tags=['local'])
GoalId = Annotated[str, Path(pattern=r'^[A-Za-z0-9_-]{1,128}$')]


class Create(BaseModel):
    request_id: str = Field(pattern=_UUID)
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]
    target: float | None = Field(default=None, gt=0, allow_inf_nan=False)
    current: float = Field(default=0, ge=0, allow_inf_nan=False)
    unit: Annotated[str, StringConstraints(strip_whitespace=True, max_length=64)] | None = None


class Progress(BaseModel):
    request_id: str = Field(pattern=_UUID)
    expected_revision: str = Field(min_length=1, max_length=64)
    note: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=1000)]
    metric: GoalMetric | None = None
    conversation_id: str | None = Field(default=None, pattern=_UUID)


class Lifecycle(BaseModel):
    request_id: str = Field(pattern=_UUID)
    expected_revision: str = Field(min_length=1, max_length=64)
    status: Literal['background', 'paused', 'achieved', 'abandoned']


class GoalDetail(BaseModel):
    goal: GoalResponse
    revision: str
    events: list[GoalProgressEvent]
    legacy_history: list[GoalHistoryEntryResponse]


@router.post('', response_model=GoalResponse)
def create(body: Create, response: Response, uid: str = Depends(require_paired_owner)):
    if body.target is None and (body.current != 0 or body.unit):
        raise HTTPException(422, 'local_goal_target_required')
    metric = None if body.target is None else GoalMetric(
        type='numeric', current=body.current, target=body.target, min=0, unit=body.unit or None,
    )
    goal = GoalCreate(title=body.title, metric=metric)
    try:
        result = goals.create_goal_idempotent(
            uid, goal.model_dump(exclude_none=True), idempotency_key=body.request_id,
            account_generation=goals.get_task_workflow_account_generation(uid),
        )
    except goals.GoalConflictError:
        raise HTTPException(409, 'local_goal_conflict') from None
    response.headers['Cache-Control'] = 'no-store'
    return normalize_goal_response(result)


@router.get('/{goal_id}', response_model=GoalDetail)
def detail(goal_id: GoalId, response: Response, uid: str = Depends(require_paired_owner)):
    try:
        goal, revision = goals.get_goal_with_revision(uid, goal_id)
    except goals.GoalNotFoundError:
        raise HTTPException(404, 'local_goal_unavailable') from None
    events = goals.list_goal_progress_events(uid, goal_id, limit=40)
    legacy = goals.get_goal_history(uid, goal_id, days=30)
    event_days = {row.created_at.strftime('%Y-%m-%d') for row in events if row.metric is not None}
    response.headers['Cache-Control'] = 'no-store'
    return {
        'goal': normalize_goal_response(goal),
        'revision': revision,
        'events': events,
        'legacy_history': [normalize_goal_history_entry(row) for row in legacy if row.get('date') not in event_days],
    }


@router.post('/{goal_id}/progress', response_model=GoalProgressEvent)
def progress(goal_id: GoalId, body: Progress, response: Response, uid: str = Depends(require_paired_owner)):
    evidence = [EvidenceRef(id=body.conversation_id, kind='conversation', scope='canonical')] if body.conversation_id else []
    event = GoalProgressEventCreate(
        kind='metric_update' if body.metric is not None else 'evidence', summary=body.note,
        metric=body.metric, evidence_refs=evidence,
    )
    try:
        saved = goals.append_goal_progress_event(
            uid, goal_id, event, idempotency_key=body.request_id,
            account_generation=goals.get_task_workflow_account_generation(uid),
            paired_expected_revision=body.expected_revision,
        )
    except goals.GoalNotFoundError:
        raise HTTPException(404, 'local_goal_unavailable') from None
    except goals.GoalConflictError:
        raise HTTPException(409, 'local_goal_conflict') from None
    except ValueError:
        raise HTTPException(422, 'local_goal_invalid_progress') from None
    response.headers['Cache-Control'] = 'no-store'
    return saved


@router.post('/{goal_id}/lifecycle', response_model=GoalResponse)
def lifecycle(goal_id: GoalId, body: Lifecycle, response: Response, uid: str = Depends(require_paired_owner)):
    try:
        saved = goals.transition_goal_lifecycle(
            uid, goal_id,
            status=GoalStatus(body.status),
            relationship_disposition=GoalRelationshipDisposition.retain,
            idempotency_key=body.request_id,
            account_generation=goals.get_task_workflow_account_generation(uid),
            paired_expected_revision=body.expected_revision,
        )
    except goals.GoalNotFoundError:
        raise HTTPException(404, 'local_goal_unavailable') from None
    except goals.GoalConflictError:
        raise HTTPException(409, 'local_goal_conflict') from None
    response.headers['Cache-Control'] = 'no-store'
    return normalize_goal_response(saved)
