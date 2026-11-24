"""Optimistic publication of a paired recording summary."""

import hashlib
import json
import math

from google.cloud import firestore

from database import conversations
from database._client import db, run_transactional


class SummaryUnavailable(ValueError):
    pass


class SummaryChanged(ValueError):
    pass


class SummaryTooLarge(ValueError):
    pass


def _ref(uid, conversation_id):
    return db.collection('users').document(uid).collection(conversations.conversations_collection).document(
        conversation_id,
    )


def _check(raw):
    if (not raw or raw.get('is_locked') or raw.get('local_chat_deleting')
            or raw.get('status') not in {None, 'completed'}):
        raise SummaryUnavailable()


def _transcript(raw, uid):
    external = raw.get('external_data') or {}
    if (external.get('local_transcript') or {}).get('segment_preview'):
        raise SummaryTooLarge()
    row = conversations._prepare_conversation_for_read(raw, uid)
    segments = row.get('transcript_segments')
    if not isinstance(segments, list):
        return ''
    lines, length = [], 0
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
        prefix = f'{speaker}: ' if speaker else ''
        line = time + prefix + text
        length += len(line) + 1
        if length > 120_000:
            raise SummaryTooLarge()
        lines.append(line)
    return '\n'.join(lines)


def _revision(raw, transcript):
    structured = raw.get('structured')
    structured = structured if isinstance(structured, dict) else {}
    previous = (raw.get('local_summary_publication') or {}).get('request_id')
    return hashlib.sha256(json.dumps(
        [transcript, structured.get('overview'), structured.get('sections'), previous],
        ensure_ascii=False, sort_keys=True,
    ).encode()).hexdigest()


def recording(uid, conversation_id):
    raw = _ref(uid, conversation_id).get(retry=None, timeout=6).to_dict()
    _check(raw)
    return raw


def source(raw, uid):
    transcript = _transcript(raw, uid)
    return transcript, _revision(raw, transcript)


def replay(raw, request_id, fingerprint):
    previous = raw.get('local_summary_publication') or {}
    if previous.get('request_id') != request_id:
        return None
    if previous.get('fingerprint') != fingerprint:
        raise SummaryChanged()
    return previous


@firestore.transactional
def _publish(transaction, uid, conversation_id, revision, candidate, publication):
    ref = _ref(uid, conversation_id)
    raw = ref.get(transaction=transaction, timeout=6).to_dict()
    _check(raw)
    previous = replay(raw, publication['request_id'], publication['fingerprint'])
    if previous is not None:
        return previous
    _, current = source(raw, uid)
    if current != revision:
        raise SummaryChanged()
    structured = raw.get('structured')
    if isinstance(structured, dict):
        patch = {'structured.overview': candidate['overview']}
        if 'user_title' not in raw or not isinstance(raw['user_title'], str):
            patch['structured.title'] = candidate['title']
    else:
        patch = {'structured': {'title': raw.get('user_title') or candidate['title'], 'overview': candidate['overview']}}
    patch['local_summary_publication'] = publication
    transaction.update(ref, patch)
    return publication


def publish(uid, conversation_id, revision, candidate, publication):
    return run_transactional(db, _publish, uid, conversation_id, revision, candidate, publication)
