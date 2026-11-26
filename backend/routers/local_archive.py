"""Bounded canonical archive reads for scoped assistant access, with revisioned quotes."""
import math
import re
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, Field

from database import conversations, local_recording_chat as archive
from utils.conversations.semantic_passages import source_revision
from utils.local_transport_auth import require_paired_owner

router = APIRouter(tags=['local'])
_UUID = r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$'


class Read(BaseModel):
    id: str = Field(pattern=_UUID)
    revision: str | None = Field(default=None, min_length=1, max_length=100)
    segment_id: str | None = Field(default=None, min_length=1, max_length=256)
    start_segment: int = Field(default=0, strict=True, ge=0)
    start_character: int = Field(default=0, strict=True, ge=0)
    limit: int = Field(default=10, strict=True, ge=1, le=30)


def _cursor(value):
    if value is not None and (value in {'.', '..'} or '/' in value or '\x00' in value):
        raise HTTPException(422, 'local_archive_invalid_cursor')
    return value


@router.get('/v1/local/archive/recordings')
def recordings(response: Response, after: Annotated[str | None, Query(max_length=1500)] = None,
               uid: str = Depends(require_paired_owner)):
    rows, cursor = conversations.read_local_search_page(uid, _cursor(after), limit=20)
    items = []
    for row in rows:
        if not re.fullmatch(_UUID, row['id']):
            continue
        structured = row.get('structured')
        structured = structured if isinstance(structured, dict) else {}
        items.append({'id': row['id'], 'title': str(row.get('user_title') or structured.get('title') or '')[:240],
                      'started_at': row.get('started_at') or row.get('created_at'),
                      'revision': source_revision(row['_local_read_version'])})
    response.headers['Cache-Control'] = 'no-store'
    return {'items': items, 'next_cursor': cursor}


def _seconds(value):
    return value if type(value) in {int, float} and math.isfinite(value) and value >= 0 else None


@router.post('/v1/local/archive/read')
def read(body: Read, response: Response, uid: str = Depends(require_paired_owner)):
    try:
        version, row = archive.recording(uid, body.id)
    except archive.RecordingUnavailable:
        raise HTTPException(404, 'local_archive_source_unavailable') from None
    revision = source_revision(version)
    if body.revision is not None and body.revision != revision:
        raise HTTPException(409, 'local_archive_source_changed')
    if (body.start_segment or body.start_character) and body.revision is None:
        raise HTTPException(422, 'local_archive_revision_required')
    segments = row.get('transcript_segments') or []
    start = body.start_segment
    if body.segment_id is not None:
        matches = [i for i, segment in enumerate(segments)
                   if isinstance(segment, dict) and segment.get('id') == body.segment_id]
        if len(matches) != 1:
            raise HTTPException(404, 'local_archive_segment_unavailable')
        start = matches[0]
    if start > len(segments) or (start == len(segments) and body.start_character):
        raise HTTPException(422, 'local_archive_invalid_cursor')
    citations, cursor, remaining = [], None, 12_000
    for index in range(start, len(segments)):
        segment = segments[index]
        if not isinstance(segment, dict) or not isinstance(segment.get('text'), str):
            continue
        text = segment['text']
        offset = body.start_character if index == start else 0
        if offset > len(text):
            raise HTTPException(422, 'local_archive_invalid_cursor')
        excerpt = text[offset:offset + min(1200, remaining)]
        citations.append({'conversation_id': body.id, 'segment_id': segment.get('id'),
                          'start_seconds': _seconds(segment.get('start')), 'end_seconds': _seconds(segment.get('end')),
                          'character_offset': offset, 'text': excerpt, 'revision': revision})
        remaining -= len(excerpt)
        if offset + len(excerpt) < len(text):
            cursor = {'start_segment': index, 'start_character': offset + len(excerpt), 'revision': revision}
            break
        if len(citations) >= body.limit or remaining == 0 or body.segment_id is not None:
            if body.segment_id is None and index + 1 < len(segments):
                cursor = {'start_segment': index + 1, 'start_character': 0, 'revision': revision}
            break
    structured = row.get('structured')
    structured = structured if isinstance(structured, dict) else {}
    summary = str(structured.get('overview') or '')
    response.headers['Cache-Control'] = 'no-store'
    return {'id': body.id, 'revision': revision, 'title': str(row.get('user_title') or structured.get('title') or '')[:240],
            'started_at': row.get('started_at') or row.get('created_at'), 'summary': summary[:4000],
            'summary_limited': len(summary) > 4000, 'citations': citations, 'next': cursor}
