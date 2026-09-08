"""Trusted-host paired-owner deletion; no new write endpoint on the tunnel."""

import json
import logging
import sys

from utils.env_loader import is_offline_runtime
from utils.local_transport_auth import load_pairing, local_tunnel_enabled
from utils.other.local_storage import local_storage_root_from_env

import main as backend_main
from database._client import get_firestore_client
from database import conversations as conversations_db
from utils.local_recording_delete import delete_linked_conversations


def main():
    logging.disable(logging.CRITICAL)
    try:
        if not is_offline_runtime() or not local_tunnel_enabled() or local_storage_root_from_env() is None:
            raise ValueError('Paired offline harness required')
        owner = load_pairing()['owner_uid']
        if not get_firestore_client().collection('users').document(owner).get(timeout=5).exists:
            raise ValueError('Paired owner missing')
        payload = json.loads(sys.stdin.read(65536))
        count = delete_linked_conversations(
            owner, payload['digest'], payload['result_keys'], get=conversations_db.get_conversation,
            delete=conversations_db.delete_conversation, check_only=payload.get('check_only', False),
        )
        print(json.dumps({'status': 'passed', 'conversations': count}))
        return 0
    except Exception:
        print('{"status":"failed"}')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
