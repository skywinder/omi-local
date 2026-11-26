"""Review, encryption, source invalidation and replay through production transactions."""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

from cryptography.fernet import Fernet
import pytest

from database import local_memories as memory


class Ref:
    def __init__(self, store, path): self.store, self.path = store, path
    @property
    def id(self): return self.path[-1]
    def collection(self, name): return Collection(self.store, self.path + (name,))
    def get(self, **kwargs):
        raw = deepcopy(self.store.rows.get(self.path))
        return SimpleNamespace(id=self.id, exists=raw is not None, to_dict=lambda: raw,
                               update_time=self.store.version, reference=self)


class Collection:
    def __init__(self, store, path):
        self.store, self.path, self.filters, self.after, self.count = store, path, [], None, 100
    def document(self, name): return Ref(self.store, self.path + (name,))
    def where(self, filter):
        self.filters.append((filter.field_path, filter.value))
        return self
    def order_by(self, field): return self
    def start_after(self, fields):
        self.after = fields['__name__'].id
        return self
    def limit(self, count):
        self.count = count
        return self
    def stream(self, **kwargs):
        selected = []
        for path, raw in sorted(self.store.rows.items()):
            if path[:-1] != self.path or (self.after and path[-1] <= self.after): continue
            if all(raw.get(key) == value for key, value in self.filters): selected.append(Ref(self.store, path).get())
        return selected[:self.count]


class Store:
    def __init__(self):
        self.rows = {}
        self.version = datetime(2026, 11, 27, tzinfo=timezone.utc)
        self.source = {'transcript_segments': [{'id': 'line', 'text': 'Project Aurora uses SQLite.', 'start': 5}]}
        self.source_ref = Ref(self, ('users', 'owner', 'conversations', 'recording'))
        self.rows[self.source_ref.path] = {}
    def collection(self, name): return Collection(self, (name,))
    def create(self, ref, row):
        assert ref.path not in self.rows
        self.rows[ref.path] = deepcopy(row)
    def set(self, ref, row): self.rows[ref.path] = deepcopy(row)


@pytest.fixture
def store(monkeypatch):
    store = Store()
    monkeypatch.setattr(memory, 'db', store)
    monkeypatch.setattr(memory, '_run', lambda fn, *args: fn(store, *args))
    def recording(uid, identifier):
        if uid != 'owner' or identifier != 'recording' or store.source is None:
            raise memory.archive.RecordingUnavailable()
        return store.version, deepcopy(store.source)
    monkeypatch.setattr(memory.archive, 'recording', recording)
    monkeypatch.setattr(memory.archive, '_recording', lambda uid, identifier:
                        Ref(store, ('users', uid, 'conversations', identifier)))
    cipher = Fernet(Fernet.generate_key())
    monkeypatch.setattr(memory.encryption, 'encrypt', lambda text, uid: cipher.encrypt(text.encode()).decode())
    monkeypatch.setattr(memory.encryption, 'decrypt', lambda text, uid: cipher.decrypt(text.encode()).decode())
    return store


def proposal(identifier='fact'):
    import hashlib
    return {'id': identifier, 'content': 'Aurora uses SQLite.', 'evidence': {
        'conversation_id': 'recording', 'content_hash': hashlib.sha256(b'Project Aurora uses SQLite.').hexdigest(),
        'quote_refs': [{'segment_id': 'line', 'quote': 'Aurora uses SQLite', 'start_ms': 5000}],
    }}


def publish(store):
    return memory.publish('owner', 'recording', store.version, [proposal()], 'extract', 'input', False)


def test_proposal_is_not_eligible_until_explicit_review_and_is_encrypted(store):
    assert publish(store)['created'] == 1
    item = memory.read('owner', 'fact')
    assert item['state'] == 'proposed' and item['eligible'] is False
    assert memory.list_page('owner', query='SQLite')['items'] == []
    assert 'SQLite' not in str(store.rows)
    memory.mutate('owner', 'fact', 'accept', item['revision'], 'accept')
    accepted = memory.list_page('owner', query='SQLite')['items']
    assert len(accepted) == 1 and accepted[0]['eligible'] is True
    assert accepted[0]['quote'] == 'Aurora uses SQLite'
    assert memory.list_page('another-owner')['items'] == []
    with pytest.raises(memory.MemoryUnavailable): memory.mutate('another-owner', 'fact', 'x', item['revision'], 'accept')


def test_duplicate_extraction_preserves_review_and_receipts_reject_reused_inputs(store):
    publish(store)
    item = memory.read('owner', 'fact')
    memory.mutate('owner', 'fact', 'reject', item['revision'], 'reject')
    assert publish(store)['created'] == 1  # Exact retry returns its original receipt.
    result = memory.publish('owner', 'recording', store.version, [proposal()], 'another', 'input', False)
    assert result == {'created': 0, 'existing': 1, 'context_limited': False}
    assert memory.read('owner', 'fact')['state'] == 'rejected'
    with pytest.raises(memory.MemoryConflict):
        memory.publish('owner', 'recording', store.version, [proposal()], 'extract', 'changed-input', False)


