from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


BACKEND_ROOT = Path(__file__).resolve().parents[2]
PROVIDER_KEYS = (
    'OPENAI_API_KEY',
    'DEEPGRAM_API_KEY',
    'GEMINI_API_KEY',
    'ANTHROPIC_API_KEY',
)


def test_offline_main_imports_without_provider_keys_and_registers_only_allowlist(tmp_path: Path) -> None:
    env = os.environ.copy()
    for key in PROVIDER_KEYS:
        env.pop(key, None)
    env.update(
        {
            'OMI_ENV_STAGE': 'offline',
            'PROVIDER_MODE': 'offline',
            'OMI_HARNESS_INSTANCE': 'unit-offline',
            'OMI_HARNESS_STATE_ROOT': str(tmp_path),
            'OMI_LOCAL_STORAGE_ROOT': str(tmp_path / 'services' / 'storage'),
            'FIRESTORE_EMULATOR_HOST': '127.0.0.1:8085',
            'FIREBASE_AUTH_EMULATOR_HOST': '127.0.0.1:9099',
            'FIREBASE_AUTH_PROJECT_ID': 'demo-omi-local',
            'FIREBASE_PROJECT_ID': 'demo-omi-local',
            'REDIS_DB_HOST': '127.0.0.1',
            'REDIS_DB_PORT': '6380',
            'BASE_API_URL': 'http://127.0.0.1:8000',
            'API_BASE_URL': 'http://127.0.0.1:8000',
            'PYTHONPATH': str(BACKEND_ROOT),
        }
    )
    probe = """
import json
import os
import sys
import hashlib
import uuid
import zlib
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import MagicMock

from fastapi.testclient import TestClient
import main

fixture = {'id': 'synthetic', 'deferred': True, 'transcript_segments': [{'text': 'Synthetic fixture'}]}
main.conversations._get_valid_conversation_by_id = lambda *args: fixture
def forbidden(*args, **kwargs):
    raise AssertionError('Offline detail must not enrich or dispatch first-open work')
main.conversations._enrich_deferred_conversation = forbidden
main.conversations._dispatch_first_open_work = forbidden
assert main.conversations.get_conversation_by_id('synthetic', source=None, uid='synthetic') == fixture
os.environ['OMI_LOCAL_TRANSPORT'] = 'ngrok'
os.environ.pop('OMI_LOCAL_LIVE_PREVIEW_URL', None)
main.users.get_user_profile = lambda uid: {'uid': uid}
profile = main.users.get_user_profile_endpoint(uid='synthetic')
assert profile['local_transcription']['live']['status'] == 'disabled'
assert profile['local_transcription']['final']['status'] == 'unavailable'
assert main.users.UserProfileResponse.model_validate(profile).model_dump()['local_transcription'] == profile['local_transcription']
assert profile['local_recording_edits_version'] == 1
assert profile['local_recording_archive_version'] == 1
assert profile['local_recording_categories_version'] == 1
assert profile['local_category_backfill_version'] == 1
assert profile['local_conversation_group_version'] == 1
assert profile['local_task_reminders_version'] == 1
assert profile['local_folders_version'] == 2
assert profile['local_speaker_labels_version'] == 1
assert profile['local_task_suggestions_version'] == 1
assert profile['local_archive_read_version'] == 1
assert profile['local_memories_version'] == 1
assert profile['local_daily_recaps_version'] == 1
assert profile['local_daily_recap_schedule_version'] == 1
assert profile['local_goals_version'] == 1
assert profile['local_goal_lifecycle_version'] == 1

key = 'A' * 43
pairing = Path(os.environ['OMI_HARNESS_STATE_ROOT']) / 'pairing.json'
pairing.write_text(json.dumps({'version': 1, 'owner_uid': 'fixture-owner',
                               'key_sha256': hashlib.sha256(key.encode()).hexdigest()}))
pairing.chmod(0o600)
os.environ['OMI_LOCAL_PAIRING_FILE'] = str(pairing)
db = main.conversations.conversations_db.db = MagicMock()
owner = db.collection.return_value.document.return_value
collection = owner.collection.return_value
query = collection.order_by.return_value.select.return_value
search_url = '/v1/local/conversations/search'
client = TestClient(main.app)
for path in ('/v1/local/folders', '/v1/local/people'):
    assert client.get(path).status_code == 401
    assert client.post(path, json={'name': 'A private label'}).status_code == 401

from routers import local_library_notes
from unittest.mock import patch as patch_notes
loopback = TestClient(main.app, base_url='http://127.0.0.1:8000', client=('127.0.0.1', 43100))
note_path = '/v1/local/library/note-states'
note_key = 'f' * 64
note_id = local_library_notes.conversation_id(note_key)
note_headers = {'Authorization': 'Bearer ' + key}
assert loopback.post(note_path, json={'keys': [note_key]}).status_code == 401
assert client.post(note_path, json={'keys': [note_key]}, headers=note_headers).status_code == 404
assert loopback.post(note_path, json={'keys': [note_key]}, headers={**note_headers, 'X-Forwarded-For': '127.0.0.1'}).status_code == 404
assert loopback.post(note_path, json={'keys': [note_key], 'change': {'archived': 'true'}}, headers=note_headers).status_code == 400
note_ref, note_tx, note_doc = MagicMock(), MagicMock(), MagicMock()
note_doc.id = note_id
note_doc.exists = True
note_doc.update_time.isoformat.return_value = "2026-11-26T09:00:00+00:00"
note_raw = {'status': 'completed', 'created_at': '2026-11-26T08:00:00Z', 'started_at': None, 'finished_at': None,
            'external_data': {'local_transcript': {'result_key': note_key}},
            'structured': {'category': 'education', 'emoji': '🎓'}, 'starred': True}
note_doc.to_dict.side_effect = lambda: json.loads(json.dumps(note_raw))
note_ref.get.return_value = note_doc
note_db = MagicMock()
note_owner = note_db.collection.return_value.document.return_value

def apply_note_patch(_ref, data):
    assert _ref is note_ref
    for field, value in data.items():
        if field == 'structured.category':
            note_raw['structured']['category'] = value
        else:
            note_raw[field] = value

note_tx.update.side_effect = apply_note_patch
note_db.get_all.return_value = [note_doc]
with patch_notes.object(local_library_notes._client, 'get_firestore_client', return_value=note_db), \
     patch_notes.object(local_library_notes.conversations, 'db', note_db), \
     patch_notes.object(note_owner.collection.return_value.document, 'return_value', note_ref), \
     patch_notes.object(local_library_notes.conversations, 'run_transactional',
                       lambda _db, func, *args: func.to_wrap(note_tx, *args)):
    read = loopback.post(note_path, json={'keys': [note_key]}, headers=note_headers)
    assert read.json() == {note_key: {'category': 'education', 'emoji': '🎓', 'starred': True, 'archived': False}}
    assert read.headers['cache-control'] == 'no-store'
    note_raw['structured'].update(title='Generated title', overview='Generated overview')
    note_raw['user_title'] = 'Renamed in Next'
    note_raw['local_summary_publication'] = {'model': 'Fixture model', 'request_id': 'private'}
    assert 'card' not in loopback.post(note_path, json={'keys': [note_key]}, headers=note_headers).json()[note_key]
    def projected(mode):
        return loopback.post(note_path, json={'keys': [note_key]}, headers={**note_headers, 'X-Omiloc-Card': mode})
    assert projected('titles').json()[note_key]['card'] == {'title': 'Renamed in Next'}
    assert 'structured.overview' not in note_db.get_all.call_args.kwargs['field_paths']
    assert projected('detail').json()[note_key]['transcript_revision'] == note_doc.update_time.isoformat()
    assert projected('detail').json()[note_key]['card'] == {'title': 'Renamed in Next', 'overview': 'Generated overview', 'model': 'Fixture model'}
    assert loopback.post(note_path, json={'keys': [note_key, 'b'*64]}, headers={**note_headers, 'X-Omiloc-Card':'detail'}).status_code == 400
    changed = loopback.post(note_path, json={'keys': [note_key], 'change': {'archived': True}}, headers=note_headers)
    assert changed.json()[note_key]['archived'] is True
    note_tx.update.assert_called_once_with(note_ref, {'archived': True})
    assert note_raw['starred']
    edit_url = f'/v1/local/conversations/{note_id}/edit'
    assert loopback.patch(edit_url, json={'field': 'archived', 'expected': False, 'value': False}, headers=note_headers).status_code == 409
    assert loopback.patch(edit_url, json={'field': 'archived', 'expected': False, 'value': True}, headers=note_headers).status_code == 200
    note_tx.update.assert_called_once()
    stale = loopback.post(note_path, json={'keys': [note_key], 'change': {
        'category': {'expected': 'work', 'value': 'technology'}}}, headers=note_headers)
    assert stale.status_code == 409
    assert loopback.post(note_path, json={'keys': [note_key], 'change': {
        'category': {'expected': 'education', 'value': 'technology'}}}, headers=note_headers).json()[note_key]['category'] == 'technology'
    note_raw['local_chat_deleting'] = True
    assert loopback.post(note_path, json={'keys': [note_key]}, headers=note_headers).json() == {}
    assert loopback.post(note_path, json={'keys': [note_key], 'change': {'starred': False}}, headers=note_headers).status_code == 404
    note_raw.pop('local_chat_deleting')
    note_raw['external_data']['local_transcript']['result_key'] = 'e' * 64
    assert loopback.post(note_path, json={'keys': [note_key], 'change': {'starred': False}}, headers=note_headers).status_code == 404
    assert note_tx.update.call_count == 2
    note_db.collection.return_value.document.assert_any_call('fixture-owner')

from utils import local_recording_rows
original_canonical = main.conversations.conversations_db.get_conversations_without_photos
original_local = local_recording_rows.local_recording_rows
time = datetime(2026, 1, 2, tzinfo=timezone.utc)
archive_fixture = {
    'id': '00000000-0000-4000-8000-000000000042', 'structured': {'title': 'Fixture'},
    'created_at': time, 'started_at': time, 'finished_at': time, 'status': 'completed',
}
projection_requests = []
def read_archive(uid, limit, offset, *, budget, list_fields_only, **filters):
    projection_requests.append(list_fields_only)
    assert uid == 'fixture-owner' and limit == 2
    if offset:
        budget.mark_exhausted('documents')
        return []
    return [archive_fixture]
main.conversations.conversations_db.get_conversations_without_photos = read_archive
local_recording_rows.local_recording_rows = lambda uid, origins=None: []
archive_auth = main.conversations.auth.get_current_user_uid
main.app.dependency_overrides[archive_auth] = lambda: 'fixture-owner'
archive_headers = {'Authorization': 'Bearer ' + key}
first_archive = client.get('/v1/conversations?limit=1', headers=archive_headers)
assert first_archive.status_code == 200, first_archive.text
assert first_archive.json()[0]['id'] == archive_fixture['id']
assert first_archive.headers['X-Omi-Conversation-Page-Size'] == '1'
assert first_archive.headers['X-Omi-Has-More'] == 'false'
cards = client.get('/v1/conversations?limit=1&list_fields_only=true', headers=archive_headers)
assert cards.status_code == 200 and cards.json()[0]['id'] == archive_fixture['id']
assert projection_requests == [False, True]
cut_archive = client.get('/v1/conversations?limit=1&offset=1', headers=archive_headers)
assert cut_archive.status_code == 200 and cut_archive.json() == []
assert cut_archive.headers['X-Omi-List-Truncated'] == 'true'
assert cut_archive.headers['X-Omi-Conversation-Page-Size'] == '0'
assert 'X-Omi-Has-More' not in cut_archive.headers
def read_archived(owner, limit, offset, **filters):
    assert owner == 'fixture-owner' and (limit, offset) == (2, 0) and filters['archived_only'] is True
    return [{**archive_fixture, 'archived': True}]
with patch_notes.object(main.conversations.conversations_db, 'get_conversations_without_photos', read_archived), \
     patch_notes.object(local_recording_rows, 'local_recording_rows', side_effect=AssertionError('Archived pages cannot include pending audio')):
    page = client.get('/v1/conversations?limit=1&archived_only=true', headers=archive_headers)
    assert page.status_code == 200, page.text
    assert len(page.json()) == 1 and page.json()[0]['archived'] is True
    assert page.headers['x-omi-has-more'] == 'false'
main.conversations.conversations_db.get_conversations_without_photos = original_canonical
local_recording_rows.local_recording_rows = original_local
from utils.local_transcript import build_conversation
from utils.offline_audio_capture import OfflineAudioCapture
storage = Path(os.environ['OMI_LOCAL_STORAGE_ROOT'])
capture = OfflineAudioCapture(session_id=str(uuid.uuid4()), input_codec='pcm16', source='phone', root=storage)
capture.record_decoded_frame(encoded_bytes=32000, pcm=b'\\x00\\x00' * 16000)
capture.finalize()
result_key = 'b' * 64
published = build_conversation({'segments': [{'text': 'Saved transcript', 'start': 0.1, 'end': 0.9}]}, {
    'result_key': result_key, 'audio_sha256': 'a' * 64, 'duration_seconds': 1,
    'started_at': '2026-01-02T11:00:00Z', 'source': 'phone', 'profile': {'engine': 'whisperkit'},
}).model_dump()
from fastapi import HTTPException
original_detail = main.conversations._get_valid_conversation_by_id
original_choices = main.conversations.conversations_db.get_conversations_by_id_without_photos
fixture_details = {published['id']: published}
def exact_detail(uid, id):
    if uid == 'fixture-owner' and id in fixture_details:
        return fixture_details[id]
    raise HTTPException(404, 'Conversation not found')
main.conversations._get_valid_conversation_by_id = exact_detail
def result_cards(uid, ids, *, include_discarded, field_paths):
    assert len(set(ids)) == len(ids)
    assert 'transcript_segments' not in field_paths
    return [fixture_details[id] for id in ids if uid == 'fixture-owner' and id in fixture_details]
main.conversations.conversations_db.get_conversations_by_id_without_photos = result_cards
saved_id = str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-capture:' + capture.session_id))
saved_url = '/v1/conversations/' + saved_id
resolve = '?resolve_local_recording=true'
assert client.get(saved_url + resolve, headers=archive_headers).json()['id'] == saved_id
results = pairing.parent / 'services' / 'local-transcripts'
data = {'import': 'passed', 'capture_key': hashlib.sha256(capture.session_id.encode()).hexdigest()}
for candidate in (result_key, 'c' * 64):
    (results / candidate).mkdir(parents=True)
receipt = results / result_key / 'import.json'
receipt.write_text(json.dumps(data))
assert client.get(saved_url, headers=archive_headers).status_code == 404
resolved = client.get(saved_url + resolve, headers=archive_headers)
assert resolved.status_code == 200, resolved.text
assert resolved.json()['id'] == published['id']
assert resolved.json()['transcript_segments'][0]['text'] == 'Saved transcript'
def related_result(id, *, opt_in=True):
    query = '?include_recording_results=true' if opt_in else ''
    response = client.get('/v1/conversations/' + id + query, headers=archive_headers)
    assert response.status_code == 200, response.text
    row = response.json()
    assert row['id'] == id
    return row['external_data']['local_transcript'].get('recording_results_id')

assert related_result(published['id']) is None
published['external_data']['local_transcript']['result_key'] = 'd' * 64
assert client.get(saved_url + resolve, headers=archive_headers).status_code == 404
published['external_data']['local_transcript']['result_key'] = result_key
main.app.dependency_overrides[archive_auth] = lambda: 'different-owner'
assert client.get(saved_url + resolve, headers=archive_headers).status_code == 404
main.app.dependency_overrides[archive_auth] = lambda: 'fixture-owner'
(results / ('c' * 64) / 'import.json').write_text(json.dumps(data))
assert client.get(saved_url + resolve, headers=archive_headers).status_code == 404
choices = resolve + '&include_recording_results=true'
single_verified = client.get(saved_url + choices, headers=archive_headers).json()
assert single_verified['id'] == saved_id
assert [r['id'] for r in single_verified['external_data']['local_recording']['results']] == [published['id']]
def add_result(key, capture_id, title):
    row = {**published, 'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + key)),
           'structured': {**published['structured'], 'title': title},
           'external_data': {'local_transcript': {'result_key': key}}}
    fixture_details[row['id']] = row
    (results / key).mkdir(exist_ok=True)
    (results / key / 'import.json').write_text(json.dumps({'import': 'passed',
        'capture_key': hashlib.sha256(capture_id.encode()).hexdigest()}))
    return row['id']

other = add_result('c' * 64, capture.session_id, 'Second pass')
assert related_result(published['id']) == saved_id
assert related_result(other) == saved_id
assert related_result(other, opt_in=False) is None
many = client.get(saved_url + choices, headers=archive_headers).json()
assert {r['id'] for r in many['external_data']['local_recording']['results']} == {published['id'], other}
assert all('transcript_segments' not in r for r in many['external_data']['local_recording']['results'])

group = uuid.uuid4()
group_root = storage / 'grouped-recordings' / str(group)
group_root.mkdir(parents=True)
progress = group_root / 'progress.json'
group_id = str(uuid.uuid5(group, 'waiting-for-parts'))
group_url = '/v1/conversations/' + group_id
start = '2026-01-02T11:00:00+00:00'
(group_root / 'config.json').write_text(json.dumps({'source': 'phone', 'started_at': start}))
def group_child(first):
    identifier = str(uuid.uuid5(group, f'conversation:{first}'))
    child = OfflineAudioCapture(session_id=identifier, input_codec='pcm16', source='phone', root=storage)
    child.record_decoded_frame(encoded_bytes=32000, pcm=b'\\x00\\x00' * 16000)
    child.finalize()
    metadata_path = child.session_dir / 'metadata.json'
    local_metadata = json.loads(metadata_path.read_bytes())
    local_metadata['conversation_group'] = {'recording_id': str(group), 'start_sample': first, 'end_sample': first+16000}
    metadata_path.write_text(json.dumps(local_metadata))
    return identifier

completed_child = group_child(0)
pending_child = group_child(32000)
different_capture = str(uuid.uuid4())
group_result = add_result('e' * 64, completed_child, 'First conversation from the group')
add_result('f' * 64, different_capture, 'Unrelated conversation')
def group_result_state(status, **state):
    progress.write_text(json.dumps({'next_sample': 48000, **state}))
    response = client.get(group_url + choices, headers=archive_headers)
    assert response.status_code == 200, response.text
    row = response.json()
    assert row['id'] == group_id
    local = row['external_data']['local_recording']
    assert local['status'] == status
    return {r['id'] for r in local['results']}

pending_id = str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-capture:' + pending_child))
assert group_result_state('waiting_for_parts', waiting_for_parts=True, waiting_row={
    'source': 'phone', 'started_at': start, 'duration_seconds': 3}) == {group_result, pending_id}
assert group_result_state('receiving') == {group_result, pending_id}
assert group_result_state('processing', completed=True) == {group_result, pending_id}
second_group_result = add_result('1' * 64, pending_child, 'Second conversation from the group')
assert group_result_state('published', completed=True) == {group_result, second_group_result}
assert related_result(group_result) == group_id
assert related_result(second_group_result) == group_id
assert related_result(second_group_result, opt_in=False) is None
second_key = fixture_details[second_group_result]['external_data']['local_transcript']
second_key['result_key'] = 'a'*64
second_key['recording_results_id'] = group_id  # An unverified stored link must not appear in the response.
assert related_result(second_group_result) is None
del second_key['recording_results_id']
second_key['result_key'] = '1'*64
child_metadata = storage / 'listen-captures' / pending_child / 'metadata.json'
original_metadata = child_metadata.read_text()
modified = json.loads(original_metadata)
modified['conversation_group']['start_sample'] += 1
child_metadata.write_text(json.dumps(modified))
assert related_result(second_group_result) is None  # An inconsistent boundary cannot claim unrelated audio.
child_metadata.write_text(original_metadata)
assert client.get(group_url + resolve, headers=archive_headers).status_code == 404
main.app.dependency_overrides[archive_auth] = lambda: 'different-owner'
assert client.get(group_url + choices, headers=archive_headers).status_code == 404
main.app.dependency_overrides[archive_auth] = lambda: 'fixture-owner'
main.conversations._get_valid_conversation_by_id = original_detail
main.conversations.conversations_db.get_conversations_by_id_without_photos = original_choices
del main.app.dependency_overrides[archive_auth]
assert client.post(search_url, json={'query': 'привет'}).status_code == 401
db.collection.assert_not_called()
headers = {'Authorization': 'Bearer ' + key}
assert client.post(search_url, json={'query': '  '}, headers=headers).status_code == 400
meaning_url = '/v1/local/conversations/semantic-search'
assert client.post(meaning_url, json={'query': 'привет'}).status_code == 401
assert client.post(meaning_url, json={'query': 'привет', 'after': 'page'}, headers=headers).status_code == 400
missing_model = client.post(meaning_url, json={'query': 'привет'}, headers=headers)
assert missing_model.status_code == 503 and missing_model.json()['detail'] == 'local_semantic_unavailable'
assert client.post(search_url, json={'query': 'привет', 'after': 'users/other'}, headers=headers).status_code == 400

timestamp = datetime(2026, 1, 2, tzinfo=timezone.utc)
documents = []
for i in range(1, 42):
    doc = MagicMock()
    doc.id = '00000000-0000-4000-8000-' + str(i).zfill(12)
    doc.to_dict.return_value = {'created_at': timestamp, 'is_locked': i == 1,
                                'structured': {'title': 'Запись'},
                                'transcript_segments': [{'text': 'Привет'}] if i == 1 else []}
    documents.append(doc)
documents[-1].to_dict.return_value.update({
    'user_title': 'Моя запись',
    'transcript_segments_compressed': True,
    'transcript_segments': zlib.compress(json.dumps([
        {'id': 'fixture-line', 'text': 'ПРИВЕТ из старой записи', 'start': 4.25, 'end': 6}
    ]).encode()),
})
query.limit.return_value.stream.side_effect = lambda **kwargs: iter(documents)
query.start_after.return_value.limit.return_value.stream.side_effect = lambda **kwargs: iter(documents[-1:])
first = client.post(search_url, json={'query': 'привет', 'uid': 'other'}, headers=headers)
assert first.status_code == 200, first.text
assert first.json() == {'items': [], 'next_cursor': documents[39].id}
documents[0].to_dict.assert_called_once()
assert first.headers['Cache-Control'] == 'no-store'
db.collection.return_value.document.assert_called_with('fixture-owner')
second = client.post(search_url, json={'query': 'привет', 'after': first.json()['next_cursor']}, headers=headers)
assert second.status_code == 200, second.text
hit, = second.json()['items']
assert hit['title'] == 'Моя запись'
assert hit['match_snippets'][0]['start_ms'] == 4250
assert hit['match_snippets'][0]['segment_id'] == 'fixture-line'
assert second.json()['next_cursor'] is None
collection.document.assert_called_once_with(documents[39].id)
query.start_after.assert_called_once_with({'__name__': collection.document.return_value})

# The search route must use the same grouped result and segment IDs as detail.
from utils import local_transcript
manifest = {'audio_sha256': 'c' * 64, 'result_key': 'd' * 64, 'duration_seconds': 20,
            'started_at': '2026-01-02T00:00:00Z', 'source': 'omi', 'conversation_group': {},
            'profile': {'engine': 'whisperx'}}
source = {'segments': [{'text': 'Intro', 'start': 0, 'end': 2},
                       {'text': 'A later needle', 'start': 12.5, 'end': 15}]}
folder = Path(os.environ['OMI_HARNESS_STATE_ROOT']) / 'services' / 'local-transcripts' / manifest['result_key']
folder.mkdir(parents=True)
file = folder / 'audio.json'
file.write_text(json.dumps(source))
(folder / 'manifest.json').write_text(json.dumps(manifest))
conversation = local_transcript.build_conversation(source, manifest)
threshold = local_transcript.GROUPED_INLINE_TRANSCRIPT_BYTES
local_transcript.GROUPED_INLINE_TRANSCRIPT_BYTES = 1
card = local_transcript.grouped_import_document(conversation, manifest, file)
local_transcript.GROUPED_INLINE_TRANSCRIPT_BYTES = threshold
assert len(card['transcript_segments']) == 1
grouped_doc = MagicMock()
grouped_doc.id = conversation.id
grouped_doc.to_dict.return_value = card
deleted_doc = MagicMock()
deleted_doc.id = documents[1].id
deleted_doc.to_dict.return_value = dict(card, deleted=True)
query.limit.return_value.stream.side_effect = lambda **kwargs: iter([deleted_doc, grouped_doc, documents[-1]])
reply = client.post(search_url, json={'query': 'needle'}, headers=headers)
assert reply.status_code == 200, reply.text
result, = reply.json()['items']
snippet, = result['match_snippets']
assert result['id'] == conversation.id and reply.json()['next_cursor'] == conversation.id
assert snippet['start_ms'] == 12500 and snippet['segment_id'] == conversation.transcript_segments[1].id
assert 'external_data.local_transcript' in collection.order_by.return_value.select.call_args.args[0]
following = client.post(search_url, json={'query': 'привет', 'after': conversation.id}, headers=headers)
assert following.json()['items'][0]['id'] == documents[-1].id and following.json()['next_cursor'] is None
file.write_text('{}')
assert client.post(search_url, json={'query': 'needle'}, headers=headers).status_code == 503
query.limit.return_value.stream.side_effect = lambda **kwargs: iter(documents)

from routers import local_tasks

from datetime import timedelta
from models.task_due import TaskDue

reminder_path = '/v1/local/action-items/reminders/schedule'
assert client.get(reminder_path).status_code == 401
reminder_db = local_tasks.action_items
original_rows = reminder_db.local_task_reminder_rows
reminder_db.local_task_reminder_rows = MagicMock()
fixture_date = '2034-07-13'
local_date = {'kind': 'date', 'date': fixture_date, 'timezone': 'Europe/Paris'}
instant = {'kind': 'instant', 'instant': '2034-07-13T09:45:00+04:00', 'timezone': 'Asia/Yerevan'}
day_doc, timed_doc, closed_doc = MagicMock(), MagicMock(), MagicMock()
day_doc.id, timed_doc.id, closed_doc.id = 'fixture-day', 'fixture-time', 'fixture-closed'
day_doc.to_dict.return_value = {'due': local_date, 'description': 'Day task'}
timed_doc.to_dict.return_value = {'due': instant, 'description': 'Timed task'}
closed_doc.to_dict.return_value = {'due': local_date, 'description': 'Closed task', 'completed': True}
reminder_db.local_task_reminder_rows.return_value = [day_doc, timed_doc, closed_doc]
schedule = client.get(reminder_path, headers=headers)
assert schedule.status_code == 200 and schedule.headers['Cache-Control'] == 'no-store'
assert schedule.json() == [
    {'id': 'fixture-time', 'description': 'Timed task', 'notify_at': '2034-07-13T05:45:00Z', 'exact_time': True},
    {'id': 'fixture-day', 'description': 'Day task', 'notify_at': '2034-07-13T07:00:00Z', 'exact_time': False},
]
owner, lower_bound = reminder_db.local_task_reminder_rows.call_args.args
assert owner == 'fixture-owner' and timedelta(minutes=59) < datetime.now(timezone.utc) - lower_bound < timedelta(minutes=61)
reminder_db.local_task_reminder_rows.return_value = [closed_doc] * 2001
assert client.get(reminder_path, headers=headers).status_code == 503
reminder_db.local_task_reminder_rows = original_rows

task_ref, task_tx = MagicMock(), MagicMock()
original_task_db = reminder_db.db
reminder_db.db = MagicMock()
reminder_db.db.collection.return_value.document.return_value.collection.return_value.document.return_value = task_ref
legacy = {'description': 'Legacy', 'due_at': datetime(2034, 7, 12, tzinfo=timezone.utc)}
task_ref.get.return_value.to_dict.return_value = legacy
patch = reminder_db._patch_local_task.to_wrap
assert patch(task_tx, 'fixture-owner', 'fixture-task', 'due', None, local_date)[0] == 'conflict'
task_tx.update.assert_not_called()
expected_due = TaskDue.from_task(legacy).model_dump(mode='python', exclude_none=True)
code, stored = patch(task_tx, 'fixture-owner', 'fixture-task', 'due', expected_due, local_date)
assert code == 'ok' and stored['due_at'] is None
assert stored['task_reminder_at'] == datetime(2034, 7, 13, 7, tzinfo=timezone.utc)
task_tx.update.assert_called_once()
task_ref.get.return_value.to_dict.return_value = stored
assert patch(task_tx, 'fixture-owner', 'fixture-task', 'due', expected_due, local_date)[0] == 'ok'
task_tx.update.assert_called_once()  # An acknowledged retry does not rewrite the deadline.
code, completed = patch(task_tx, 'fixture-owner', 'fixture-task', 'completed', False, True)
assert code == 'ok' and completed['task_reminder_at'] is None and completed['due'] == local_date
task_ref.get.return_value.to_dict.return_value = completed
code, reopened = patch(task_tx, 'fixture-owner', 'fixture-task', 'completed', True, False)
assert code == 'ok' and reopened['task_reminder_at'] == stored['task_reminder_at']
reminder_db.db = original_task_db

retry_path = '/v1/local/conversations/' + documents[-1].id + '/retry-processing'
assert client.post(retry_path).status_code == 401
assert client.post(retry_path, headers=headers).status_code == 404

suggestion_path = '/v1/local/conversations/' + documents[-1].id + '/task-suggestions'
assert client.get(suggestion_path).status_code == 401
assert client.post(suggestion_path, json={'provider_binding': 'a' * 64}).status_code == 401
suggestion_source = {'id': 'fixture-line', 'text': 'I will send the budget.', 'start': 4.25}
original_recording = local_tasks.local_recording_chat.recording
original_sources_current = local_tasks.local_recording_chat.sources_current
local_tasks.local_recording_chat.recording = MagicMock(return_value=('revision', {
    'transcript_segments': [suggestion_source, {'text': 'Unaddressable line.'}],
}))
local_tasks.local_recording_chat.sources_current = MagicMock(return_value=True)
local_tasks._library_request = MagicMock(return_value=json.dumps({
    'suggestions': [{'description': 'Send the budget', 'source': 1}],
}))
local_tasks.action_items.create_action_item = MagicMock(side_effect=forbidden)
prompt = {'provider_binding': 'a' * 64}
suggestions = client.post(suggestion_path, json=prompt, headers=headers)
assert suggestions.status_code == 200, suggestions.text
candidate, = suggestions.json()['suggestions']
assert candidate['segment_id'] == suggestion_source['id'] and candidate['start_ms'] == 4250
assert candidate['segment_sha256'] == hashlib.sha256(suggestion_source['text'].encode()).hexdigest()
assert suggestions.json()['context_limited']
local_tasks._library_request.assert_called_once_with({
    'binding': prompt['provider_binding'], 'sources': [suggestion_source['text']],
}, suggestions=True)
local_tasks.local_recording_chat.sources_current.return_value = False
assert client.post(suggestion_path, json=prompt, headers=headers).status_code == 409
local_tasks.action_items.create_action_item.assert_not_called()
local_tasks.local_recording_chat.recording = original_recording
local_tasks.local_recording_chat.sources_current = original_sources_current

# A grouped archive can keep the full transcript in a result file.
grouped_ref, grouped_tx = MagicMock(), MagicMock()
grouped_ref.get.return_value.to_dict.return_value = {
    'status': 'completed', 'external_data': {'local_transcript': {'segment_storage': 'result-file'}},
    'structured': {'category': 'education'}, 'transcript_segments': [{'id': 'first', 'text': 'Excerpt'}],
}
grouped_db = main.conversations.conversations_db
old_db = grouped_db.db
grouped_db.db = MagicMock()
grouped_db.db.collection.return_value.document.return_value.collection.return_value.document.return_value = grouped_ref
for field in ('speaker', 'segment_text'):
    assert grouped_db._patch_local_recording.to_wrap(grouped_tx, 'fixture-owner', 'stored', field, '', '', None)[0] == 'transcript_unavailable'
grouped_tx.update.assert_not_called()
outcome, _ = grouped_db._patch_local_recording.to_wrap(grouped_tx, 'fixture-owner', 'stored', 'category', 'education', 'work', None)
assert outcome == 'ok'
grouped_tx.update.assert_called_once_with(grouped_ref, {'user_category': 'work', 'structured.category': 'work'})
grouped_tx.reset_mock()

# Exercise paired PATCH on the later segment of the checked file, which the stored preview omits.
from database import local_summary as grouped_summaries
from google.cloud import firestore as grouped_firestore
fixture_uid = 'fixture-owner'
file.write_text(json.dumps(source))
original_bytes = file.read_bytes()
persisted = grouped_db.encode_conversation_for_write(fixture_uid, card, 'enhanced')
persisted['data_protection_level'] = 'enhanced'
grouped_ref.get.return_value.to_dict.return_value = persisted
preview = persisted['transcript_segments']
original_revision = grouped_summaries.source(persisted, fixture_uid, background=True).revision

def apply_grouped_patch(ref, patch):
    assert ref is grouped_ref
    for key, value in patch.items():
        if value is grouped_firestore.DELETE_FIELD:
            persisted.pop(key, None)
        else:
            persisted[key] = value

grouped_tx.update.side_effect = apply_grouped_patch
original_patch = grouped_db.patch_local_recording
grouped_db.patch_local_recording = lambda *args: grouped_db._patch_local_recording.to_wrap(grouped_tx, *args)
later = conversation.transcript_segments[1]
path = '/v1/local/conversations/' + conversation.id + '/edit'
digest = lambda value: hashlib.sha256(value.encode()).hexdigest()
edit = {'field': 'segment_text', 'segment_id': later.id, 'expected': digest(later.text), 'value': 'Corrected late-marker.'}
budget = local_transcript.GROUPED_TRANSCRIPT_EDIT_BYTES
local_transcript.GROUPED_TRANSCRIPT_EDIT_BYTES = 1
limit = client.patch(path, json=edit, headers=headers)
assert limit.status_code == 413 and limit.json()['detail'] == 'local_recording_transcript_edit_limit'
grouped_tx.update.assert_not_called()
local_transcript.GROUPED_TRANSCRIPT_EDIT_BYTES = budget
result = client.patch(path, json=edit, headers=headers)
assert result.status_code == 200, result.text
assert result.json()['conversation']['transcript_segments'][1]['id'] == later.id
assert result.json()['conversation']['transcript_segments'][1]['text'] == edit['value']
assert 'local_transcript_edits' not in result.json()['conversation']
assert edit['value'] not in persisted['local_transcript_edits']
assert persisted['transcript_segments'] == preview and file.read_bytes() == original_bytes
revision = grouped_summaries.source(persisted, fixture_uid, background=True)
assert revision.revision != original_revision and edit['value'] in revision.transcript
assert client.patch(path, json=edit, headers=headers).status_code == 200
assert grouped_tx.update.call_count == 1
assert client.patch(path, json={**edit, 'value': 'Stale overwrite.'}, headers=headers).status_code == 409

speaker_before = {'person_id': None, 'is_user': False}
speaker_after = {'person_id': None, 'is_user': True}
label = {'field': 'speaker', 'expected': {later.id: speaker_before}, 'value': speaker_after}
reply = client.patch(path, json=label, headers=headers)
assert reply.status_code == 200, reply.text
assert reply.json()['conversation']['transcript_segments'][1]['is_user'] is True
assert reply.json()['conversation']['transcript_segments'][1]['text'] == edit['value']
assert persisted['transcript_segments'] == preview

grouped_db.db = old_db
grouped_doc.to_dict.return_value = persisted
query.limit.return_value.stream.side_effect = lambda **kwargs: iter([grouped_doc])
reply = client.post(search_url, json={'query': 'late-marker'}, headers=headers)
assert reply.status_code == 200, reply.text
match, = reply.json()['items'][0]['match_snippets']
assert match['segment_id'] == later.id and match['start_ms'] == 12500
assert client.post(search_url, json={'query': 'needle'}, headers=headers).json()['items'] == []

# Both chat scopes must ground citations in the checked full transcript and its edits.
from routers import local_recording_chat as paired_chat
from contextlib import ExitStack
from unittest.mock import patch as replace_for_chat

search_snapshots = old_db.get_all.return_value
old_db.get_all.return_value = [grouped_doc]
archive_chat = '/v1/local/conversations/chat'
recording_chat = '/v1/local/conversations/' + conversation.id + '/chat'
question = {'id': str(uuid.uuid4()), 'provider_binding': 'b' * 64, 'question': 'late-marker'}
assert client.post(archive_chat, json=question).status_code == 401

def reply_from_edited_source(payload, *, archive):
    assert payload['question'] == question['question']
    index = payload['sources'].index(edit['value']) + 1
    return json.dumps({'answer': 'Found the corrected line.', 'sources': [index]})

def record_turn(uid, conversation_id, request_id, previous, revision, payload):
    assert uid == fixture_uid and conversation_id == conversation.id and previous is None
    assert revision == grouped_doc.update_time
    return {**payload, 'id': request_id, 'sequence': 1, 'created_at': datetime.now(timezone.utc)}

def suggest_from_edited_source(payload, *, suggestions):
    assert suggestions
    index = payload['sources'].index(edit['value']) + 1
    return json.dumps({'suggestions': [{'description': 'Follow up on the correction', 'source': index}]})

with ExitStack() as stack:
    def replace(name, **kwargs):
        return stack.enter_context(replace_for_chat.object(paired_chat.chat_db, name, **kwargs))

    provider = stack.enter_context(replace_for_chat.object(paired_chat, '_library_request', side_effect=reply_from_edited_source))
    replace('sources_current', return_value=True)
    replace('turn', return_value=None)
    replace('history', return_value=([], None))
    replace('publish', side_effect=record_turn)
    suggestion_model = stack.enter_context(replace_for_chat.object(local_tasks, '_library_request',
                                                                  side_effect=suggest_from_edited_source))
    for chat_path in (archive_chat, recording_chat):
        chat_reply = client.post(chat_path, json=question, headers=headers)
        assert chat_reply.status_code == 200, chat_reply.text
        reference, = chat_reply.json()['evidence_references']
        assert reference['conversation_id'] == conversation.id and reference['segment_id'] == later.id
        assert reference['start_ms'] == 12500 and reference['summary'] == edit['value']
    task_path = recording_chat.removesuffix('/chat') + '/task-suggestions'
    task_reply = client.post(task_path, json=prompt, headers=headers)
    assert task_reply.status_code == 200, task_reply.text
    task_suggestion, = task_reply.json()['suggestions']
    assert task_suggestion['segment_id'] == later.id and task_suggestion['segment_sha256'] == digest(edit['value'])
    assert provider.call_count == 2
    file.write_text('{}')
    assert client.post(archive_chat, json=question, headers=headers).json()['detail'] == 'archive_chat_scan_limited'
    assert client.post(recording_chat, json=question, headers=headers).status_code == 404
    assert client.post(task_path, json=prompt, headers=headers).status_code == 404
    assert provider.call_count == 2
    suggestion_model.assert_called_once()
    file.write_bytes(original_bytes)

# A meaning-only question can reach the checked correction without exposing stale or low-score pointers.
from utils.conversations.semantic_passages import passages as indexed_passages, source_revision
checked = local_transcript.hydrate_grouped_transcript(grouped_db._prepare_conversation_for_read(persisted, fixture_uid),
                                                   local_transcript.local_transcript_root(), fixture_uid)
position = next(i for i, passage in enumerate(indexed_passages(checked))
                if passage.snippet and passage.snippet['segment_id'] == later.id)
saved_version = grouped_doc.update_time
grouped_doc.update_time = datetime(2026, 1, 1, tzinfo=timezone.utc)
hit = {'id': conversation.id, 'score': .84, 'position': position, 'revision': source_revision(grouped_doc.update_time)}
meaning_question = {**question, 'question': 'Где нашли подтверждение?',
                    'history': [{'question': 'Относительно договора', 'answer': 'Продолжаем.'}]}
def paraphrase_reply(payload, *, archive):
    assert archive and payload['sources'] == [edit['value']]
    return json.dumps({'answer': 'Found through the semantic index.', 'sources': [1]})

with ExitStack() as stack:
    rank = stack.enter_context(replace_for_chat.object(paired_chat.local_semantic_search, 'rank', return_value=[hit]))
    receiver = stack.enter_context(replace_for_chat.object(paired_chat, '_library_request', side_effect=paraphrase_reply))
    revisions = stack.enter_context(replace_for_chat.object(paired_chat.chat_db, 'sources_current', return_value=True))
    result = client.post(archive_chat, json=meaning_question, headers=headers)
    assert result.status_code == 200, result.text
    source, = result.json()['evidence_references']
    assert source['segment_id'] == later.id and source['summary'] == edit['value']
    rank.assert_called_once_with(fixture_uid, 'Где нашли подтверждение?\\nОтносительно договора')
    for unsafe in ({**hit, 'revision': 'stale'}, {**hit, 'score': .72}):
        rank.return_value = [unsafe]
        assert client.post(archive_chat, json=meaning_question, headers=headers).status_code == 422
    receiver.assert_called_once()
    rank.return_value = [hit]
    revisions.side_effect = [True, False]
    assert client.post(archive_chat, json=meaning_question, headers=headers).status_code == 409

# Archive history is opt-in on the wire and follows the server's head across devices.
prior_id = str(uuid.uuid4())
prior_source = documents[-1].id
prior_turn = {'id': prior_id, 'sequence': 2, 'created_at': datetime.now(timezone.utc), 'question': 'First question',
              'answer': 'Server context', 'source_ids': [prior_source], 'evidence_references': [], 'context_limited': False}
def saved_reply(body, *, archive):
    assert archive and body['history'] == [{'question': 'First question', 'answer': 'Server context'}]
    return json.dumps({'answer': 'Saved answer.', 'sources': [body['sources'].index(edit['value'])+1]})

def save_archive(uid, request_id, previous, revisions, payload, *, thread_id=None):
    assert uid == fixture_uid and previous == prior_id and revisions == {conversation.id: grouped_doc.update_time}
    assert set(payload['source_ids']) == {prior_source, conversation.id}
    return {**payload, 'id': request_id, 'sequence': 3, 'created_at': datetime.now(timezone.utc)}

with ExitStack() as stack:
    pages = stack.enter_context(replace_for_chat.object(paired_chat.chat_db, 'archive_history', return_value=([prior_turn], 2)))
    lookup = stack.enter_context(replace_for_chat.object(paired_chat.chat_db, 'archive_turn', return_value=None))
    store = stack.enter_context(replace_for_chat.object(paired_chat.chat_db, 'publish_archive', side_effect=save_archive))
    stack.enter_context(replace_for_chat.object(paired_chat.chat_db, 'sources_current', return_value=True))
    available = stack.enter_context(replace_for_chat.object(paired_chat.chat_db, 'archive_sources_available', return_value=True))
    stack.enter_context(replace_for_chat.object(paired_chat, '_chat_provider', return_value=None))
    receiver = stack.enter_context(replace_for_chat.object(paired_chat, '_library_request', side_effect=saved_reply))
    assert client.get(archive_chat, params={'stored': 'true'}).status_code == 401
    legacy = client.get(archive_chat, headers=headers).json()
    assert not legacy['stored_history'] and not legacy['turns']
    pages.assert_not_called()
    saved = client.get(archive_chat, headers=headers, params={'stored': 'true', 'before': 4})
    assert saved.headers['Cache-Control'] == 'no-store'
    assert saved.json()['stored_history'] and saved.json()['turns'][0]['id'] == prior_id
    assert saved.json()['archive_threads'] is True
    pages.assert_called_once_with(fixture_uid, before=4, thread_id=None)
    stored_request = {**question, 'store': True, 'previous': prior_id}
    assert client.post(archive_chat, headers=headers, json={**stored_request, 'previous': None}).status_code == 409
    assert client.post(archive_chat, headers=headers, json={**stored_request, 'history': [{'question':'fake', 'answer':'fake'}]}).status_code == 400
    available.return_value = False
    assert client.post(archive_chat, headers=headers, json=stored_request).status_code == 409
    receiver.assert_not_called()
    available.return_value = True
    actual = client.post(archive_chat, headers=headers, json=stored_request)
    assert actual.status_code == 200 and actual.json()['sequence'] == 3
    assert 'source_ids' not in actual.json()
    lookup.return_value = actual.json()
    assert client.post(archive_chat, headers=headers, json=stored_request).json() == actual.json()
    assert client.post(archive_chat, headers=headers, json={**stored_request, 'question': 'Another'}).status_code == 409
    receiver.assert_called_once()
    store.assert_called_once()

    threads = archive_chat + '/threads'
    thread_id = str(uuid.uuid4())
    thread_path = threads + '/' + thread_id
    assert client.get(threads).status_code == 401
    assert client.post(threads, json={'id': thread_id, 'title': 'Private'}).status_code == 401
    assert client.delete(thread_path).status_code == 401
    assert client.delete(threads + '/not-a-thread', headers=headers).status_code == 503
    assert client.post(threads, headers=headers, json={'id': thread_id, 'title': '  '}).status_code == 400
    thread_label = {'id': thread_id, 'title': 'Named archive chat', 'created_at': prior_turn['created_at']}
    create = stack.enter_context(replace_for_chat.object(paired_chat.chat_db, 'create_archive_thread', return_value=thread_label))
    thread_reply = client.post(threads, headers=headers, json={'id': thread_id, 'title': ' Named archive chat '})
    assert thread_reply.status_code == 201 and thread_reply.json()['title'] == thread_label['title']
    create.assert_called_once_with(fixture_uid, thread_id, thread_label['title'])
    listed = stack.enter_context(replace_for_chat.object(paired_chat.chat_db, 'archive_threads', return_value=[thread_label]))
    assert client.get(threads, headers=headers).json() == [thread_reply.json()]
    listed.assert_called_once_with(fixture_uid)
    assert client.get(thread_path, headers=headers).json()['turns'][0]['id'] == prior_id
    pages.assert_called_with(fixture_uid, before=None, thread_id=thread_id)
    lookup.return_value = None
    separate = {**stored_request, 'id': str(uuid.uuid4())}
    assert client.post(thread_path, headers=headers, json=separate).status_code == 200
    lookup.assert_called_with(fixture_uid, separate['id'], thread_id=thread_id)
    assert store.call_args.kwargs['thread_id'] == thread_id
    remove = stack.enter_context(replace_for_chat.object(paired_chat.chat_db, 'delete_archive_thread'))
    assert client.delete(thread_path, headers=headers).status_code == 204
    remove.assert_called_once_with(fixture_uid, thread_id)
    pages.side_effect = paired_chat.chat_db.ArchiveThreadUnavailable
    lookup.side_effect = paired_chat.chat_db.ArchiveThreadUnavailable
    assert client.get(thread_path, headers=headers).status_code == 404
    assert client.post(thread_path, headers=headers, json=separate).status_code == 404

grouped_doc.update_time = saved_version
old_db.get_all.return_value = search_snapshots
query.limit.return_value.stream.side_effect = lambda **kwargs: iter(documents)

grouped_db.db = MagicMock()
grouped_db.db.collection.return_value.document.return_value.collection.return_value.document.return_value = grouped_ref
restore = {**edit, 'expected': digest(edit['value']), 'value': later.text}
assert client.patch(path, json=restore, headers=headers).status_code == 200
assert client.patch(path, json={**label, 'expected': {later.id: speaker_after}, 'value': speaker_before},
                    headers=headers).status_code == 200
assert 'local_transcript_edits' not in persisted and file.read_bytes() == original_bytes
first_line = conversation.transcript_segments[0]
preview_edit = {'field': 'segment_text', 'segment_id': first_line.id, 'expected': digest(first_line.text),
                'value': 'Corrected preview ' * 30}
assert client.patch(path, json=preview_edit, headers=headers).status_code == 200
preview_rows = grouped_db._prepare_conversation_for_read(persisted, fixture_uid)['transcript_segments']
assert len(preview_rows) == 1 and preview_rows[0]['text'] == preview_edit['value'][:180]
assert file.read_bytes() == original_bytes
file.write_text('{}')
corrupt = client.patch(path, json=edit, headers=headers)
assert corrupt.status_code == 503 and corrupt.json()['detail'] == 'local_recording_transcript_unavailable'
file.write_bytes(original_bytes)
grouped_db.patch_local_recording = original_patch
grouped_db.db = old_db

from routers import local_summary
from database import local_summary as summary_db
from models.conversation_enums import CategoryEnum

category_path = '/v1/local/conversations/classify-categories'
category_ids = [str(uuid.uuid4()) for _ in range(3)]
category_prompt = {'recording_ids': category_ids, 'provider_binding': 'a' * 64}
assert client.get(category_path).status_code == 401
assert client.post(category_path, json=category_prompt).status_code == 401
with ExitStack() as categories:
    read = categories.enter_context(replace_for_chat.object(summary_db, 'category_input', side_effect=[
        ('pending','Saved synopsis about a software compiler.','current-a'),
        ('already_classified',None,None), ('pending','Saved synopsis about a hiking trip.','current-b'),
    ]))
    publish_category = categories.enter_context(replace_for_chat.object(summary_db, 'publish_category',
                                                                       side_effect=['updated','changed']))
    provider = categories.enter_context(replace_for_chat.object(local_summary, '_category_request', return_value=json.dumps({
        'items': [{'number':2,'category':'travel'}, {'number':1,'category':'technology'}],
    })))
    duplicates = client.post(category_path,headers=headers,json={**category_prompt,'recording_ids':[category_ids[0]]*2})
    assert duplicates.status_code == 400
    read.assert_not_called()
    category_result = client.post(category_path, headers=headers, json=category_prompt)
    assert category_result.status_code == 200, category_result.text
    assert [row['state'] for row in category_result.json()] == ['updated','already_classified','changed']
    assert [row['id'] for row in category_result.json()] == category_ids
    assert category_result.headers['cache-control'] == 'no-store'
    assert [item['text'] for item in provider.call_args.args[0]['excerpts']] == [
        'Saved synopsis about a software compiler.', 'Saved synopsis about a hiking trip.',
    ]
    assert all(identifier not in json.dumps(provider.call_args.args) for identifier in category_ids)
    assert publish_category.call_args_list[0].args == (fixture_uid,category_ids[0],'current-a',CategoryEnum.technology)
    publish_category.reset_mock()
    read.side_effect = [('pending','Available excerpt','rev')]
    provider.return_value = json.dumps({'items':[]})
    malformed_category = client.post(category_path, headers=headers, json={**category_prompt,'recording_ids':category_ids[:1]})
    assert malformed_category.status_code == 502
    publish_category.assert_not_called()

classification_ref, classification_tx = MagicMock(), MagicMock()
classification_doc = classification_ref.get.return_value
classification_doc.update_time = 'fresh'
classification_raw = {'status':'completed','user_title':'My title','starred':True,'structured':{
    'title':'Model title','overview':'Saved analysis of compilers.','category':'other','emoji':'💾','sections':[{'heading':'Notes'}],
}}
classification_doc.to_dict.return_value = classification_raw
with replace_for_chat.object(summary_db, '_ref', return_value=classification_ref):
    status, excerpt, revision = summary_db.category_input(fixture_uid, category_ids[0])
    assert (status, excerpt, revision) == ('pending','My title\\nSaved analysis of compilers.','fresh')
    publish = summary_db._publish_category.to_wrap
    assert publish(classification_tx,fixture_uid,category_ids[0],'fresh',CategoryEnum.other) == 'unclassified'
    assert publish(classification_tx,fixture_uid,category_ids[0],'old',CategoryEnum.technology) == 'changed'
    classification_raw['user_category'] = 'other'
    assert publish(classification_tx,fixture_uid,category_ids[0],'fresh',CategoryEnum.technology) == 'already_classified'
    classification_tx.update.assert_not_called()
    del classification_raw['user_category']
    assert publish(classification_tx,fixture_uid,category_ids[0],'fresh',CategoryEnum.technology) == 'updated'
    classification_tx.update.assert_called_once_with(classification_ref,{'structured.category':'technology'})

summary_path = '/v1/local/conversations/' + documents[-1].id + '/regenerate-summary'
assert client.get(summary_path).status_code == 401
assert client.post(summary_path, json={}).status_code == 401
queue_path = summary_path.replace('/regenerate-summary', '/summary-jobs')
assert client.get(queue_path).status_code == 401
assert client.post(queue_path, json={}).status_code == 401
raw = {'status': 'completed', 'user_title': 'Mine',
       'structured': {'title': 'Mine', 'overview': 'Previous', 'sections': [
           {'heading': 'Previous', 'body_markdown': 'Stale source.', 'source_segment_ids': ['line']},
       ]},
       'transcript_segments': [{'id': 'line', 'text': 'Corrected transcript.', 'start': 1}]}
reference, transaction = MagicMock(), MagicMock()
summary_db._ref = lambda *_: reference
reference.get.return_value.to_dict.return_value = raw
snapshot = summary_db.source(raw, 'fixture-owner')
assert snapshot.transcript == '[src:1] [1.0] Corrected transcript.'
long = {'status': 'completed', 'transcript_segments': [{'id': 'long', 'text': 'a' * 125000, 'start': 0}]}
assert len(summary_db.source(long, 'fixture-owner', background=True).transcript) > 120000
try:
    summary_db.source(long, 'fixture-owner')
    raise AssertionError('The synchronous route has a smaller input budget')
except summary_db.SummaryTooLarge:
    pass
assert summary_db.published_provenance(raw) is None
raw['external_data'] = {'local_transcript': {'stages': {'summary': {
    'status': 'ready', 'model': 'Initial actual model', 'template_name': 'Initial template', 'prompt': 'private',
}}}}
assert summary_db.published_provenance(raw) == {'model': 'Initial actual model', 'template_name': 'Initial template'}
raw['local_summary_publication'] = {'model': 'Published actual model', 'template_name': 'Saved template',
                                    'fingerprint': 'private', 'prompt': 'private'}
assert summary_db.published_provenance(raw) == {'model': 'Published actual model', 'template_name': 'Saved template'}
del raw['local_summary_publication']
revision = snapshot.revision
publication = {'request_id': documents[0].id, 'fingerprint': 'fixture', 'model': 'fixture', 'template_name': 'fixture'}
candidate = {'title': 'Generated title', 'overview': 'New recap', 'category': 'education', 'emoji': '📚'}
reply = summary_db._publish.to_wrap(
    transaction, 'fixture-owner', documents[-1].id, revision, candidate, publication,
)
assert reply == publication
transaction.update.assert_called_once_with(reference, {
    'structured.overview': 'New recap', 'structured.category': 'education', 'structured.emoji': '📚',
    'structured.sections': [],
    'local_summary_publication': publication,
})
transaction.reset_mock()
raw['user_category'] = 'family'
rich = {**candidate, 'sections': [
    {'heading': 'Decision', 'body_markdown': 'We chose the API. ![img](https://untrusted.example/)', 'source_refs': [1, 999]},
]}
summary_db._publish.to_wrap(transaction, 'fixture-owner', documents[-1].id, revision, rich, publication)
assert 'structured.category' not in transaction.update.call_args.args[1]
assert transaction.update.call_args.args[1]['structured.emoji'] == '📚'
section, = transaction.update.call_args.args[1]['structured.sections']
assert section['source_segment_ids'] == ['line']
assert '!' + chr(92) + '[img]' in section['body_markdown']
assert transaction.update.call_args.args[1]['structured.overview'] == '## Decision' + chr(10) * 2 + section['body_markdown']
transaction.reset_mock()
raw['transcript_segments'][0]['text'] = 'New edit.'
try:
    summary_db._publish.to_wrap(transaction, 'fixture-owner', documents[-1].id, revision, candidate, publication)
    raise AssertionError('A source edit must reject the candidate')
except summary_db.SummaryChanged:
    pass
transaction.update.assert_not_called()

assert client.get('/v1/local/memories').status_code == 401
assert client.post('/v1/local/memories/00000000-0000-4000-8000-000000000001', json={}).status_code == 401
assert client.post('/v1/local/conversations/00000000-0000-4000-8000-000000000001/memories', json={}).status_code == 401

from routers import local_daily_recaps
from datetime import timedelta

spring = {'day': '2026-03-29', 'start': '2026-03-28T23:00:00Z', 'end': '2026-03-29T22:00:00Z'}
assert local_daily_recaps._day(local_daily_recaps.DayInput(**spring)).end - datetime(
    2026, 3, 28, 23, tzinfo=timezone.utc,
) == timedelta(hours=23)
assert client.get('/v1/local/daily-recaps/schedule').status_code == 401
assert client.post('/v1/local/daily-recaps/schedule', json={}).status_code == 401
assert client.post('/v1/local/daily-recaps/preview', json=spring).status_code == 401
assert client.post('/v1/local/daily-recaps/generate', json={}).status_code == 401
invalid = {**spring, 'end': '2026-03-31T22:00:00Z'}
assert client.post('/v1/local/daily-recaps/preview', json=invalid, headers=headers).status_code == 422

# Exercise the authenticated API and real scheduler/publication with synthetic
# sources, controlled clock and in-memory transaction storage (no live models).
def exercise_recap_schedule():
    from copy import deepcopy
    from types import SimpleNamespace
    from unittest.mock import patch
    from database import local_daily_recaps as recap_db, local_recap_schedule as schedule_db
    from utils import local_recap_scheduler as runner
    store = {}
    instant = [datetime(2026, 3, 28, 12, tzinfo=timezone.utc)]
    class Ref:
        def __init__(self, key): self.key = key
        def get(self, **kwargs):
            return SimpleNamespace(to_dict=lambda: deepcopy(store.get(self.key)))
    class Tx:
        def set(self, ref, value): store[ref.key] = deepcopy(value)
    def transaction(db, fn, *args): return fn.to_wrap(Tx(), *args)
    def documents(*args):
        return [('source', ({'status': 'completed', 'structured': {'overview': 'An explicit decision.'}},
                            instant[0], 'revision'))], False
    provider = {'provider': {'binding': 'a' * 64, 'model': 'Synthetic', 'host': 'fixture.invalid'}}
    model_calls = []
    stopping = [False]
    def request(body=None):
        if body is None: return json.dumps(provider)
        assert body['binding'] == 'a' * 64
        model_calls.append(body)
        if len(model_calls) == 2: stopping[0] = True
        return json.dumps({'headline': 'Day recap', 'overview': 'An explicit decision.',
                           'decisions': [{'decision': 'An explicit decision.', 'source': 1}]})
    with patch.object(schedule_db, '_ref', lambda uid: Ref('schedule')), \
         patch.object(schedule_db, 'now', lambda: instant[0]), \
         patch.object(schedule_db, 'run_transactional', transaction), \
         patch.object(recap_db, '_recap', lambda uid, day: Ref(day.id)), \
         patch.object(recap_db, '_documents', documents), \
         patch.object(recap_db, 'run_transactional', transaction), \
         patch.object(local_daily_recaps, '_request', request):
        initial = client.get('/v1/local/daily-recaps/schedule', headers=headers)
        assert initial.status_code == 200 and initial.json()['enabled'] is False
        assert initial.headers['cache-control'] == 'no-store'
        body = {'request_id': str(uuid.uuid4()), 'revision': '', 'enabled': True,
                'timezone': 'Europe/Berlin', 'hour': 9, 'minute': 0, 'provider_binding': 'a' * 64}
        assert client.post('/v1/local/daily-recaps/schedule', headers=headers,
                           json={**body, 'timezone': 'not/a-zone'}).status_code == 422
        assert client.post('/v1/local/daily-recaps/schedule', headers=headers,
                           json={**body, 'provider_binding': 'b' * 64}).status_code == 409
        saved = client.post('/v1/local/daily-recaps/schedule', headers=headers, json=body)
        assert saved.status_code == 200, saved.text
        assert saved.json()['next_day'] == '2026-03-28'
        assert 'lease' not in saved.json() and 'request_body' not in saved.json()
        assert client.post('/v1/local/daily-recaps/schedule', headers=headers, json=body).json() == saved.json()
        runner.tick()
        assert not model_calls
        instant[0] = datetime(2026, 3, 29, 7, tzinfo=timezone.utc)
        runner.tick()
        assert len(model_calls) == 1
        assert store['local-2026-03-28']['decisions_made'][0]['conversation_id'] == 'source'
        assert store['schedule']['status'] == 'ready'
        runner.tick()
        assert len(model_calls) == 1
        instant[0] += timedelta(days=1)
        runner.tick(lambda: stopping[0])
        assert len(model_calls) == 2
        assert 'local-2026-03-29' not in store
        assert store['schedule']['status'] == 'changed'
        # Disable using the revision that was returned before the worker ran.
        disabled = {**body, 'revision': saved.json()['revision'], 'request_id': str(uuid.uuid4()), 'enabled': False}
        assert client.post('/v1/local/daily-recaps/schedule', headers=headers, json=disabled).status_code == 200
        instant[0] += timedelta(days=1)
        runner.tick()
        assert len(model_calls) == 2
exercise_recap_schedule()

from routers import local_goals

assert client.post('/v1/local/goals', json={}).status_code == 401
assert client.get('/v1/local/goals/legacy-goal').status_code == 401
assert client.post('/v1/local/goals/legacy-goal/progress', json={}).status_code == 401
lifecycle = '/v1/local/goals/legacy-goal/lifecycle'
assert client.post(lifecycle, json={}).status_code == 401
assert client.post(lifecycle, headers=headers, json={
    'request_id': documents[0].id, 'expected_revision': 'old', 'status': 'focused',
}).status_code == 422

assert client.post('/v1/local/goals', headers=headers, json={
    'request_id': documents[0].id, 'title': 'Fixture', 'current': 2,
}).status_code == 422
assert client.post('/v1/local/goals/legacy-goal/progress', headers=headers, json={
    'request_id': documents[0].id, 'expected_revision': 'old', 'note': '   ',
}).status_code == 422

forbidden_modules = (
    'routers.chat', 'routers.firmware', 'routers.updates', 'routers.oauth',
    'routers.payment', 'routers.stt', 'routers.tts', 'routers.desktop_realtime',
)
print(json.dumps({
    'egress_guard': main._OFFLINE_EGRESS_POLICY is not None,
    'paths': sorted({route.path for route in main.app.routes}),
    'provider_keys': sorted(key for key in %r if os.environ.get(key)),
    'forbidden_modules': sorted(name for name in forbidden_modules if name in sys.modules),
}))
""" % (PROVIDER_KEYS,)

    result = subprocess.run(
        [sys.executable, '-c', probe],
        cwd=BACKEND_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)

    assert payload['egress_guard'] is True
    assert payload['provider_keys'] == []
    assert payload['forbidden_modules'] == []
    assert set(payload['paths']) == {
        '/openapi.json',
        '/v1/account/cutover/control',
        '/v1/action-items',
        '/v1/conversations',
        '/v1/conversations/{conversation_id}',
        '/v1/goals/all',
        '/v1/local/goals',
        '/v1/local/goals/{goal_id}',
        '/v1/local/goals/{goal_id}/progress',
        '/v1/local/goals/{goal_id}/lifecycle',
        '/v1/health',
        '/v1/local/status',
        '/v1/local/audio/parts',
        '/v1/local/conversations/{conversation_id}/audio',
        '/v1/local/conversations/search',
        '/v1/local/conversations/classify-categories',
        '/v1/local/conversations/semantic-search',
        '/v1/local/conversations/chat',
        '/v1/local/conversations/chat/threads',
        '/v1/local/conversations/chat/threads/{thread_id}',
        '/v1/local/conversations/{conversation_id}/chat',
        '/v1/local/conversations/{conversation_id}/edit',
        '/v1/local/folders',
        '/v1/local/folders/{folder_id}',
        '/v1/local/folders/move',
        '/v1/local/folders/reorder',
        '/v1/local/people',
        '/v1/local/action-items',
        '/v1/local/action-items/reminders/schedule',
        '/v1/local/action-items/{task_id}',
        '/v1/local/archive/recordings',
        '/v1/local/archive/read',
        '/v1/local/memories',
        '/v1/local/memories/{memory_id}',
        '/v1/local/conversations/{conversation_id}/memories',
        '/v1/local/conversations/{conversation_id}/task-suggestions',
        '/v1/local/conversations/{conversation_id}/regenerate-summary',
        '/v1/local/conversations/{conversation_id}/summary-jobs',
        '/v1/local/conversations/{conversation_id}/retry-processing',
        '/v1/local/preview',
        '/v1/local/library/note-states',
        '/v1/local/processing',
        '/v1/local/processing/live-tuning',
        '/v1/local/processing/summary-settings',
        '/v1/local/processing/save',
        '/v1/local/processing/probe',
        '/v1/local/processing/models',
        '/v1/local/processing/activate',
        '/v1/local/processing/profiles/{profile_id}',
        '/v1/users/available-languages',
        '/v1/users/daily-summaries',
        '/v1/local/daily-recaps/schedule',
        '/v1/local/daily-recaps/preview',
        '/v1/local/daily-recaps/generate',
        '/v1/users/language',
        '/v1/users/me/subscription',
        '/v1/users/onboarding',
        '/v1/users/people',
        '/v1/users/private-cloud-sync',
        '/v1/users/profile',
        '/v1/users/training-data-opt-in',
        '/v1/users/transcription-preferences',
        '/v3/speech-profile',
        '/v4/listen',
    }
