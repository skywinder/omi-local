"""Explicit, paired generation of a daily overview from the saved archive."""

import hashlib
from datetime import date, datetime, time, timedelta, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, Field, StringConstraints, ValidationError

from database import local_daily_recaps as recaps
from routers.local_recording_chat import ChatProvider, _UUID, library_request
from routers.users import DailySummaryResponse
from utils.local_transport_auth import require_paired_owner

router = APIRouter(tags=['local'])
_DIGEST = r'^[a-f0-9]{64}$'
Source = Annotated[int, Field(strict=True, ge=1, le=40)]


class DayInput(BaseModel):
    day: date
    start: datetime
    end: datetime


class Generate(DayInput):
    request_id: str = Field(pattern=_UUID)
    revision: str = Field(pattern=_DIGEST)
    provider_binding: str = Field(pattern=_DIGEST)


class Preview(BaseModel):
    provider: ChatProvider | None
    revision: str
    count: int
    source_count: int
    limited: bool


class Highlight(BaseModel):
    topic: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]
    summary: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]
    sources: list[Source] = Field(min_length=1, max_length=8)


class Decision(BaseModel):
    decision: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=420)]
    source: Source


class Candidate(BaseModel):
    headline: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]
    overview: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2500)]
    highlights: list[Highlight] = Field(default_factory=list, max_length=6)
    decisions: list[Decision] = Field(default_factory=list, max_length=4)


class ProviderOptions(BaseModel):
    provider: ChatProvider | None


def _day(value):
    if value.start.utcoffset() is None or value.end.utcoffset() is None:
        raise HTTPException(422, 'local_recap_invalid_day')
    start, end = (point.astimezone(timezone.utc) for point in (value.start, value.end))
    midnight = datetime.combine(value.day, time.min, tzinfo=timezone.utc)
    if (abs(start - midnight) > timedelta(hours=15)
            or not timedelta(hours=22) <= end - start <= timedelta(hours=26)):
        raise HTTPException(422, 'local_recap_invalid_day')
    return recaps.Day(value.day.isoformat(), start, end)


def _request(body=None):
    return library_request('daily-recap', body, timeout=72 if body else 6, size_limit=64 * 1024)


@router.post('/v1/local/daily-recaps/preview', response_model=Preview)
def preview(body: DayInput, response: Response, uid: str = Depends(require_paired_owner)):
    day = _day(body)
    captured = recaps.context(uid, day, recaps.read(uid, day))
    provider = None
    if captured.sources:
        try:
            provider = ProviderOptions.model_validate_json(_request()).provider
        except (ValidationError, HTTPException):
            pass
    response.headers['Cache-Control'] = 'no-store'
    return {
        'provider': provider, 'revision': captured.revision, 'count': captured.count,
        'source_count': len(captured.sources), 'limited': captured.limited,
    }


@router.post('/v1/local/daily-recaps/generate', response_model=DailySummaryResponse)
def generate(body: Generate, response: Response, uid: str = Depends(require_paired_owner)):
    response.headers['Cache-Control'] = 'no-store'
    return generate_recap(body, uid)


def generate_recap(body: Generate, uid: str, publication_guard=None):
    day = _day(body)
    fingerprint = hashlib.sha256(body.model_dump_json().encode()).hexdigest()
    try:
        saved = recaps.read(uid, day)
        replay = recaps.repeated(saved, body.request_id, fingerprint)
        if replay is not None:
            return recaps.public_summary(replay)
        captured = recaps.context(uid, day, saved)
        if captured.revision != body.revision:
            raise recaps.DayChanged()
        if not captured.sources:
            raise HTTPException(422, 'local_recap_empty_day')
        candidate = Candidate.model_validate_json(_request({
            'binding': body.provider_binding, 'sources': captured.sources,
        }))
        result = {
            'headline': candidate.headline, 'overview': candidate.overview,
            'highlights': [
                {'topic': item.topic, 'summary': item.summary,
                 'conversation_ids': [captured.source_ids[n - 1] for n in dict.fromkeys(item.sources)]}
                for item in candidate.highlights
            ],
            'decisions_made': [
                {'decision': item.decision, 'conversation_id': captured.source_ids[item.source - 1]}
                for item in candidate.decisions
            ],
        }
        return recaps.public_summary(recaps.publish(
            uid, day, captured, result, body.request_id, fingerprint, publication_guard,
        ))
    except recaps.DayChanged:
        raise HTTPException(409, 'local_recap_source_changed') from None
    except (ValidationError, IndexError):
        raise HTTPException(502, 'local_recap_invalid_result') from None


class ScheduleInput(BaseModel):
    request_id: str = Field(pattern=_UUID)
    revision: str = Field(max_length=36)
    enabled: bool = Field(strict=True)
    timezone: str = Field(min_length=1, max_length=100)
    hour: int = Field(strict=True, ge=0, le=23)
    minute: int = Field(strict=True, ge=0, le=59)
    provider_binding: str = Field(default='', max_length=64)


def _schedule_view(uid):
    from database import local_recap_schedule as schedule
    provider = None
    try:
        provider = ProviderOptions.model_validate_json(_request()).provider
    except (ValidationError, HTTPException):
        pass
    return {**schedule.public(schedule.read(uid)), 'provider': provider}


@router.get('/v1/local/daily-recaps/schedule')
def get_schedule(response: Response, uid: str = Depends(require_paired_owner)):
    response.headers['Cache-Control'] = 'no-store'
    return _schedule_view(uid)


@router.post('/v1/local/daily-recaps/schedule')
def set_schedule(body: ScheduleInput, response: Response, uid: str = Depends(require_paired_owner)):
    from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
    from database import local_recap_schedule as schedule
    try:
        ZoneInfo(body.timezone)
    except (ZoneInfoNotFoundError, ValueError):
        raise HTTPException(422, 'local_recap_invalid_timezone') from None
    provider = None
    if body.enabled:
        try:
            provider = ProviderOptions.model_validate_json(_request()).provider
        except ValidationError:
            raise HTTPException(502, 'local_recap_invalid_provider') from None
        if provider is None or provider.binding != body.provider_binding:
            raise HTTPException(409, 'local_recap_provider_changed')
    if not body.enabled:
        try:
            provider = ProviderOptions.model_validate_json(_request()).provider
        except (ValidationError, HTTPException):
            pass
    data = {**body.model_dump(), 'model': provider.model if provider else None,
            'host': provider.host if provider else None}
    try:
        row = schedule.configure(uid, data)
    except recaps.DayChanged:
        raise HTTPException(409, 'local_recap_schedule_changed') from None
    response.headers['Cache-Control'] = 'no-store'
    return {**schedule.public(row), 'provider': provider}
