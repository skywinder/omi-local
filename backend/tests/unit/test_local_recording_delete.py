import uuid

import pytest

from utils.local_recording_delete import delete_linked_conversations


def test_delete_matches_every_profile_and_is_retryable():
    digest = 'a' * 64
    keys = ['b' * 64, 'c' * 64]
    saved = {str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + key)):
             {'external_data': {'local_transcript': {'audio_sha256': digest, 'result_key': key}}} for key in keys}
    def get(owner, key):
        assert owner == 'synthetic-owner'
        return saved.get(key)
    def delete(owner, key):
        assert owner == 'synthetic-owner'
        del saved[key]
    assert delete_linked_conversations('synthetic-owner', digest, keys, get=get, delete=delete) == 2
    assert not saved
    assert delete_linked_conversations('synthetic-owner', digest, keys, get=get, delete=delete) == 0


def test_changed_provenance_prevents_all_deletion():
    deleted = []
    with pytest.raises(ValueError, match='provenance'):
        delete_linked_conversations('synthetic-owner', 'a' * 64, ['b' * 64],
            get=lambda *_: {'external_data': {'local_transcript': {'audio_sha256': 'c' * 64}}},
            delete=lambda *args: deleted.append(args))
    assert not deleted
