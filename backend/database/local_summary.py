"""Optimistic publication of a paired recording summary."""

import hashlib
import json
import math
from collections import Counter
from typing import NamedTuple

from google.cloud import firestore

from database import conversations
from database._client import db, run_transactional
from models.conversation_enums import CategoryEnum
from utils.local_transcript import hydrate_grouped_transcript, local_transcript_root, summary_labels, summary_note_fields

SUMMARY_SHORT_LIMIT = 120_000
SUMMARY_BACKGROUND_LIMIT = 2_000_000


class SummaryUnavailable(ValueError):
    pass


class SummaryChanged(ValueError):
    pass


class SummaryTooLarge(ValueError):
    pass


class SummarySource(NamedTuple):
    transcript: str
    revision: str
    segment_ids: list[tuple[str, ...]]


def owner_scope(uid):
    return hashlib.sha256(uid.encode()).hexdigest()


def _ref(uid, conversation_id):
    return db.collection('users').document(uid).collection(conversations.conversations_collection).document(
        conversation_id,
    )


def _check(raw):
    if (not raw or conversations.is_soft_deleted(raw) or raw.get('is_locked') or raw.get('local_chat_deleting')
            or raw.get('status') not in {None, 'completed'}):
        raise SummaryUnavailable()


def _transcript(raw, uid, *, background=False):
    external = raw.get('external_data') or {}
    row = conversations._prepare_conversation_for_read(raw, uid)
    if (external.get('local_transcript') or {}).get('segment_preview'):
        if not background:
            raise SummaryTooLarge()
        try:
            row = hydrate_grouped_transcript(row, local_transcript_root(), uid)
        except (ValueError, OSError, KeyError, TypeError):
            raise SummaryUnavailable() from None
        if (row['external_data']['local_transcript']).get('segment_preview'):
            raise SummaryUnavailable()
    segments = row.get('transcript_segments')
    if not isinstance(segments, list):
        return '', []
    lines, ids, length = [], [], 0
    for segment in segments:
        if not isinstance(segment, dict):
            continue
        text = segment.get('text')
        if not isinstance(text, str) or not text.strip():
            continue
        start = segment.get('start')
        time = f'[{start:.1f}] ' if type(start) in {int, float} and math.isfinite(start) and start >= 0 else ''
        speaker = segment.get('speaker')
        if not isinstance(speaker, str) or len(speaker) > 60:
            speaker = ''
        prefix = f"{' '.join(speaker.splitlines())}: " if speaker else ''
        content = (prefix + ' '.join(text.splitlines())).replace('[src:', '[source:')
        line = f'[src:{len(lines) + 1}] ' + time + content
        length += len(line) + 1
        if length > (SUMMARY_BACKGROUND_LIMIT if background else SUMMARY_SHORT_LIMIT):
            raise SummaryTooLarge()
        lines.append(line)
        identifier = segment.get('id')
        ids.append(identifier if isinstance(identifier, str) and identifier else None)
    counts = Counter(ids)
    return '\n'.join(lines), [(identifier,) if identifier and counts[identifier] == 1 else () for identifier in ids]


def _revision(raw, transcript, segment_ids):
    structured = raw.get('structured')
    structured = structured if isinstance(structured, dict) else {}
    previous = (raw.get('local_summary_publication') or {}).get('request_id')
    return hashlib.sha256(json.dumps(
        [transcript, segment_ids, structured.get('overview'), structured.get('sections'), previous],
        ensure_ascii=False, sort_keys=True,
    ).encode()).hexdigest()


def recording(uid, conversation_id):
    raw = _ref(uid, conversation_id).get(retry=None, timeout=6).to_dict()
    _check(raw)
    return raw


def needs_backfill(raw):
    try:
        _check(raw)
    except SummaryUnavailable:
        return False
    local = (raw.get('external_data') or {}).get('local_transcript')
    if not isinstance(local, dict) or not local or raw.get('local_summary_publication'):
        return False
    structured = raw.get('structured') or {}
    stage = (local.get('stages') or {}).get('summary') or {}
    return (isinstance(structured, dict) and not structured.get('overview') and not structured.get('sections')
            and stage.get('status') in {None, 'disabled', 'failed'})


def backfill_candidates(uid):
    collection = _ref(uid, 'unused').parent
    fields = ('status', 'deleted', 'is_locked', 'local_chat_deleting', 'local_summary_publication.request_id',
              'structured.overview', 'structured.sections', 'external_data.local_transcript.version',
              'external_data.local_transcript.stages.summary.status')
    return [doc.id for doc in collection.select(fields).stream(retry=None, timeout=30)
            if needs_backfill(doc.to_dict())]


def source(raw, uid, *, background=False) -> SummarySource:
    transcript, segment_ids = _transcript(raw, uid, background=background)
    return SummarySource(transcript, _revision(raw, transcript, segment_ids), segment_ids)


