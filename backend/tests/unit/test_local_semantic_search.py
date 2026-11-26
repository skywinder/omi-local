from datetime import datetime, timezone

import pytest

from utils.conversations.local_chat import merge_archive_sources, semantic_archive_source
from utils.conversations.local_semantic_search import SemanticUnavailable, resolve, resolve_passages
from utils.conversations.semantic_passages import passages, source_revision


def test_ranked_pointers_hydrate_only_current_sources_and_keep_seek_anchor():
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    row = {'_local_read_version': now, 'started_at': now, 'structured': {'title': 'Test'}, 'transcript_segments': []}
    rows = {'changed': row, 'current': row}
    hydrated = []

    def hydrate(source):
        hydrated.append(source)
        return {**source, 'transcript_segments': [
            {'id': 'prior', 'start': 7.0, 'end': 11.0, 'text': 'I found the old bank documents.'},
            {'id': 'seek', 'start': 12.5, 'end': 15.0, 'text': 'Here is the affidavit.'},
        ]}

    result, = resolve([
        {'id': 'changed', 'revision': 'older', 'position': 2},
        {'id': 'deleted', 'revision': source_revision(now), 'position': 2},
        {'id': 'current', 'revision': source_revision(now), 'position': 2},
    ], rows, hydrate)
    assert len(hydrated) == 1
    assert result['id'] == 'current'
    assert result['match_snippets'] == [{
        'text': 'Here is the affidavit.', 'segment_id': 'seek', 'start': 12.5, 'end': 15.0,
    }]
    items = list(passages(hydrate(row)))
    assert 'bank documents' in items[2].text
    assert items[2].snippet['segment_id'] == 'seek'
    assert items[2].source_text == 'Here is the affidavit.'

    with pytest.raises(SemanticUnavailable):
        resolve([{'id': 'changed', 'revision': 'older', 'position': 2}], rows, hydrate)


def test_semantic_chat_cites_the_match_window_and_merges_distinct_segments_within_budget():
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    late = 'The shutoff is beside the boiler.'
    row = {'_local_read_version': now, 'started_at': now, 'structured': {'title': 'Summary only'},
           'transcript_segments': [{'id': 'late', 'start': 10, 'text': 'x' * 820 + late}]}
    hits = [{'id': 'recording', 'revision': source_revision(now), 'position': i} for i in (0, 2)]
    summary, answer = resolve_passages(hits, {'recording': row}, lambda value: value)
    assert semantic_archive_source(*summary) is None
    match = semantic_archive_source(*answer)
    assert match['segment_id'] == 'late' and match['start_ms'] == 10_000 and late in match['text']
    assert not match['text'].startswith('x' * 200)  # This is the matched window, past the first 640 characters.
    keyword = [{'conversation_id': 'recording', 'segment_id': 'keyword', 'text': 'typed terms'}]
    extra = [{'conversation_id': 'recording', 'segment_id': str(i), 'text': 'z' * 1200} for i in range(20)]
    selected = merge_archive_sources([*keyword, *extra], [match, match])
    assert selected[:2] == [keyword[0], match] and selected.count(match) == 1
    assert sum(len(source['text']) for source in selected) <= 9000
