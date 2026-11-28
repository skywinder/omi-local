"""Trusted-host transcript snapshot and publication for the library's summary worker."""

import json
import logging
import re
import sys

from utils.env_loader import is_offline_runtime
from utils.local_transport_auth import load_pairing, local_tunnel_enabled

# Establish the offline egress guard before opening the paired database.
import main as backend_main  # noqa: F401
from database import local_summary as summaries
from routers.local_summary import Candidate


def execute(uid, body):
    operation = body['operation']
    scope = summaries.owner_scope(uid)
    if operation == 'backfill_candidates':
        return {'scope': scope, 'recording_ids': summaries.backfill_candidates(uid)}
    recording_id = body['recording_id']
    if not re.fullmatch(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}', recording_id):
        raise summaries.SummaryUnavailable()
    raw = summaries.recording(uid, recording_id)
    only_missing = body.get('only_missing') is True
    if body.get('scope', scope if operation in {'source', 'describe'} else None) != scope:
        raise summaries.SummaryUnavailable()
    if operation == 'publish':
        publication = body['publication']
        previous = summaries.replay(raw, publication['request_id'], publication['fingerprint'])
        if previous is None:
            candidate = Candidate.model_validate(body['candidate']).model_dump()
            previous = summaries.publish(
                uid, recording_id, body['revision'], candidate, publication, background=True, only_missing=only_missing,
            )
        return {'publication': previous}
    if operation in {'source', 'describe'}:
        if only_missing and not summaries.needs_backfill(raw):
            raise summaries.SummaryChanged()
        snapshot = summaries.source(raw, uid, background=True)
        if not snapshot.transcript:
            raise summaries.SummaryUnavailable()
        if body.get('revision', snapshot.revision) != snapshot.revision:
            raise summaries.SummaryChanged()
        result = {'revision': snapshot.revision, 'scope': scope}
        if operation == 'source':
            result['transcript'] = snapshot.transcript
        else:
            result['overview'] = (raw.get('structured') or {}).get('overview')
            result['published'] = summaries.published_provenance(raw)
        return result
    raise ValueError('Unknown summary worker operation')


def main():
    logging.disable(logging.CRITICAL)
    try:
        if not is_offline_runtime() or not local_tunnel_enabled():
            raise summaries.SummaryUnavailable()
        result = execute(load_pairing()['owner_uid'], json.load(sys.stdin))
    except summaries.SummaryUnavailable:
        result = {'error': 'recording_unavailable'}
    except summaries.SummaryChanged:
        result = {'error': 'recording_changed'}
    except summaries.SummaryTooLarge:
        result = {'error': 'recording_too_large'}
    except (ValueError, TypeError, KeyError, OSError):
        result = {'error': 'database_failure'}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
