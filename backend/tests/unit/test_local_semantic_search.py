from datetime import datetime, timezone

from utils.conversations.local_semantic_search import resolve
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
