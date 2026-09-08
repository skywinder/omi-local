import pytest

from utils.local_transcript import build_conversation


def manifest():
    return {'audio_sha256': 'a' * 64, 'result_key': 'b' * 64, 'duration_seconds': 4,
            'started_at': '2026-01-01T00:00:00Z', 'source': 'omi',
            'profile': {'engine': 'whisperx', 'model': 'large-v3-turbo'}}


def raw():
    return {'language': 'ru', 'segments': [
        {'text': 'Проверка API.', 'start': 0.111, 'end': 1.456, 'speaker': 'SPEAKER_01'},
        {'text': 'Да.', 'start': 2.123, 'end': 3.456, 'speaker': 'SPEAKER_00'},
    ]}


def test_existing_wire_format_case_times_speakers_and_stable_identity():
    before = raw()
    conversation = build_conversation(before, manifest())
    assert before == raw()
    assert conversation.model_dump(mode='json') == build_conversation(raw(), manifest()).model_dump(mode='json')
    assert [s.text for s in conversation.transcript_segments] == ['Проверка API.', 'Да.']
    assert [s.speaker_id for s in conversation.transcript_segments] == [1, 0]
    assert conversation.transcript_segments[0].start == 0.111
    assert all(not s.is_user and s.speaker_identity_status == 'unknown' for s in conversation.transcript_segments)
    assert conversation.status == 'completed' and not conversation.deferred
    assert not conversation.structured.action_items
    alternative = manifest()
    alternative['result_key'] = 'c' * 64
    assert build_conversation(raw(), alternative).id != conversation.id


def test_parakeet_provenance_uses_same_mobile_contract():
    data = manifest()
    data['profile'] = {'engine': 'parakeet-mlx', 'model': 'mlx-community/parakeet-tdt-0.6b-v3',
                       'device': 'gpu', 'compute_type': 'float32'}
    conversation = build_conversation(raw(), data)
    assert all(s.stt_provider == 'parakeet-mlx-local' for s in conversation.transcript_segments)
    assert conversation.external_data['local_transcript']['profile'] == data['profile']
    assert conversation.status == 'completed' and conversation.uses_custom_stt


def test_word_speaker_change_splits_sentence_without_losing_text():
    data = {'language': 'ru', 'segments': [{'text': 'Да. API работает.', 'start': 0, 'end': 3,
        'speaker': 'SPEAKER_00', 'words': [
            {'word': 'Да.', 'start': 0, 'end': 0.8, 'speaker': 'SPEAKER_00'},
            {'word': 'API', 'start': 1, 'end': 1.8, 'speaker': 'SPEAKER_01'},
            {'word': 'работает.', 'start': 2, 'end': 3, 'speaker': 'SPEAKER_01'},
        ]}]}
    conversation = build_conversation(data, manifest())
    assert [s.text for s in conversation.transcript_segments] == ['Да.', 'API работает.']
    assert [s.speaker_id for s in conversation.transcript_segments] == [0, 1]
    del data['segments'][0]['words'][1]['start']
    with pytest.raises(ValueError):
        build_conversation(data, manifest())


@pytest.mark.parametrize('start', [None, True, float('nan'), -0.1, 5])
def test_invalid_timestamp_never_creates_completed_conversation(start):
    data = raw()
    data['segments'][0]['start'] = start
    with pytest.raises(ValueError):
        build_conversation(data, manifest())


def test_empty_transcript_is_not_success_and_unknown_speaker_is_not_user():
    with pytest.raises(ValueError):
        build_conversation({'segments': []}, manifest())
    data = raw()
    del data['segments'][0]['speaker']
    first = build_conversation(data, manifest()).transcript_segments[0]
    assert first.speaker is None and first.speaker_id == -1 and not first.is_user
