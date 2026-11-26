"""Fixed synthetic archive questions; no private recordings or live inference.

These cases evaluate the evidence supplied to chat. They do not establish
semantic model relevance or the factual quality of generated answers.
"""
from datetime import datetime, timezone

import pytest
from utils.conversations.local_chat import rank_archive_sources, select_sources, merge_archive_sources


OLD = datetime(2009, 1, 2, tzinfo=timezone.utc)
CURRENT = datetime(2026, 11, 26, tzinfo=timezone.utc)


def recording(identifier, text, *, version=CURRENT):
    return {'id': identifier, 'started_at': OLD, '_local_read_version': version,
            'structured': {'title': 'Synthetic archive'},
            'transcript_segments': [{'id': 'spoken', 'text': text, 'start': 7200, 'end': 7560}]}


CASES = [
    ('Where is the Meridian certificate?', 'The Meridian certificate is in the blue folder.', 'blue folder'),
    ('Где лежит акт Меридиан?', 'Акт Меридиан лежит в синей папке.', 'синей папке'),
    ('What is the Aurora budget?', 'The approved Aurora budget is 24000 euros.', '24000 euros'),
    ('Какой код у сейфа Сапфир?', 'Код сейфа Сапфир — 5017.', '5017'),
]


@pytest.mark.parametrize('query,answer,expected', CASES)
@pytest.mark.parametrize('position', ['old', 'middle', 'end'])
def test_old_and_long_recording_questions_retrieve_the_answer(query, answer, expected, position):
    filler = 'Unrelated introduction. ' * 600
    text = answer if position == 'old' else filler + answer + (filler if position == 'middle' else '')
    source = recording('old-recording', text)
    distractor = recording('new-recording', 'A recent discussion about unrelated equipment.')
    selected = merge_archive_sources(rank_archive_sources([distractor, source], query), [])
    assert selected and expected in selected[0]['text']
    assert selected[0]['conversation_id'] == 'old-recording'
    assert selected[0]['segment_id'] == 'spoken'
    assert selected[0]['start_ms'] == 7_200_000
    assert selected[0]['text'] in text  # Every excerpt remains directly citable.
    assert len(selected[0]['text']) <= 1200
    one_recording, limited = select_sources(source['transcript_segments'], query)
    assert expected in one_recording[0]['text']
    assert limited == (position != 'old')


def test_correction_is_the_evidence_even_if_summary_and_old_version_disagree():
    row = recording('corrected', 'Обновлённый срок проекта Феникс — 19 декабря.')
    row['structured']['overview'] = 'Срок проекта Феникс — 12 декабря.'
    found = rank_archive_sources([row], 'Какой срок проекта Феникс?')
    assert len(found) == 1
    assert '19 декабря' in found[0]['text'] and '12 декабря' not in found[0]['text']
    assert found[0]['revision'] == CURRENT
    assert rank_archive_sources([row], 'Where is the Neptune password?') == []


def test_hybrid_keeps_distinct_evidence_windows_from_the_same_long_segment():
    base = {'conversation_id': 'long', 'segment_id': 'spoken', 'start_ms': 0}
    keyword = {**base, 'text': 'Aurora was approved in February.'}
    semantic = {**base, 'text': 'Its budget was reduced to 24000 euros in March.'}
    selected = merge_archive_sources([keyword], [semantic, semantic])
    assert selected == [keyword, semantic]
    assert sum(len(source['text']) for source in selected) <= 9000
