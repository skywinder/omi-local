"""Read and publish paired daily recaps in the existing daily summary collection."""

import hashlib
import json
from dataclasses import dataclass
from datetime import datetime, timezone

from google.cloud import firestore
from google.cloud.firestore_v1.base_query import FieldFilter

from database import conversations, daily_summaries
from database._client import db, run_transactional
from utils.conversations.local_chat import select_sources


_SCAN_LIMIT = 128
_SOURCE_LIMIT = 40
_FIELDS = [
    'created_at', 'started_at', 'finished_at', 'discarded', 'deleted', 'is_locked', 'local_chat_deleting', 'status',
    'structured', 'user_title', 'data_protection_level', 'transcript_segments', 'transcript_segments_compressed',
    'external_data.local_transcript.segment_preview',
]


class DayChanged(ValueError):
    pass


@dataclass(frozen=True)
class Day:
    date: str
    start: datetime
    end: datetime

    @property
    def id(self):
        return 'local-' + self.date


@dataclass
class Context:
    revision: str
    sources: list[dict]
    source_ids: list[str]
    count: int
    minutes: int
    limited: bool


def _owner(uid):
    return db.collection('users').document(uid)


def _recap(uid, day):
    return _owner(uid).collection(daily_summaries.DAILY_SUMMARIES_COLLECTION).document(day.id)


def _documents(uid, day, transaction=None):
    collection = _owner(uid).collection(conversations.conversations_collection)
    rows, limited = {}, False
    for field in ('started_at', 'created_at'):
        matches = list(collection.where(filter=FieldFilter(field, '>=', day.start)).where(
            filter=FieldFilter(field, '<', day.end),
        ).order_by(field).select(_FIELDS).limit(_SCAN_LIMIT + 1).stream(
            transaction=transaction, retry=None, timeout=8,
        ))
        limited |= len(matches) > _SCAN_LIMIT
        for doc in matches[:_SCAN_LIMIT]:
            row = doc.to_dict()
            if not row or any(row.get(flag) for flag in ('deleted', 'discarded', 'is_locked', 'local_chat_deleting')):
                continue
            if row.get('status') not in {None, 'completed'}:
                continue
            started = row.get('started_at') or row.get('created_at')
            if isinstance(started, datetime) and day.start <= started < day.end:
                rows[doc.id] = (row, started, doc.update_time.isoformat())
    return sorted(rows.items(), key=lambda item: (item[1][1], item[0])), limited


def _excerpt(row, structured, uid):
    recap = structured.get('overview')
    if isinstance(recap, str) and recap.strip():
        return recap.strip(), 'recap', False
    decoded = conversations._prepare_conversation_for_read(row, uid) or {}
    excerpts, limited = select_sources(decoded.get('transcript_segments'), '')
    preview = ((row.get('external_data') or {}).get('local_transcript') or {}).get('segment_preview') is True
    return '\n'.join(item['text'] for item in excerpts), 'transcript', limited or preview


def _revision(day, rows, saved, limited):
    previous = (saved or {}).get('local_request_id')
    revisions = [(identifier, version) for identifier, (_, _, version) in rows]
    inputs = [revisions, previous, day.start.isoformat(), day.end.isoformat(), limited]
    return hashlib.sha256(json.dumps(inputs).encode()).hexdigest()


def context(uid, day, saved=None):
    rows, limited = _documents(uid, day)
    revision = _revision(day, rows, saved, limited)
    sources, source_ids, seconds, chars_left = [], [], 0, 9500
    for identifier, (row, started, _) in rows:
        end = row.get('finished_at')
        if isinstance(end, datetime) and end >= started:
            seconds += (end - started).total_seconds()
        if len(sources) >= _SOURCE_LIMIT or chars_left < 250:
            limited = True
            continue
        structured = row.get('structured')
        structured = structured if isinstance(structured, dict) else {}
        text, kind, clipped = _excerpt(row, structured, uid)
        if not text:
            limited = True
            continue
        title = row.get('user_title') or structured.get('title')
        title = title[:140] if isinstance(title, str) else ''
        limit = min(1000, chars_left - len(title))
        limited |= clipped or len(text) > limit
        text = text[:limit]
        chars_left -= len(title) + len(text)
        source_ids.append(identifier)
        sources.append({'source': len(sources) + 1, 'title': title, 'text': text, 'kind': kind})
    return Context(revision, sources, source_ids, len(rows), int(seconds // 60), limited)


def public_summary(row):
    return {key: value for key, value in row.items() if key not in {'local_request_id', 'local_request_fingerprint'}}


def read(uid, day):
    return _recap(uid, day).get(retry=None, timeout=6).to_dict()


def repeated(saved, request_id, fingerprint):
    if not saved or saved.get('local_request_id') != request_id:
        return None
    if saved.get('local_request_fingerprint') != fingerprint:
        raise DayChanged()
    return saved


@firestore.transactional
def _publish(transaction, uid, day, captured, result, request_id, fingerprint, publication_guard=None):
    ref = _recap(uid, day)
    current = ref.get(transaction=transaction, timeout=6).to_dict()
    replay = repeated(current, request_id, fingerprint)
    if replay is not None:
        return replay
    if publication_guard is not None:
        publication_guard(transaction)
        if current is not None:
            raise DayChanged()
    rows, limited = _documents(uid, day, transaction)
    if _revision(day, rows, current, limited) != captured.revision:
        raise DayChanged()
    summary = {
        **result, 'id': day.id, 'date': day.date, 'created_at': datetime.now(timezone.utc),
        'stats': {'total_conversations': captured.count, 'total_duration_minutes': captured.minutes},
        'local_source_ids': captured.source_ids, 'local_coverage_limited': captured.limited,
        'local_request_id': request_id, 'local_request_fingerprint': fingerprint,
    }
    transaction.set(ref, summary)
    return summary


def publish(uid, day, captured, result, request_id, fingerprint, publication_guard=None):
    return run_transactional(db, _publish, uid, day, captured, result, request_id, fingerprint, publication_guard)
