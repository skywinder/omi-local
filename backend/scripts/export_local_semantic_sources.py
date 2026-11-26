"""Stream the current paired owner's searchable archive to a trusted local indexer."""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

from utils.conversations.semantic_passages import owner_digest, passages, source_revision
from utils.local_transport_auth import load_pairing, local_tunnel_enabled


_RECORDING_ID = re.compile(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}')


def iter_sources(uid):
    from database.conversations import read_local_search_page
    from utils.local_transcript import hydrate_grouped_transcript

    root = Path(os.environ['OMI_HARNESS_STATE_ROOT']) / 'services' / 'local-transcripts'
    cursor = None
    while True:
        rows, next_cursor = read_local_search_page(uid, cursor, 20, end_page_after_file=True)
        for row in rows:
            if not _RECORDING_ID.fullmatch(row['id']):
                continue
            source = (row.get('external_data') or {}).get('local_transcript') or {}
            if source.get('segment_storage') == 'result-file':
                row = hydrate_grouped_transcript(row, root)
            yield {
                'id': row['id'], 'revision': source_revision(row['_local_read_version']),
                'passages': [passage.text for passage in passages(row)],
            }
        if next_cursor is None:
            break
        if cursor is not None and cursor >= next_cursor:
            raise ValueError('Archive scan failed to advance')
        cursor = next_cursor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--owner-digest', action='store_true', help='print only the index owner identity')
    args = parser.parse_args()
    if not local_tunnel_enabled():
        raise ValueError('Paired local transport is required')
    emulator = urlsplit('//' + os.environ.get('FIRESTORE_EMULATOR_HOST', ''))
    if emulator.hostname not in {'127.0.0.1', 'localhost', '::1'} or emulator.port is None:
        raise ValueError('Loopback Firestore is required')
    uid = load_pairing()['owner_uid']
    if args.owner_digest:
        print(owner_digest(uid))
        return
    print(json.dumps({'owner': owner_digest(uid), 'version': 1}))
    count = 0
    for source in iter_sources(uid):
        print(json.dumps(source, ensure_ascii=False, separators=(',', ':')))
        count += 1
    print(json.dumps({'complete': count}))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Local semantic archive scan failed', file=sys.stderr)
        sys.exit(1)
