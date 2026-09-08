"""Delete only Conversations whose exact local-WAV provenance was verified."""

import re
import uuid


def delete_linked_conversations(owner, digest, result_keys, *, get, delete, check_only=False):
    if not re.fullmatch(r'[0-9a-f]{64}', digest) or not isinstance(result_keys, list):
        raise ValueError('Invalid local recording reference')
    references = []
    for key in set(result_keys):
        if not isinstance(key, str) or not re.fullmatch(r'[0-9a-f]{64}', key):
            raise ValueError('Invalid local transcript reference')
        conversation_id = str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + key))
        saved = get(owner, conversation_id)
        if saved is not None:
            provenance = (saved.get('external_data') or {}).get('local_transcript') or {}
            if (provenance.get('audio_sha256') != digest or provenance.get('result_key') != key
                    or saved.get('audio_files') or saved.get('photos')):
                raise ValueError('Conversation provenance changed; nothing deleted')
            references.append(conversation_id)
    # All references must pass before the first write. Absent rows make retry safe.
    if not check_only:
        for conversation_id in references:
            delete(owner, conversation_id)
            if get(owner, conversation_id) is not None:
                raise ValueError('Conversation deletion could not be verified')
    return len(references)
