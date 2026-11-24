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
        '/v1/local/preview',
        '/v1/local/processing',
        '/v1/local/processing/live-tuning',
        '/v1/local/processing/save',
        '/v1/local/processing/probe',
        '/v1/local/processing/models',
        '/v1/local/processing/activate',
        '/v1/local/processing/profiles/{profile_id}',
        '/v1/users/available-languages',
        '/v1/users/daily-summaries',
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
