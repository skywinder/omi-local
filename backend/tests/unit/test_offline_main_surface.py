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
assert profile['local_conversation_group_version'] == 1

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
assert client.post(search_url, json={'query': 'привет'}).status_code == 401
db.collection.assert_not_called()
headers = {'Authorization': 'Bearer ' + key}
assert client.post(search_url, json={'query': '  '}, headers=headers).status_code == 400
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

from routers import local_tasks

suggestion_path = '/v1/local/conversations/' + documents[-1].id + '/task-suggestions'
assert client.get(suggestion_path).status_code == 401
assert client.post(suggestion_path, json={'provider_binding': 'a' * 64}).status_code == 401
suggestion_source = {'id': 'fixture-line', 'text': 'I will send the budget.', 'start': 4.25}
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

from routers import local_summary
from database import local_summary as summary_db

summary_path = '/v1/local/conversations/' + documents[-1].id + '/regenerate-summary'
assert client.get(summary_path).status_code == 401
assert client.post(summary_path, json={}).status_code == 401
raw = {'status': 'completed', 'user_title': 'Mine',
       'structured': {'title': 'Mine', 'overview': 'Previous'},
       'transcript_segments': [{'text': 'Corrected transcript.', 'start': 1}]}
reference, transaction = MagicMock(), MagicMock()
summary_db._ref = lambda *_: reference
reference.get.return_value.to_dict.return_value = raw
_, revision = summary_db.source(raw, 'fixture-owner')
publication = {'request_id': documents[0].id, 'fingerprint': 'fixture', 'model': 'fixture', 'template_name': 'fixture'}
candidate = {'title': 'Generated title', 'overview': 'New recap'}
reply = summary_db._publish.to_wrap(
    transaction, 'fixture-owner', documents[-1].id, revision, candidate, publication,
)
assert reply == publication
transaction.update.assert_called_once_with(reference, {
    'structured.overview': 'New recap', 'local_summary_publication': publication,
})
transaction.reset_mock()
raw['transcript_segments'][0]['text'] = 'New edit.'
try:
    summary_db._publish.to_wrap(transaction, 'fixture-owner', documents[-1].id, revision, candidate, publication)
    raise AssertionError('A source edit must reject the candidate')
except summary_db.SummaryChanged:
    pass
transaction.update.assert_not_called()

from routers import local_daily_recaps
from datetime import timedelta

spring = {'day': '2026-03-29', 'start': '2026-03-28T23:00:00Z', 'end': '2026-03-29T22:00:00Z'}
assert local_daily_recaps._day(local_daily_recaps.DayInput(**spring)).end - datetime(
    2026, 3, 28, 23, tzinfo=timezone.utc,
) == timedelta(hours=23)
assert client.post('/v1/local/daily-recaps/preview', json=spring).status_code == 401
invalid = {**spring, 'end': '2026-03-31T22:00:00Z'}
assert client.post('/v1/local/daily-recaps/preview', json=invalid, headers=headers).status_code == 422

from routers import local_goals

assert client.post('/v1/local/goals', json={}).status_code == 401
assert client.get('/v1/local/goals/legacy-goal').status_code == 401
assert client.post('/v1/local/goals/legacy-goal/progress', json={}).status_code == 401
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
        '/v1/health',
        '/v1/local/status',
        '/v1/local/audio/parts',
        '/v1/local/conversations/{conversation_id}/audio',
        '/v1/local/conversations/search',
        '/v1/local/conversations/chat',
        '/v1/local/conversations/{conversation_id}/chat',
        '/v1/local/conversations/{conversation_id}/edit',
        '/v1/local/folders',
        '/v1/local/folders/{folder_id}',
        '/v1/local/folders/move',
        '/v1/local/folders/reorder',
        '/v1/local/people',
        '/v1/local/action-items',
        '/v1/local/action-items/{task_id}',
        '/v1/local/conversations/{conversation_id}/task-suggestions',
        '/v1/local/conversations/{conversation_id}/regenerate-summary',
        '/v1/local/preview',
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
