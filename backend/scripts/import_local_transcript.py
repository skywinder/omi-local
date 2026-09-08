"""Trusted-host import into the paired local owner; no public write endpoint."""

from __future__ import annotations

import argparse
import json
import logging
import os
from pathlib import Path

from utils.env_loader import is_offline_runtime
from utils.local_transport_auth import load_pairing, local_tunnel_enabled
from utils.other.local_storage import local_storage_root_from_env

# The normal entrypoint installs the local network/credential guards before
# database imports. No ML package is imported into the backend environment.
import main as backend_main
from database._client import get_firestore_client
from database import conversations as conversations_db
from utils.conversations import lifecycle
from utils.local_transcript import build_conversation


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('result_dir', nargs='?')
    args = parser.parse_args()
    logging.disable(logging.CRITICAL)
    try:
        if not is_offline_runtime() or not local_tunnel_enabled() or local_storage_root_from_env() is None:
            raise ValueError('Paired offline harness required')
        owner = load_pairing()['owner_uid']
        if not get_firestore_client().collection('users').document(owner).get(timeout=5).exists:
            raise ValueError('Paired owner missing from local database')
        if args.result_dir is None:
            print('{"preflight":"passed"}')
            return 0
        root = (Path(os.environ['OMI_HARNESS_STATE_ROOT']) / 'services/local-transcripts').resolve()
        folder = Path(args.result_dir).resolve()
        if folder.parent != root:
            raise ValueError('Result must be inside owned local transcript storage')
        manifest = json.loads((folder / 'manifest.json').read_text())
        raw = json.loads((folder / 'audio.json').read_text())
        conversation = build_conversation(raw, manifest)
        payload = conversation.model_dump(mode='json')
        # Raw + manifest are the replay source. A repeat uses create-if-absent,
        # preserving edits, and checks provenance before reporting success.
        created = lifecycle.create_completed_conversation(owner, conversation.model_dump(), idempotent=True)
        saved = conversations_db.get_conversation(owner, conversation.id)
        if not saved or saved.get('status') != 'completed' or saved.get('external_data') != payload['external_data']:
            raise ValueError('Conversation persistence was not verified')
        print(json.dumps({'import': 'passed', 'created': created, 'segments': len(saved['transcript_segments'])}))
        return 0
    except Exception as error:
        print(json.dumps({'import': 'failed', 'error_type': type(error).__name__}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
