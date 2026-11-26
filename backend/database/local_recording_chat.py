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


class ArchiveThreadUnavailable(ValueError):
    pass


class ArchiveChatLimit(ValueError):
    pass


_THREAD_LIMIT = 40
_THREAD_TURN_LIMIT = 250


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


def _archive_threads(uid):
    return db.collection('users').document(uid).collection('local_archive_chat_threads')


def _active_archive_threads(uid):
    return _archive_threads(uid).where(filter=firestore.FieldFilter('state', '==', 'active')).limit(_THREAD_LIMIT)


def _thread_label(uid, identifier, data):
    return {'id': identifier, 'title': encryption.decrypt(data['title'], uid), 'created_at': data['created_at']}


def archive_threads(uid):
    rows = _active_archive_threads(uid).stream(retry=None, timeout=6)
    labels = [_thread_label(uid, row.id, row.to_dict()) for row in rows]
    return sorted(labels, key=lambda row: (row['created_at'], row['id']), reverse=True)


@firestore.transactional
def _create_archive_thread(transaction, uid, thread_id, title):
    ref = _archive_threads(uid).document(thread_id)
    existing = ref.get(transaction=transaction, timeout=6).to_dict()
    if existing is not None:
        if existing['state'] != 'active':
            raise ArchiveThreadUnavailable()
        label = _thread_label(uid, thread_id, existing)
        if label['title'] != title:
            raise RecordingChanged()
        return label
    if len(list(_active_archive_threads(uid).stream(transaction=transaction, retry=None, timeout=6))) >= _THREAD_LIMIT:
        raise ArchiveChatLimit()
    created_at = datetime.now(timezone.utc)
    transaction.create(ref, {'state': 'active', 'title': encryption.encrypt(title, uid), 'created_at': created_at})
    return {'id': thread_id, 'title': title, 'created_at': created_at}


def create_archive_thread(uid, thread_id, title):
    return run_transactional(db, _create_archive_thread, uid, thread_id, title)


@firestore.transactional
def _delete_archive_thread(transaction, uid, thread_id):
    ref = _archive_threads(uid).document(thread_id)
    thread = ref.get(transaction=transaction, timeout=6).to_dict()
    if thread is None:
        raise ArchiveThreadUnavailable()
    if thread['state'] == 'deleted':
        return
    turns = list(ref.collection('turns').select([]).limit(_THREAD_TURN_LIMIT + 2).stream(
        transaction=transaction, retry=None, timeout=8,
    ))
    if len(turns) > _THREAD_TURN_LIMIT + 1:  # One extra document is the head.
        raise ArchiveChatLimit()
    for turn in turns:
        transaction.delete(turn.reference)
    # Keep only the ID as a fence against replaying an old creation request.
    transaction.set(ref, {'state': 'deleted'})


def delete_archive_thread(uid, thread_id):
    run_transactional(db, _delete_archive_thread, uid, thread_id)


def _archive_turns(uid, thread_id, transaction=None):
    if thread_id is None:
        return db.collection('users').document(uid).collection('local_archive_chat')
    ref = _archive_threads(uid).document(thread_id)
    thread = ref.get(transaction=transaction, field_paths=['state'], retry=None, timeout=6).to_dict()
    if not thread or thread['state'] != 'active':
        raise ArchiveThreadUnavailable()
    return ref.collection('turns')


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


def archive_turn(uid, request_id, *, thread_id=None):
    ref = _archive_turns(uid, thread_id).document(request_id)
    existing = _read_turn(uid, ref.get(retry=None, timeout=6))
    return _archive_redact(existing, _archive_recordings(uid, existing['source_ids'])) if existing else None


def archive_history(uid, *, before=None, limit=12, thread_id=None):
    turns, next_before = _history(uid, _archive_turns(uid, thread_id), before, limit)
    available = _archive_recordings(uid, {identifier for turn in turns for identifier in turn['source_ids']})
    return [_archive_redact(turn, available) for turn in turns], next_before


def archive_sources_available(uid, ids):
    return len(_archive_recordings(uid, ids)) == len(ids)


def archive_thread_full(sequence):
    return sequence >= _THREAD_TURN_LIMIT


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
def _publish_archive(transaction, uid, request_id, previous, revisions, payload, thread_id=None):
    collection = _archive_turns(uid, thread_id, transaction)
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
    if thread_id is not None and archive_thread_full(head.get('count', 0)):
        raise ArchiveChatLimit()
    if (head.get('id') != previous or len(available) != len(payload['source_ids'])
            or any(available.get(identifier) != revision for identifier, revision in revisions.items())):
        raise RecordingChanged()
    return _append_turn(transaction, uid, ref, head_ref, head, payload)


def publish_archive(uid, request_id, previous, revisions, payload, *, thread_id=None):
    return run_transactional(db, _publish_archive, uid, request_id, previous, revisions, payload, thread_id)


def delete_recording(uid, conversation_id):
    # Inference runs without a database lock. Make in-flight answers ineligible
    # for publication before enumerating the recording's owned children.
    _recording(uid, conversation_id).update({'local_chat_deleting': True}, timeout=6)
    conversations.delete_conversation(uid, conversation_id)
