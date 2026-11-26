"""The loopback library projects note metadata from the paired archive owner."""

import asyncio
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field, StrictBool, model_validator

from database import _client, conversations
from models.conversation_enums import CategoryEnum
from routers.listen.local_status import require_local_preview
from utils.local_transcript import summary_labels
from utils.local_transport_auth import require_paired_owner

router = APIRouter()
_LIMIT = 16 * 1024
_FIELDS = ('starred', 'archived', 'is_locked', 'deleted', 'status', 'local_chat_deleting', 'user_category',
           'structured.category', 'structured.emoji', 'external_data.local_transcript.result_key')


class CategoryChange(BaseModel):
    model_config = ConfigDict(extra='forbid')
    expected: CategoryEnum
    value: CategoryEnum


class NoteRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    keys: list[Annotated[str, Field(pattern=r'^[0-9a-f]{64}$')]] = Field(min_length=1, max_length=200)
    change: dict[str, StrictBool | CategoryChange] | None = None

    @model_validator(mode='after')
    def one_change(self):
        if self.change is not None:
            if len(self.keys) != 1 or len(self.change) != 1:
                raise ValueError('A change requires one recording and one field')
            field, value = next(iter(self.change.items()))
            if not ((field == 'category' and isinstance(value, CategoryChange))
                    or (field in {'starred', 'archived'} and isinstance(value, bool))):
                raise ValueError('Invalid note field')
        return self


async def read_request(request: Request) -> NoteRequest:
    try:
        length = int(request.headers.get('content-length', '0'))
        if (not 0 < length <= _LIMIT or request.headers.get('transfer-encoding')
                or request.headers.get('content-type', '').split(';')[0].strip() != 'application/json'):
            raise ValueError()
        body = bytearray()
        async with asyncio.timeout(10):
            async for chunk in request.stream():
                body.extend(chunk)
                if len(body) > length:
                    raise ValueError()
        if len(body) != length:
            raise ValueError()
        return NoteRequest.model_validate_json(body)
    except (TimeoutError, ValueError) as error:
        raise HTTPException(400, 'Invalid note states request') from error


def note_state(row, key, card=None):
    if (not row or row.get('is_locked') or row.get('local_chat_deleting') or conversations.is_soft_deleted(row)
            or row.get('status') not in {None, 'completed'}
            or ((row.get('external_data') or {}).get('local_transcript') or {}).get('result_key') != key):
        return None
    summary = row.get('structured')
    labels = summary_labels(summary if isinstance(summary, dict) else {})
    manual = row.get('user_category')
    category = manual if isinstance(manual, str) and manual in CategoryEnum._value2member_map_ else labels.get('category', 'other')
    result = {**labels, 'category': category, 'starred': row.get('starred') is True, 'archived': row.get('archived') is True}
    if card:
        structured = summary if isinstance(summary, dict) else {}
        title = row.get('user_title')
        if not isinstance(title, str):
            title = structured.get('title')
        values = {}
        if isinstance(title, str) and len(title) <= 500:
            values['title'] = title
        overview = structured.get('overview')
        if card == 'detail' and isinstance(overview, str) and len(overview) <= 20000:
            values['overview'] = overview
            publication = row.get('local_summary_publication')
            model = publication.get('model') if isinstance(publication, dict) else None
            if isinstance(model, str) and 0 < len(model) <= 300:
                values['model'] = model
        if values:
            result['card'] = values
    return result


def conversation_id(key):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + key))


@router.post('/v1/local/library/note-states', dependencies=[Depends(require_local_preview)])
def local_library_note_states(response: Response, uid: str = Depends(require_paired_owner),
                              request: NoteRequest = Depends(read_request),
                             card: Annotated[str | None, Header(alias='X-Omiloc-Card')] = None):
    response.headers['Cache-Control'] = 'no-store'
    if request.change is not None:
        key = request.keys[0]
        field, change = next(iter(request.change.items()))
        expected, value = (change.expected, change.value) if isinstance(change, CategoryChange) else (None, change)
        status, row = conversations.patch_local_recording(uid, conversation_id(key), field, expected, value, result_key=key)
        if status == 'conflict':
            raise HTTPException(409, 'Category changed')
        result = note_state(row, key) if status == 'ok' else None
        if result is None:
            raise HTTPException(404, 'Note unavailable')
        return {key: result}

    if card not in {None, 'titles', 'detail'} or (card == 'detail' and len(request.keys) != 1):
        raise HTTPException(400, 'Invalid recording projection')
    fields = _FIELDS
    if card:
        fields += ('user_title', 'structured.title')
    if card == 'detail':
        fields += ('structured.overview', 'local_summary_publication.model')
    keys = {conversation_id(key): key for key in request.keys}
    client = _client.get_firestore_client()
    collection = client.collection('users').document(uid).collection('conversations')
    records = client.get_all([collection.document(cid) for cid in keys], field_paths=fields, retry=None, timeout=8)
    result = {}
    for doc in records:
        if doc is not None and doc.exists and (key := keys.get(doc.id)):
            if (state := note_state(doc.to_dict(), key, card)) is not None:
                result[key] = state
    return result
