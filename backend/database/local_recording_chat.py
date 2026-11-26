"""Owner-scoped recording and archive chat history in the local emulator."""

import json
from datetime import datetime, timezone

from google.cloud import firestore

from database import conversations
from database._client import db, run_transactional
from utils import encryption
from utils.local_transcript import hydrate_grouped_transcript, local_transcript_root


class RecordingUnavailable(ValueError):
    pass


class RecordingChanged(ValueError):
    pass


def _recording(uid, conversation_id):
    return db.collection('users').document(uid).collection(conversations.conversations_collection).document(conversation_id)


def _available(data):
    return data is not None and not (data.get('is_locked') or data.get('local_chat_deleting'))


def recording(uid, conversation_id):
    row = conversations.read_local_search_sources(uid, [conversation_id]).get(conversation_id)
    if row is None:
        raise RecordingUnavailable()
    try:
        return row['_local_read_version'], hydrate_grouped_transcript(row, local_transcript_root(), uid)
    except (ValueError, OSError):
        raise RecordingUnavailable() from None


def sources_current(uid, revisions):
    documents = [_recording(uid, identifier) for identifier in revisions]
    current = {
        snapshot.id: snapshot.update_time
        for snapshot in db.get_all(documents, field_paths=['is_locked', 'local_chat_deleting'], retry=None, timeout=6)
        if _available(snapshot.to_dict())
    }
    return current == revisions


def _turns(uid, conversation_id):
    return _recording(uid, conversation_id).collection('local_chat')


def _read_turn(uid, snapshot):
    data = snapshot.to_dict()
    if not data:
        return None
    return {'id': snapshot.id, 'sequence': data['sequence'], 'created_at': data['created_at'],
            **json.loads(encryption.decrypt(data['payload'], uid))}


def turn(uid, conversation_id, request_id):
    snapshot = _turns(uid, conversation_id).document(request_id).get(retry=None, timeout=6)
    return _read_turn(uid, snapshot)


def _history(uid, collection, before, limit):
    query = collection.order_by('sequence', direction=firestore.Query.DESCENDING)
    if before is not None:
        query = query.start_after({'sequence': before})
    documents = list(query.limit(limit + 1).stream(retry=None, timeout=6))
    turns = [_read_turn(uid, document) for document in documents[:limit]]
    return turns, turns[-1]['sequence'] if len(documents) > limit else None


def history(uid, conversation_id, *, before=None, limit=12):
    return _history(uid, _turns(uid, conversation_id), before, limit)


def _archive_turns(uid):
    return db.collection('users').document(uid).collection('local_archive_chat')


def _archive_recordings(uid, ids, transaction=None):
    if not ids:
        return {}
    rows = db.get_all([_recording(uid, identifier) for identifier in ids], transaction=transaction,
                      field_paths=['is_locked', 'local_chat_deleting', 'deleted'], retry=None, timeout=6)
    return {row.id: row.update_time for row in rows
            if _available(data := row.to_dict()) and not conversations.is_soft_deleted(data)}


def _archive_redact(turn, available):
    if all(identifier in available for identifier in turn['source_ids']):
        return turn
    return {**turn, 'answer': '', 'evidence_references': [], 'sources_unavailable': True}


def archive_turn(uid, request_id):
    ref = _archive_turns(uid).document(request_id)
    existing = _read_turn(uid, ref.get(retry=None, timeout=6))
    return _archive_redact(existing, _archive_recordings(uid, existing['source_ids'])) if existing else None


def archive_history(uid, *, before=None, limit=12):
    turns, next_before = _history(uid, _archive_turns(uid), before, limit)
    available = _archive_recordings(uid, {identifier for turn in turns for identifier in turn['source_ids']})
    return [_archive_redact(turn, available) for turn in turns], next_before


def archive_sources_available(uid, ids):
    return len(_archive_recordings(uid, ids)) == len(ids)


def _append_turn(transaction, uid, ref, head_ref, head, payload):
    sequence = head.get('count', 0) + 1
    created_at = datetime.now(timezone.utc)
    encrypted = encryption.encrypt(json.dumps(payload, ensure_ascii=False), uid)
    transaction.create(ref, {'sequence': sequence, 'created_at': created_at, 'payload': encrypted})
    transaction.set(head_ref, {'id': ref.id, 'count': sequence})
    return {'id': ref.id, 'sequence': sequence, 'created_at': created_at, **payload}


@firestore.transactional
def _publish(transaction, uid, conversation_id, request_id, previous, revision, payload):
    parent = _recording(uid, conversation_id)
    source = parent.get(transaction=transaction, field_paths=['is_locked', 'local_chat_deleting'], timeout=6)
    if not _available(source.to_dict()):
        raise RecordingUnavailable()
    collection = _turns(uid, conversation_id)
    ref = collection.document(request_id)
    existing = _read_turn(uid, ref.get(transaction=transaction, timeout=6))
    if existing is not None:
        if existing['question'] != payload['question']:
            raise RecordingChanged()
        return existing
    if revision != source.update_time:
        raise RecordingChanged()

    head_ref = collection.document('head')
    head = head_ref.get(transaction=transaction, timeout=6).to_dict() or {}
    if head.get('id') != previous:
        raise RecordingChanged()
    return _append_turn(transaction, uid, ref, head_ref, head, payload)


def publish(uid, conversation_id, request_id, previous, revision, payload):
    return run_transactional(db, _publish, uid, conversation_id, request_id, previous, revision, payload)


@firestore.transactional
def _publish_archive(transaction, uid, request_id, previous, revisions, payload):
    collection = _archive_turns(uid)
    ref = collection.document(request_id)
    existing = _read_turn(uid, ref.get(transaction=transaction, timeout=6))
    source = existing if existing is not None else payload
    available = _archive_recordings(uid, source['source_ids'], transaction=transaction)
    if existing is not None:
        if existing['question'] != payload['question']:
            raise RecordingChanged()
        return _archive_redact(existing, available)
    head_ref = collection.document('head')
    head = head_ref.get(transaction=transaction, timeout=6).to_dict() or {}
    if (head.get('id') != previous or len(available) != len(payload['source_ids'])
            or any(available.get(identifier) != revision for identifier, revision in revisions.items())):
        raise RecordingChanged()
    return _append_turn(transaction, uid, ref, head_ref, head, payload)


def publish_archive(uid, request_id, previous, revisions, payload):
    return run_transactional(db, _publish_archive, uid, request_id, previous, revisions, payload)


def delete_recording(uid, conversation_id):
    # Inference runs without a database lock. Make in-flight answers ineligible
    # for publication before enumerating the recording's owned children.
    _recording(uid, conversation_id).update({'local_chat_deleting': True}, timeout=6)
    conversations.delete_conversation(uid, conversation_id)
