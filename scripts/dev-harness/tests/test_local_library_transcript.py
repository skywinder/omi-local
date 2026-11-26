import uuid
from types import SimpleNamespace

import httpx
import pytest

from dev_harness import local_library_transcript as transcript


def test_open_transcript_rechecks_names_and_reloads_edits_and_source_changes(tmp_path, monkeypatch):
    key, digest = 'a' * 64, 'b' * 64
    cfg = SimpleNamespace(repo_root=tmp_path, backend_port=21000)
    pairing = tmp_path / '.env'
    pairing.write_text('OMI_LOCAL_TRANSPORT=tailscale\nOMI_LOCAL_APP_KEY=' + 'c' * 43 + '\n')
    pairing.chmod(0o600)
    source = tmp_path / 'audio.json'
    source.write_text('{}')
    cid = str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + key))
    local = {'audio_sha256': digest, 'result_key': key}
    row = {'id': cid, 'status': 'completed', 'external_data': {'local_transcript': local}, 'transcript_segments': [
        {'start': 0, 'end': 1, 'text': 'Corrected', 'person_id': 'fixture', 'speaker': 'SPEAKER_00'},
        {'start': 1, 'end': 2, 'text': 'My words', 'is_user': True},
    ]}
    reads = []
    person = {'name': 'Assigned name', 'id': 'fixture'}
    names_status = 200

    def serve(req):
        assert req.url.host == '127.0.0.1' and req.headers['authorization'].startswith('Bearer ')
        if req.url.path == '/v1/local/people':
            return httpx.Response(names_status, json=[person])
        assert req.url.path == '/v1/conversations/' + cid
        reads.append(req.url.path)
        return httpx.Response(200, json=row)

    factory = httpx.Client
    monkeypatch.setattr(transcript.httpx, 'Client', lambda **opts: factory(transport=httpx.MockTransport(serve), **opts))
    reader = transcript.PairedTranscript(cfg)
    def read(revision):
        return reader.read(key, digest, 2, revision, [source])

    turns, missing = read('v1')
    assert not missing and turns[0]['speaker_name'] == 'Assigned name' and 'person_id' not in turns[0]
    assert turns[1]['is_user'] is True
    person['name'] = 'Renamed'
    assert read('v1')[0][0]['speaker_name'] == 'Renamed' and len(reads) == 1
    names_status = 503
    turns, missing = read('v1')
    assert missing and turns[0]['text'] == 'Corrected' and 'speaker_name' not in turns[0]
    row['transcript_segments'][0]['text'] = 'Edited again'
    assert read('v2')[0][0]['text'] == 'Edited again' and len(reads) == 2
    source.write_text('changed')
    local['segment_preview'] = True
    with pytest.raises(ValueError, match='source mismatch'):
        read('v2')
    assert len(reads) == 3
    local['segment_preview'] = False
    local['audio_sha256'] = 'd' * 64
    with pytest.raises(ValueError, match='source mismatch'):
        read(None)
