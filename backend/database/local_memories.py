"""Paired memory review authority; encrypted facts with rechecked source evidence.

The hosted memory admission/graph pipeline is not active in this runtime. Local
proposals and reviewed facts share this one store and Omi's MemoryEvidence shape.
No derived index may treat a row as confirmed without checking its source.
"""
import hashlib
import json
from datetime import datetime, timezone
from time import monotonic
from uuid import uuid4

from google.cloud import firestore
from database._client import db, run_transactional
from database import local_recording_chat as archive
from utils import encryption


class MemoryConflict(ValueError):
    pass


class MemoryUnavailable(ValueError):
    pass


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def _collection(uid, name='local_memories'):
    return db.collection('users').document(uid).collection(name)


def _request(uid, request_id):
    return _collection(uid, 'local_memory_requests').document(request_id)


def receipt(uid, request_id, expected):
    row = _request(uid, request_id).get(retry=None, timeout=6).to_dict()
    return _replay(row, expected)


def _replay(row, expected):
    if row is None:
        return None
    if row['fingerprint'] != expected:
        raise MemoryConflict()
    return row['result']


def _run(fn, *args):
    # SDK wrappers retain retry state: allocate one for each concurrent call.
    return run_transactional(db, firestore.transactional(fn), *args)


def _source_guard(tx, uid, identifier, version):
    doc = archive._recording(uid, identifier).get(transaction=tx, timeout=6)
    raw = doc.to_dict()
    if (not archive._available(raw) or any(raw.get(key) for key in ('deleted', 'discarded'))
            or doc.update_time != version):
        raise MemoryConflict()


def _publish(tx, uid, source_id, version, proposals, request_id, expected, limited):
    request_ref = _request(uid, request_id)
    replay = _replay(request_ref.get(transaction=tx, timeout=6).to_dict(), expected)
    if replay is not None:
        return replay
    _source_guard(tx, uid, source_id, version)
    refs = [(_collection(uid).document(item['id']), item) for item in proposals]
    present = [ref.get(transaction=tx, timeout=6).exists for ref, _ in refs]
    instant = datetime.now(timezone.utc)
    for (ref, proposal), exists in zip(refs, present):
        if exists:
            continue  # A repeated extraction cannot overwrite review or resurrect a deletion.
        tx.create(ref, {'source_id': source_id, 'state': 'proposed', 'revision': str(uuid4()),
                        'created_at': instant, 'updated_at': instant,
                        'payload': encryption.encrypt(json.dumps({**proposal, 'original_content': proposal['content'],
                                                                 'revisions': []}, ensure_ascii=False), uid)})
    result = {'created': len(refs) - sum(present), 'existing': sum(present), 'context_limited': limited}
    tx.create(request_ref, {'fingerprint': expected, 'result': result})
    return result


def publish(uid, source_id, version, proposals, request_id, expected, limited):
    return _run(_publish, uid, source_id, version, proposals, request_id, expected, limited)


def _payload(uid, raw):
    return json.loads(encryption.decrypt(raw['payload'], uid))


def source_status(uid, payload, cache=None):
    evidence = payload['evidence']
    identifier = evidence['conversation_id']
    cache = {} if cache is None else cache
    if identifier not in cache:
        try:
            cache[identifier] = archive.recording(uid, identifier)
        except archive.RecordingUnavailable:
            cache[identifier] = None
    checked = cache[identifier]
    if checked is None:
        return 'unavailable', None
    version, recording = checked
    citation = evidence['quote_refs'][0]
    matches = [row for row in recording.get('transcript_segments', [])
               if isinstance(row, dict) and row.get('id') == citation['segment_id']]
    if len(matches) != 1 or not isinstance(matches[0].get('text'), str):
        return 'changed', version
    text = matches[0]['text']
    current = hashlib.sha256(text.encode()).hexdigest() == evidence['content_hash'] and citation['quote'] in text
    return ('current' if current else 'changed'), version