def test_source_correction_and_deletion_remove_confirmed_fact_from_search(store):
    publish(store)
    item = memory.read('owner', 'fact')
    memory.mutate('owner', 'fact', 'accept', item['revision'], 'accept')
    store.source['transcript_segments'][0]['text'] = 'Project Aurora now uses PostgreSQL.'
    store.version += timedelta(seconds=1)
    assert memory.list_page('owner', query='SQLite')['items'] == []
    changed = memory.read('owner', 'fact')
    assert changed['source_status'] == 'changed' and changed['quote'] is None and not changed['eligible']
    with pytest.raises(memory.MemoryConflict):
        memory.mutate('owner', 'fact', 'edit', changed['revision'], 'edit', 'Another statement')
    store.source = None
    assert memory.read('owner', 'fact')['source_status'] == 'unavailable'
    assert memory.list_page('owner', query='Aurora')['items'] == []


def test_concurrent_source_edit_conflicts_before_accepting(store, monkeypatch):
    publish(store)
    item = memory.read('owner', 'fact')
    def race(fn, *args):
        store.version += timedelta(seconds=1)
        return fn(store, *args)
    monkeypatch.setattr(memory, '_run', race)
    with pytest.raises(memory.MemoryConflict):
        memory.mutate('owner', 'fact', 'accept', item['revision'], 'accept')
    assert memory.read('owner', 'fact')['state'] == 'proposed'


def test_correction_replay_conflict_and_delete_never_resurrect_content(store):
    publish(store)
    first = memory.read('owner', 'fact')
    response = memory.mutate('owner', 'fact', 'accept', first['revision'], 'accept', 'Aurora project uses SQLite.')
    assert memory.mutate('owner', 'fact', 'accept', first['revision'], 'accept', 'Aurora project uses SQLite.') == response
    with pytest.raises(memory.MemoryConflict): memory.mutate('owner', 'fact', 'different', first['revision'], 'accept')
    current = memory.read('owner', 'fact')
    assert current['original_content'] == 'Aurora uses SQLite.'
    assert current['revisions'][0]['content'] == 'Aurora uses SQLite.'
    assert current['content'] == 'Aurora project uses SQLite.'
    memory.mutate('owner', 'fact', 'delete', current['revision'], 'delete')
    assert memory.mutate('owner', 'fact', 'accept', first['revision'], 'accept', 'Aurora project uses SQLite.') == response
    assert memory.list_page('owner')['items'] == []
    raw = store.rows[('users', 'owner', 'local_memories', 'fact')]
    assert raw['payload'] is None and 'source_id' not in raw
    memory.publish('owner', 'recording', store.version, [proposal()], 'again', 'input', False)
    with pytest.raises(memory.MemoryUnavailable): memory.read('owner', 'fact')


def test_pagination_continues_past_nonmatching_facts(store):
    memory.publish('owner', 'recording', store.version, [proposal(f'fact-{i:02}') for i in range(25)],
                   'extract', 'input', False)
    first = memory.list_page('owner', state='proposed')
    assert len(first['items']) == 20 and first['next_after'] == 'fact-19'
    second = memory.list_page('owner', state='proposed', after=first['next_after'])
    assert len(second['items']) == 5 and second['next_after'] is None
    assert memory.list_page('owner', state='proposed', source_id='recording', query='missing')['next_after'] == 'fact-19'


def test_api_extracts_proposals_and_rejects_invented_quotes(store, monkeypatch):
    import json
    from uuid import uuid4
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from routers import local_memories as api
    identifier = '00000000-0000-4000-8000-000000000001'
    store.rows[('users', 'owner', 'conversations', identifier)] = {}
    monkeypatch.setattr(memory.archive, 'recording', lambda uid, source: (store.version, deepcopy(store.source)))
    app = FastAPI()
    app.include_router(api.router)
    app.dependency_overrides[api.require_paired_owner] = lambda: 'owner'
    client = TestClient(app)
    output = {'proposals': [{'content': 'Aurora uses SQLite.', 'source': 1, 'quote': 'Aurora uses SQLite'}]}
    sent = []
    def inference(operation, body, *, timeout, size_limit):
        assert operation == 'memory-proposals'
        if body is None: return json.dumps({'provider': {'binding': 'a' * 64, 'model': 'Synthetic', 'host': 'test.invalid'}})
        sent.append(body)
        return json.dumps(output)
    monkeypatch.setattr(api, 'library_request', inference)
    path = f'/v1/local/conversations/{identifier}/memories'
    assert client.get(path).json()['provider']['model'] == 'Synthetic'
    request = {'request_id': str(uuid4()), 'provider_binding': 'a' * 64}
    created = client.post(path, json=request)
    assert created.status_code == 200 and created.json()['created'] == 1, created.text
    assert sent == [{'binding': 'a' * 64, 'sources': ['Project Aurora uses SQLite.']}]
    assert client.post(path, json=request).json() == created.json()
    assert len(sent) == 1
    proposed = client.get('/v1/local/memories?state=proposed').json()['items'][0]
    assert proposed['quote'] == 'Aurora uses SQLite' and proposed['eligible'] is False
    assert client.get('/v1/local/memories?query=SQLite').json()['items'] == []
    review = {'request_id': str(uuid4()), 'revision': proposed['revision'], 'action': 'accept'}
    assert client.post('/v1/local/memories/' + proposed['id'], json=review).status_code == 200
    assert client.get('/v1/local/memories?query=SQLite').json()['items'][0]['eligible'] is True
    output['proposals'][0]['quote'] = 'Invented quotation'
    rejected = client.post(path, json={**request, 'request_id': str(uuid4())})
    assert rejected.status_code == 502
    assert len(client.get('/v1/local/memories').json()['items']) == 1
