import io
import json
import sqlite3
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread

import pytest

from dev_harness.local_semantic import InventoryHandler, QueryServer, sources
from dev_harness.local_semantic_index import Source, rebuild, search
from dev_harness.local_semantic_refresh import refresh


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

    model.encoded.clear()
    reimported = [Source('relevant', 'r4', [(0, 'dinner')])]
    assert rebuild(path, 'paired', reimported, model)['updated'] == 0
    assert model.encoded == []
    found, = search(path, 'paired', 'train booking', model)
    assert (found.revision, found.position) == ('r4', 0)
    # A changed position changes what the result opens, even with identical text.
    assert rebuild(path, 'paired', [Source('relevant', 'r5', [(1, 'dinner')])], model)['updated'] == 1


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


def test_refresh_uses_local_socket_and_holds_footer_until_export_success(tmp_path):
    path = tmp_path / 'semantic.sqlite'
    model = Encoder()
    rebuild(path, 'paired', [Source('before', 'old', [(0, 'trip by rail')])], model)
    inventory = '\n'.join(json.dumps(row) for row in [
        {'owner': 'paired', 'version': 1}, {'id': 'after', 'revision': 'new', 'passages': ['trip by rail']},
        {'complete': 1},
    ])
    exporter = [sys.executable, '-c']
    with TemporaryDirectory(prefix='omi-semantic-', dir='/tmp') as directory:
        address = str(Path(directory) / 'inventory.sock')
        with QueryServer(address, path, 'paired', model, InventoryHandler) as server:
            worker = Thread(target=server.serve_forever)
            worker.start()
            try:
                failing = exporter + [f'print({inventory!r}); raise SystemExit(1)']
                with pytest.raises(ValueError, match='exporter failed'):
                    refresh(address, failing)
                assert [hit.id for hit in search(path, 'paired', 'train booking', model)] == ['before']
                assert refresh(address, exporter + [f'print({inventory!r})']) == {
                    'sources': 1, 'updated': 1, 'passages': 1,
                }
                assert [hit.id for hit in search(path, 'paired', 'train booking', model)] == ['after']
            finally:
                server.shutdown()
                worker.join()