def published_provenance(raw):
    """Describe the saved result, never the current provider or latest attempted job."""
    publication = raw.get('local_summary_publication')
    if not isinstance(publication, dict):
        publication = (((raw.get('external_data') or {}).get('local_transcript') or {}).get('stages') or {}).get('summary')
        if not isinstance(publication, dict) or publication.get('status') != 'ready':
            return None
    result = {key: value for key, limit in (('model', 300), ('template_name', 100))
              if isinstance(value := publication.get(key), str) and 0 < len(value) <= limit and value.isprintable()}
    return result or None


def replay(raw, request_id, fingerprint):
    previous = raw.get('local_summary_publication') or {}
    if previous.get('request_id') != request_id:
        return None
    if previous.get('fingerprint') != fingerprint:
        raise SummaryChanged()
    return previous


@firestore.transactional
def _publish(transaction, uid, conversation_id, revision, candidate, publication, background=False, only_missing=False):
    ref = _ref(uid, conversation_id)
    raw = ref.get(transaction=transaction, timeout=6).to_dict()
    _check(raw)
    previous = replay(raw, publication['request_id'], publication['fingerprint'])
    if previous is not None:
        return previous
    if only_missing and not needs_backfill(raw):
        raise SummaryChanged()
    snapshot = source(raw, uid, background=background)
    if snapshot.revision != revision:
        raise SummaryChanged()
    structured = raw.get('structured')
    labels = summary_labels(candidate, user_category=raw.get('user_category'))
    notes = summary_note_fields(candidate, snapshot.segment_ids)
    if isinstance(structured, dict):
        patch = {f'structured.{key}': value for key, value in {**labels, **notes}.items()}
        if 'user_title' not in raw or not isinstance(raw['user_title'], str):
            patch['structured.title'] = candidate['title']
    else:
        patch = {'structured': {
            **labels, **notes, 'title': raw.get('user_title') or candidate['title'],
        }}
        if raw.get('user_category'):
            patch['structured']['category'] = raw['user_category']
    patch['local_summary_publication'] = publication
    transaction.update(ref, patch)
    return publication


def publish(uid, conversation_id, revision, candidate, publication, *, background=False, only_missing=False):
    return run_transactional(db, _publish, uid, conversation_id, revision, candidate, publication, background, only_missing)


def _classification_status(raw):
    try:
        _check(raw)
    except SummaryUnavailable:
        return 'unavailable'
    if raw.get('user_category'):
        return 'already_classified'
    structured = raw.get('structured')
    if structured is None:
        return 'pending'
    if not isinstance(structured, dict):
        return 'unavailable'
    category = structured.get('category')
    if isinstance(category, str) and category != CategoryEnum.other.value and category in CategoryEnum._value2member_map_:
        return 'already_classified'
    return 'pending'


def category_input(uid, conversation_id):
    document = _ref(uid, conversation_id).get(retry=None, timeout=6)
    raw = document.to_dict()
    state = _classification_status(raw)
    if state != 'pending':
        return state, None, None
    row = conversations._prepare_conversation_for_read(raw, uid)
    if row is None:
        return 'unavailable', None, None
    row['id'] = conversation_id
    structured = row.get('structured') or {}
    overview = structured.get('overview')
    if isinstance(overview, str) and overview.strip():
        excerpt = overview.strip()[:1400]
    else:
        try:
            row = hydrate_grouped_transcript(row, local_transcript_root(), uid)
        except (OSError, ValueError, KeyError, TypeError):
            return 'unavailable', None, None
        if ((row.get('external_data') or {}).get('local_transcript') or {}).get('segment_preview'):
            return 'unavailable', None, None
        segments = row.get('transcript_segments')
        if not isinstance(segments, list):
            return 'unavailable', None, None
        lines = [segment['text'].strip() for segment in segments
                 if isinstance(segment, dict) and isinstance(segment.get('text'), str) and segment['text'].strip()]
        if len(lines) > 6:
            lines = [lines[i * (len(lines) - 1) // 5] for i in range(6)]
        excerpt = '\n'.join(line[:220] for line in lines)
    if not excerpt:
        return 'unavailable', None, None
    title = structured.get('title')
    text = '\n'.join(value for value in (title.strip()[:120] if isinstance(title, str) else '', excerpt) if value)
    return 'pending', text, document.update_time


@firestore.transactional
def _publish_category(transaction, uid, conversation_id, revision, category):
    ref = _ref(uid, conversation_id)
    current = ref.get(transaction=transaction, timeout=6)
    raw = current.to_dict()
    state = _classification_status(raw)
    if state != 'pending':
        return state
    if current.update_time != revision:
        return 'changed'
    if category == CategoryEnum.other:
        return 'unclassified'
    patch = {'structured.category': category.value} if isinstance(raw.get('structured'), dict) else {
        'structured': {'category': category.value},
    }
    transaction.update(ref, patch)
    return 'updated'


def publish_category(uid, conversation_id, revision, category):
    return run_transactional(db, _publish_category, uid, conversation_id, revision, category)
