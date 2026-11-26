import io
import json
import sqlite3

import pytest

from dev_harness.local_semantic import sources
from dev_harness.local_semantic_index import Source, rebuild, search


class Encoder:
    dimensions = 2
    fingerprint = 'example-v1'

    def __init__(self):
        self.encoded = []

    def encode(self, texts, *, query):
        self.encoded.extend(texts)
        return [(1.0, 0.0) if text in ('trip by rail', 'train booking') else (0.0, 1.0) for text in texts]


def test_index_keeps_only_revision_pointers_and_reuses_unchanged_vectors(tmp_path):
    path = tmp_path / 'semantic.sqlite'
    model = Encoder()
    sources = [
        Source('relevant', 'r1', [(0, 'unrelated'), (1, 'trip by rail'), (2, 'trip by rail')]),
        Source('other', 'r2', [(0, 'dinner')]),
    ]
    assert rebuild(path, 'paired', sources, model) == {'sources': 2, 'updated': 2, 'passages': 4}
    found = search(path, 'paired', 'train booking', model)
    assert [(hit.id, hit.revision, hit.position, hit.score) for hit in found] == [
        ('relevant', 'r1', 1, 1), ('other', 'r2', 0, 0),
    ]
    assert b'trip by rail' not in path.read_bytes()
    assert path.stat().st_mode & 0o077 == 0
    with pytest.raises(ValueError, match='identity'):
        search(path, 'unpaired', 'train booking', model)

    model.encoded.clear()
    assert rebuild(path, 'paired', sources[:1], model) == {'sources': 1, 'updated': 0, 'passages': 3}
    assert model.encoded == []
    assert [hit.id for hit in search(path, 'paired', 'train booking', model)] == ['relevant']

    changed = [Source('relevant', 'r3', [(0, 'dinner')])]
    assert rebuild(path, 'paired', changed, model)['updated'] == 1
    found, = search(path, 'paired', 'train booking', model)
    assert (found.revision, found.position, found.score) == ('r3', 0, 0)


def test_incomplete_inventory_keeps_previous_snapshot(tmp_path):
    path = tmp_path / 'semantic.sqlite'
    model = Encoder()
    rebuild(path, 'paired', [Source('kept', 'old', [(0, 'trip by rail')])], model)
    partial = [{'owner': 'paired', 'version': 1}, {'id': 'new', 'revision': 'new', 'passages': ['dinner']}]

    def stream(rows):
        return io.StringIO(''.join(json.dumps(item) + '\n' for item in rows))

    with pytest.raises(ValueError, match='Incomplete'):
        rebuild(path, 'paired', sources(stream(partial), 'paired'), model)
    assert [hit.id for hit in search(path, 'paired', 'train booking', model)] == ['kept']
    with pytest.raises(ValueError, match='owner'):
        rebuild(path, 'paired', sources(stream(partial), 'other'), model)
    with pytest.raises(sqlite3.IntegrityError):
        repeated = [partial[0], partial[1], partial[1], {'complete': 2}]
        rebuild(path, 'paired', sources(stream(repeated), 'paired'), model)
    assert [hit.id for hit in search(path, 'paired', 'train booking', model)] == ['kept']

    empty = [partial[0], {'complete': 0}]
    assert rebuild(path, 'paired', sources(stream(empty), 'paired'), model)['passages'] == 0
    assert search(path, 'paired', 'train booking', model) == []
