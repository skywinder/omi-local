"""Owner-scoped chat history stored beside the recording, in the local emulator."""

import json
from datetime import datetime, timezone

from google.cloud import firestore

from database import conversations
from database._client import db, run_transactional
from utils import encryption


class RecordingUnavailable(ValueError):
    pass


class RecordingChanged(ValueError):
    pass


def _recording(uid, conversation_id):
    return db.collection('users').document(uid).collection(conversations.conversations_collection).document(conversation_id)


def _available(data):
    return data is not None and not (data.get('is_locked') or data.get('local_chat_deleting'))


def recording(uid, conversation_id):
    fields = ['is_locked', 'local_chat_deleting', 'data_protection_level',
              'transcript_segments', 'transcript_segments_compressed']
    snapshot = _recording(uid, conversation_id).get(field_paths=fields, retry=None, timeout=6)
    data = snapshot.to_dict()
    if not _available(data):
        raise RecordingUnavailable()
    return snapshot.update_time, conversations._prepare_conversation_for_read(data, uid) or {}


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


def history(uid, conversation_id, *, before=None, limit=12):
    query = _turns(uid, conversation_id).order_by('sequence', direction=firestore.Query.DESCENDING)
    if before is not None:
        query = query.start_after({'sequence': before})
    documents = list(query.limit(limit + 1).stream(retry=None, timeout=6))
    turns = [_read_turn(uid, document) for document in documents[:limit]]
    return turns, turns[-1]['sequence'] if len(documents) > limit else None


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
    sequence = head.get('count', 0) + 1
    created_at = datetime.now(timezone.utc)
    encrypted = encryption.encrypt(json.dumps(payload, ensure_ascii=False), uid)
    transaction.create(ref, {'sequence': sequence, 'created_at': created_at, 'payload': encrypted})
    transaction.set(head_ref, {'id': request_id, 'count': sequence})
    return {'id': request_id, 'sequence': sequence, 'created_at': created_at, **payload}


def publish(uid, conversation_id, request_id, previous, revision, payload):
    return run_transactional(db, _publish, uid, conversation_id, request_id, previous, revision, payload)


def delete_recording(uid, conversation_id):
    # Inference runs without a database lock. Make in-flight answers ineligible
    # for publication before enumerating the recording's owned children.
    _recording(uid, conversation_id).update({'local_chat_deleting': True}, timeout=6)
    conversations.delete_conversation(uid, conversation_id)
