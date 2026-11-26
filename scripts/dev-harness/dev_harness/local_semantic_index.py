"""Disposable vector projection of one paired owner's canonical transcript revisions."""

import fcntl
import math
import os
import sqlite3
import struct
import tempfile
from contextlib import closing
from dataclasses import dataclass
from itertools import islice
from pathlib import Path
from typing import Iterable, Protocol, Sequence


_FORMAT = '1'
_SCHEMA = '''
CREATE TABLE IF NOT EXISTS identity (format TEXT NOT NULL, owner TEXT NOT NULL, model TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sources (id TEXT PRIMARY KEY, revision TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS passages (
    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    embedding BLOB NOT NULL,
    PRIMARY KEY (source_id, position)
) WITHOUT ROWID;
'''


class Encoder(Protocol):
    fingerprint: str
    dimensions: int

    def encode(self, texts: Sequence[str], *, query: bool) -> Sequence[Sequence[float]]: ...


@dataclass(frozen=True)
class Source:
    id: str
    revision: str
    passages: Iterable[tuple[int, str]]


@dataclass(frozen=True)
class Hit:
    id: str
    revision: str
    position: int
    score: float


def _readonly(path):
    return sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True)


def _matches(db, owner, encoder):
    return db.execute('SELECT format, owner, model FROM identity').fetchall() == [
        (_FORMAT, owner, encoder.fingerprint)
    ]


def _batches(iterable, size):
    chunks = iter(iterable)
    while batch := list(islice(chunks, size)):
        yield batch


def _normalize(embedding, dimensions):
    if len(embedding) != dimensions or any(not math.isfinite(x) for x in embedding):
        raise ValueError('Invalid semantic vector')
    norm = math.sqrt(math.fsum(x * x for x in embedding))
    if not norm:
        raise ValueError('Empty semantic vector')
    return [x / norm for x in embedding]


def rebuild(path, owner: str, sources: Iterable[Source], encoder: Encoder) -> dict:
    """Reconcile a complete inventory. Partial reads leave the last index usable."""
    path = Path(path)
    with os.fdopen(os.open(path.with_suffix('.lock'), os.O_CREAT | os.O_RDWR, 0o600), 'r+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fd, filename = tempfile.mkstemp(prefix=f'.{path.name}.', dir=path.parent)
        os.close(fd)
        stage = Path(filename)
        try:
            summary = _populate(stage, path, owner, sources, encoder)
            os.replace(stage, path)
            parent = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(parent)
            finally:
                os.close(parent)
            return summary
        finally:
            stage.unlink(missing_ok=True)


def _populate(stage, previous, owner, sources, encoder):
    vector = struct.Struct(f'<{encoder.dimensions}f')
    scanned = updated = 0
    with closing(sqlite3.connect(stage)) as db:
        if previous.is_file():
            with closing(_readonly(previous)) as old:
                if _matches(old, owner, encoder):
                    old.backup(db)
        db.execute('PRAGMA foreign_keys = ON')
        db.execute('PRAGMA secure_delete = ON')
        db.executescript(_SCHEMA)
        with db:
            if not _matches(db, owner, encoder):
                db.execute('INSERT INTO identity VALUES (?, ?, ?)', (_FORMAT, owner, encoder.fingerprint))
            db.execute('CREATE TEMP TABLE seen (id TEXT PRIMARY KEY)')
            for source in sources:
                db.execute('INSERT INTO seen VALUES (?)', (source.id,))
                scanned += 1
                previous_revision = db.execute('SELECT revision FROM sources WHERE id = ?', (source.id,)).fetchone()
                if previous_revision == (source.revision,):
                    continue
                updated += 1
                db.execute('DELETE FROM sources WHERE id = ?', (source.id,))
                db.execute('INSERT INTO sources VALUES (?, ?)', (source.id, source.revision))
                for batch in _batches(source.passages, 8):
                    vectors = encoder.encode([text for _, text in batch], query=False)
                    db.executemany(
                        'INSERT INTO passages VALUES (?, ?, ?)',
                        ((source.id, position, vector.pack(*_normalize(values, encoder.dimensions)))
                         for (position, _), values in zip(batch, vectors, strict=True)),
                    )
            db.execute('DELETE FROM sources WHERE id NOT IN (SELECT id FROM seen)')
            count, = db.execute('SELECT COUNT(*) FROM passages').fetchone()
    return {'sources': scanned, 'updated': updated, 'passages': count}


def search(path, owner: str, query: str, encoder: Encoder, *, limit: int = 40) -> list[Hit]:
    """Rank source pointers. The paired API must recheck revisions before exposing text."""
    import numpy as np

    query = query.strip()
    if not query or len(query) > 240 or not 1 <= limit <= 100:
        raise ValueError('Invalid semantic query')
    size = encoder.dimensions * 4
    with closing(_readonly(path)) as db:
        if not _matches(db, owner, encoder):
            raise ValueError('Semantic index identity mismatch')
        query_vector, = encoder.encode([query], query=True)
        query_vector = np.asarray(_normalize(query_vector, encoder.dimensions), dtype=np.float32)
        best: dict[str, Hit] = {}
        passages = db.execute('''
            SELECT p.source_id, s.revision, p.position, p.embedding
            FROM passages p JOIN sources s ON s.id = p.source_id
        ''')
        for batch in _batches(passages, 512):
            if any(len(row[3]) != size for row in batch):
                raise ValueError('Invalid indexed vector size')
            vectors = np.frombuffer(b''.join(row[3] for row in batch), dtype='<f4').reshape(-1, encoder.dimensions)
            scores = np.sum(vectors * query_vector, axis=1)
            for (identifier, revision, position, _), value in zip(batch, scores, strict=True):
                score = float(value)
                prior = best.get(identifier)
                if prior is None or (score, -position) > (prior.score, -prior.position):
                    best[identifier] = Hit(identifier, revision, position, score)
        return sorted(best.values(), key=lambda hit: (-hit.score, hit.id))[:limit]