def _public(uid, identifier, raw, cache=None):
    if raw is None or raw['state'] == 'deleted':
        raise MemoryUnavailable()
    payload = _payload(uid, raw)
    source, _ = source_status(uid, payload, cache)
    citation = payload['evidence']['quote_refs'][0]
    return {'id': identifier, 'revision': raw['revision'], 'state': raw['state'], 'source_status': source,
            'eligible': raw['state'] == 'accepted' and source == 'current',
            'content': payload['content'], 'conversation_id': raw['source_id'],
            'segment_id': citation['segment_id'], 'start_ms': citation.get('start_ms'),
            'quote': citation['quote'] if source == 'current' else None,
            'created_at': raw['created_at'], 'updated_at': raw['updated_at'],
            'original_content': payload.get('original_content', payload['content']),
            'revisions': payload.get('revisions', [])}


def read(uid, identifier):
    return _public(uid, identifier, _collection(uid).document(identifier).get(retry=None, timeout=6).to_dict())


def list_page(uid, *, state='accepted', source_id=None, query='', after=None):
    collection = _collection(uid)
    if source_id:
        collection = collection.where(filter=firestore.FieldFilter('source_id', '==', source_id))
    else:
        collection = collection.where(filter=firestore.FieldFilter('state', '==', state))
    collection = collection.order_by('__name__')
    if after:
        collection = collection.start_after({'__name__': _collection(uid).document(after)})
    documents = list(collection.limit(21).stream(retry=None, timeout=6))
    rows, cache, cursor = [], {}, None
    terms = query.casefold().split()
    deadline = monotonic() + 15
    for doc in documents[:20]:
        if cursor is not None and monotonic() > deadline:
            break
        cursor = doc.id
        raw = doc.to_dict()
        if not raw or raw['state'] == 'deleted' or raw['state'] != state:
            continue
        row = _public(uid, doc.id, raw, cache)
        # Search is an eligibility boundary, never a projection of stale facts.
        if terms and (not row['eligible'] or not all(term in row['content'].casefold() for term in terms)):
            continue
        rows.append(row)
    more = bool(documents and cursor != documents[-1].id)
    return {'items': rows, 'next_after': cursor if more else None}


def _mutate(tx, uid, identifier, request_id, expected, revision, action, content, source_version):
    request_ref = _request(uid, request_id)
    replay = _replay(request_ref.get(transaction=tx, timeout=6).to_dict(), expected)
    if replay is not None:
        return replay
    ref = _collection(uid).document(identifier)
    raw = ref.get(transaction=tx, timeout=6).to_dict()
    if not raw or raw['state'] == 'deleted':
        raise MemoryUnavailable()
    if raw['revision'] != revision:
        raise MemoryConflict()
    payload = _payload(uid, raw)
    if action in {'accept', 'edit'}:
        if action == 'edit' and raw['state'] != 'accepted':
            raise MemoryConflict()
        _source_guard(tx, uid, raw['source_id'], source_version)
        if content is not None and content != payload['content']:
            payload['revisions'] = [*payload.get('revisions', []),
                {'content': payload['content'], 'changed_at': datetime.now(timezone.utc).isoformat()}][-20:]
            payload['content'] = content
        state = 'accepted'
    elif action == 'reject':
        if raw['state'] == 'accepted':
            raise MemoryConflict()
        state = 'rejected'
    elif action == 'delete':
        state = 'deleted'
    else:
        raise MemoryConflict()
    updated = {**raw, 'state': state, 'revision': str(uuid4()), 'updated_at': datetime.now(timezone.utc),
               'payload': None if state == 'deleted' else encryption.encrypt(json.dumps(payload, ensure_ascii=False), uid)}
    if state == 'deleted':
        updated.pop('source_id', None)
    result = {'id': identifier, 'revision': updated['revision'], 'state': state}
    tx.set(ref, updated)
    tx.create(request_ref, {'fingerprint': expected, 'result': result})
    return result


def mutate(uid, identifier, request_id, revision, action, content=None):
    expected = fingerprint([identifier, revision, action, content])
    previous = receipt(uid, request_id, expected)
    if previous is not None:
        return previous
    source_version = None
    if action in {'accept', 'edit'}:
        raw = _collection(uid).document(identifier).get(retry=None, timeout=6).to_dict()
        if not raw or raw['state'] == 'deleted':
            raise MemoryUnavailable()
        source, source_version = source_status(uid, _payload(uid, raw))
        if source != 'current':
            raise MemoryConflict()
    return _run(_mutate, uid, identifier, request_id, expected, revision, action, content, source_version)
