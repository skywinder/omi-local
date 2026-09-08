"""Opt-in synthetic check against the running paired local Firestore emulator."""

import dataclasses
import hashlib
import json
import logging
import secrets
import tempfile
import wave
from datetime import datetime, timezone
from pathlib import Path

import main as backend_main
from fastapi import HTTPException, Response
from database import conversations as conversations_db
from database._client import get_firestore_client
from routers.conversations import get_conversation_by_id, get_conversations
from utils.env_loader import is_offline_runtime
from utils.local_transport_auth import load_pairing, local_tunnel_enabled
from utils.local_transcript import build_conversation
from utils.conversations import lifecycle
from dev_harness import config
from dev_harness.local_library import Library
from dev_harness.local_library_delete import delete_recording


def main():
    logging.disable(logging.CRITICAL)
    if not is_offline_runtime() or not local_tunnel_enabled():
        raise ValueError('Paired offline harness required')
    owner = load_pairing()['owner_uid']
    if not get_firestore_client().collection('users').document(owner).get(timeout=5).exists:
        raise ValueError('Paired owner missing')
    repo = Path(__file__).resolve().parents[2]
    cfg = config.load_config(repo, create_layout=False)
    created = None
    try:
        with tempfile.TemporaryDirectory(prefix='library-synthetic-', dir=cfg.layout.state_root) as temp:
            services = Path(temp)
            local_cfg = dataclasses.replace(cfg, layout=dataclasses.replace(cfg.layout, services_dir=services))
            folder = services / 'storage/listen-captures/synthetic'
            folder.mkdir(parents=True)
            with wave.open(str(folder / 'audio.wav'), 'wb') as wav:
                wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                wav.writeframes(b'\0\0' * 48000)
            digest = hashlib.sha256((folder / 'audio.wav').read_bytes()).hexdigest()
            key = secrets.token_hex(32)
            started = datetime.now(timezone.utc).isoformat()
            manifest = {'audio_sha256': digest, 'result_key': key, 'duration_seconds': 3,
                        'started_at': started, 'source': 'omi', 'profile': {'engine': 'whisperx'}}
            raw = {'language': 'ru', 'segments': [{'text': 'Синтетическая проверка удаления.', 'start': 0, 'end': 2}]}
            (folder / 'metadata.json').write_text(json.dumps({'status': 'completed', 'decode_errors': 0,
                                                           'started_at': started, 'source': 'omi'}))
            result = services / 'local-transcripts' / key
            result.mkdir(parents=True)
            (result / 'manifest.json').write_text(json.dumps(manifest))
            (result / 'audio.json').write_text(json.dumps(raw))
            conversation = build_conversation(raw, manifest)
            assert conversations_db.get_conversation(owner, conversation.id) is None
            created = conversation.id
            lifecycle.create_completed_conversation(owner, conversation.model_dump(), idempotent=True)
            assert get_conversation_by_id(created, source=None, include_discarded=True, uid=owner)['transcript_segments']
            def app_ids():
                return {r['id'] for r in get_conversations(response=Response(), sources=None, start_date=None,
                        end_date=None, folder_id=None, starred=None, uid=owner)}
            assert created in app_ids()
            library = Library(services)
            records = library.scan()
            assert len(records) == 1 and records[0]['status'] == 'ready'
            assert library.get(records[0]['id'])['segments']
            assert delete_recording(local_cfg, folder / 'audio.wav')['status'] == 'deleted'
            assert library.scan() == []
            assert not folder.exists() and not result.exists()
            assert created not in app_ids()
            try:
                get_conversation_by_id(created, source=None, include_discarded=True, uid=owner)
            except HTTPException as error:
                assert error.status_code == 404
            else:
                raise AssertionError('Deleted app detail still visible')
        print('{"library_delete":"passed","app_list":"passed","app_detail_404":"passed","files_removed":"passed"}')
    finally:
        if created and conversations_db.get_conversation(owner, created) is not None:
            conversations_db.delete_conversation(owner, created)


if __name__ == '__main__':
    main()
