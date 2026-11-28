import pytest

from utils.local_transcript import build_conversation


def manifest():
    return {'audio_sha256': 'a' * 64, 'result_key': 'b' * 64, 'duration_seconds': 4,
            'started_at': '2026-01-01T00:00:00Z', 'source': 'omi',
            'profile': {'engine': 'whisperx', 'model': 'large-v3-turbo'}}


def raw():
    return {'language': 'ru', 'segments': [
        {'text': 'Проверка API.', 'start': 0.111, 'end': 1.456, 'speaker': 'SPEAKER_01'},
        {'text': 'Да.', 'start': 2.123, 'end': 3.456, 'speaker': 'SPEAKER_00'},
    ]}


def test_existing_wire_format_case_times_speakers_and_stable_identity():
    before = raw()
    conversation = build_conversation(before, manifest())
    assert before == raw()
    assert conversation.model_dump(mode='json') == build_conversation(raw(), manifest()).model_dump(mode='json')
    assert [s.text for s in conversation.transcript_segments] == ['Проверка API.', 'Да.']
    assert [s.speaker_id for s in conversation.transcript_segments] == [1, 0]
    assert conversation.transcript_segments[0].start == 0.111
    assert all(not s.is_user and s.speaker_identity_status == 'unknown' for s in conversation.transcript_segments)
    assert conversation.status == 'completed' and not conversation.deferred
    assert not conversation.structured.action_items
    alternative = manifest()
    alternative['result_key'] = 'c' * 64
    assert build_conversation(raw(), alternative).id != conversation.id


def test_summary_backfill_skips_existing_notes_and_incomplete_captures():
    from database.local_summary import needs_backfill

    capture = raw()
    capture['processing'] = {'summary': {'status': 'failed'}}
    recording = build_conversation(capture, manifest()).model_dump(mode='json')
    assert needs_backfill(recording)
    assert not needs_backfill({**recording, 'structured': {'overview': 'Existing recap'}})
    assert not needs_backfill({**recording, 'structured': {'sections': [{'heading': 'Edited note'}]}})
    assert not needs_backfill({**recording, 'local_summary_publication': {'request_id': 'saved'}})
    assert not needs_backfill({**recording, 'status': 'processing'})
    assert not needs_backfill({**recording, 'deleted': True})
    assert not needs_backfill({**recording, 'external_data': {}})


@pytest.mark.parametrize('engine,provider', [('parakeet-mlx', 'parakeet-mlx-local'),
                                           ('whisperkit', 'whisperkit-local'),
                                           ('openai-compatible', 'openai-compatible-local')])
def test_alternative_engine_provenance_uses_same_mobile_contract(engine, provider):
    data = manifest()
    data['profile'] = {'engine': engine, 'model': 'synthetic-model'}
    conversation = build_conversation(raw(), data)
    assert all(s.stt_provider == provider for s in conversation.transcript_segments)
    assert conversation.external_data['local_transcript']['profile'] == data['profile']
    assert conversation.status == 'completed' and conversation.uses_custom_stt


def test_word_speaker_change_splits_sentence_without_losing_text():
    data = {'language': 'ru', 'segments': [{'text': 'Да. API работает.', 'start': 0, 'end': 3,
        'speaker': 'SPEAKER_00', 'words': [
            {'word': 'Да.', 'start': 0, 'end': 0.8, 'speaker': 'SPEAKER_00'},
            {'word': 'API', 'start': 1, 'end': 1.8, 'speaker': 'SPEAKER_01'},
            {'word': 'работает.', 'start': 2, 'end': 3, 'speaker': 'SPEAKER_01'},
        ]}]}
    data['structured'] = {'title': 'API', 'overview': 'Fallback', 'sections': [
        {'heading': 'Decision', 'body_markdown': 'API works.', 'source_refs': [1, 91]},
        {'heading': 'Unknown', 'body_markdown': 'Unsupported.', 'source_refs': [91]},
    ]}
    conversation = build_conversation(data, manifest())
    assert [s.text for s in conversation.transcript_segments] == ['Да.', 'API работает.']
    assert [s.speaker_id for s in conversation.transcript_segments] == [0, 1]
    section, = conversation.structured.sections
    assert section.source_segment_ids == [line.id for line in conversation.transcript_segments]
    assert conversation.structured.overview == '## Decision\n\nAPI works.'
    del data['segments'][0]['words'][1]['start']
    with pytest.raises(ValueError):
        build_conversation(data, manifest())


@pytest.mark.parametrize('start', [None, True, float('nan'), -0.1, 5])
def test_invalid_timestamp_never_creates_completed_conversation(start):
    data = raw()
    data['segments'][0]['start'] = start
    with pytest.raises(ValueError):
        build_conversation(data, manifest())


def test_empty_transcript_is_not_success_and_unknown_speaker_is_not_user():
    with pytest.raises(ValueError):
        build_conversation({'segments': []}, manifest())
    data = raw()
    del data['segments'][0]['speaker']
    first = build_conversation(data, manifest()).transcript_segments[0]
    assert first.speaker is None and first.speaker_id == -1 and not first.is_user


def test_selected_pipeline_summary_projects_into_existing_conversation_contract():
    data, result = manifest(), raw()
    data['profile']['pipeline'] = {'summary': {'kind': 'openai-compatible'}}
    result['structured'] = {
        'title': 'Обсуждение API', 'overview': 'Проверили работу API.', 'category': 'technology', 'emoji': '💻',
    }
    conversation = build_conversation(result, data)
    assert conversation.structured.title == 'Обсуждение API'
    assert conversation.structured.overview == 'Проверили работу API.'
    assert conversation.structured.category == 'technology' and conversation.structured.emoji == '💻'
    assert conversation.external_data['local_transcript']['profile'] == data['profile']
    assert conversation.structured.action_items == []
    result['structured'].update(category='unknown', emoji='not an emoji')
    legacy = build_conversation(result, data)
    assert legacy.structured.category == 'other' and legacy.structured.emoji == '🎙️'
    result['structured']['overview'] = {'invalid': True}
    with pytest.raises(ValueError, match='summary'):
        build_conversation(result, data)


def test_paired_archive_page_counts_merged_rows_and_never_advances_past_a_truncated_prefix(monkeypatch):
    from datetime import datetime, timezone
    from types import SimpleNamespace

    from utils import local_recording_rows as records

    def row(identifier, minute):
        return {'id': identifier, 'created_at': datetime(2026, 1, 2, 0, minute, tzinfo=timezone.utc), 'source': 'omi'}

    older, newest = row('older', 1), row('newest', 4)
    local_first, local_last = row('local-first', 5), row('local-last', 0)
    monkeypatch.setattr(records, 'local_recording_rows', lambda uid, origins: [local_first, local_last])
    filters = dict(
        statuses=['processing', 'completed'], sources=['omi'], start_date=None, end_date=None,
        folder_id=None, starred=None, include_discarded=True,
    )
    reads = []

    def read(uid, limit, offset, *, budget, **received_filters):
        reads.append((uid, limit, offset))
        assert received_filters == filters
        return [newest] if budget.truncated else [newest, older][offset:offset + limit]

    complete = SimpleNamespace(truncated=False)
    assert records.read_local_archive_page(read, 'owner', 2, 0, budget=complete, **filters) == (
        [local_first, newest], True,
    )
    assert records.read_local_archive_page(read, 'owner', 2, 2, budget=complete, **filters) == (
        [older, local_last], False,
    )
    partial = SimpleNamespace(truncated=True)
    assert records.read_local_archive_page(read, 'owner', 3, 0, budget=partial, **filters) == (
        [local_first, newest], None,
    )
    assert records.read_local_archive_page(read, 'owner', 2, 2, budget=partial, **filters) == ([], None)
    assert reads == [('owner', 3, 0), ('owner', 5, 0), ('owner', 4, 0), ('owner', 5, 0)]


@pytest.mark.parametrize('state', ['pending', 'processing', 'failed', 'no_speech'])
def test_saved_recording_stays_visible_until_import_succeeds(tmp_path, monkeypatch, state):
    import hashlib
    import json
    import uuid
    from utils import local_recording_rows as rows
    from utils.offline_audio_capture import OfflineAudioCapture

    storage = tmp_path / 'services/storage'
    results = tmp_path / 'services/local-transcripts'
    results.mkdir(parents=True)
    monkeypatch.setattr(rows, 'is_offline_runtime', lambda: True)
    monkeypatch.setattr(rows, 'local_tunnel_enabled', lambda: True)
    monkeypatch.setattr(rows, 'load_pairing', lambda: {'owner_uid': 'synthetic-owner'})
    monkeypatch.setattr(rows, 'local_storage_root_from_env', lambda: storage)
    monkeypatch.setenv('OMI_HARNESS_STATE_ROOT', str(tmp_path))
    capture = OfflineAudioCapture(session_id=str(uuid.uuid4()), input_codec='pcm16', source='phone', root=storage)
    capture.record_decoded_frame(encoded_bytes=32000, pcm=b'\x00\x00' * 16000)
    assert rows.local_recording_rows('synthetic-owner') == []  # unfinished input lives in the capture card
    capture.finalize()
    key = hashlib.sha256(capture.session_id.encode()).hexdigest()
    queue = results / 'watch-queue.json'
    queue.write_text(json.dumps({key: {'state': state, 'profile': {'api_key': 'never-return'}}}))
    pending = rows.local_recording_rows('synthetic-owner')
    assert len(pending) == 1
    assert pending[0]['status'] == 'processing'
    assert pending[0]['external_data'] == {'local_recording': {'status': state, 'duration_seconds': 1.0}}
    assert rows.local_recording_rows('another-owner') == []
    assert 'never-return' not in str(pending) and str(storage) not in str(pending)
    row_id = pending[0]['id']
    assert rows.request_processing_retry('another-owner', row_id) == 'not_found'
    marker = capture.session_dir / '.retry-processing'
    assert not marker.exists()
    if state == 'failed':
        assert rows.request_processing_retry('synthetic-owner', row_id) == 'pending'
        assert marker.is_file()
        assert rows.request_processing_retry('synthetic-owner', row_id) == 'pending'
        assert rows.local_recording_rows('synthetic-owner')[0]['external_data']['local_recording']['status'] == 'pending'
        assert json.loads(queue.read_text())[key]['state'] == 'failed'  # Only the watcher owns the queue.
    elif state == 'no_speech':
        assert rows.request_processing_retry('synthetic-owner', row_id) == 'conflict'
        assert not marker.exists()
    queue.write_text(json.dumps({key: {'state': 'completed'}}))
    assert rows.local_recording_rows('synthetic-owner') == []
    # Manual import also retires the projection even if no queue job exists.
    queue.write_text('{}')
    assert len(rows.local_recording_rows('synthetic-owner')) == 1
    (results / ('b' * 64)).mkdir()
    (results / ('b' * 64) / 'import.json').write_text(json.dumps({'import': 'passed', 'capture_key': key}))
    assert rows.local_recording_rows('synthetic-owner') == []


def test_pending_projection_obeys_filters_and_merged_page_offsets():
    from datetime import datetime, timezone
    from utils.local_recording_rows import filter_local_recording_rows, merge_local_recording_page

    now = datetime(2026, 9, 17, tzinfo=timezone.utc)
    pending = [{'id': 'pending', 'created_at': now, 'source': 'omi'}]
    filters = dict(statuses=['processing', 'completed'], sources=[], start_date=None, end_date=None,
                   folder_id=None, starred=None)
    assert filter_local_recording_rows(pending, **filters) == pending
    for key, value in [('statuses', ['completed']), ('sources', ['phone']), ('folder_id', 'folder'), ('starred', True)]:
        assert filter_local_recording_rows(pending, **{**filters, key: value}) == []
    completed = [{'id': 'completed', 'created_at': now.replace(day=16)}]
    assert merge_local_recording_page(completed, pending, offset=0, limit=1) == pending
    assert merge_local_recording_page(completed, pending, offset=1, limit=1) == completed


@pytest.mark.parametrize('broken', ['invalid_json', 'non_object', 'oversized', 'bad_entry', 'bad_state', 'symlink'])
def test_invalid_optional_job_state_does_not_hide_saved_audio(tmp_path, monkeypatch, broken):
    import hashlib
    import json
    import uuid
    from utils import local_recording_rows as rows
    from utils.offline_audio_capture import OfflineAudioCapture

    storage = tmp_path / 'services/storage'
    results = tmp_path / 'services/local-transcripts'
    receipt = results / ('b' * 64) / 'import.json'
    receipt.parent.mkdir(parents=True)
    monkeypatch.setattr(rows, 'is_offline_runtime', lambda: True)
    monkeypatch.setattr(rows, 'local_tunnel_enabled', lambda: True)
    monkeypatch.setattr(rows, 'load_pairing', lambda: {'owner_uid': 'synthetic-owner'})
    monkeypatch.setattr(rows, 'local_storage_root_from_env', lambda: storage)
    monkeypatch.setenv('OMI_HARNESS_STATE_ROOT', str(tmp_path))
    capture = OfflineAudioCapture(session_id=str(uuid.uuid4()), input_codec='pcm16', source='phone', root=storage)
    capture.record_decoded_frame(encoded_bytes=32000, pcm=b'\x00\x00' * 16000)
    capture.finalize()
    queue = results / 'watch-queue.json'
    if broken in {'bad_entry', 'bad_state'}:
        key = hashlib.sha256(capture.session_id.encode()).hexdigest()
        queue.write_text(json.dumps({key: [] if broken == 'bad_entry' else {'state': []}}))
        receipt.write_text(json.dumps({'import': 'passed', 'capture_key': []}))
    elif broken == 'symlink':
        target = tmp_path / 'untrusted.json'
        target.write_text('{}')
        queue.symlink_to(target)
        receipt.symlink_to(target)
    else:
        payload = {'invalid_json': '{', 'non_object': '[]', 'oversized': ' ' * (4 * 1024 * 1024) + '{}'}[broken]
        queue.write_text(payload)
        receipt.write_text(payload)
    pending = rows.local_recording_rows('synthetic-owner')
    assert len(pending) == 1
    assert pending[0]['external_data']['local_recording']['status'] == 'saved'


def test_pipeline_stage_outcomes_are_projected_with_fixed_fields_only():
    data, result = manifest(), raw()
    data['profile']['pipeline'] = {'stt': {'kind': 'openai-compatible'}, 'diarization': {'kind': 'mycelia'}}
    result['diarization'] = {'turns': [[0.0, 3.5, 'SPEAKER_00']], 'speakers': 2}
    result['processing'] = {
        'stt': {'status': 'ready', 'provider_name': 'GPU whisper', 'model': 'large-v3-turbo', 'api_key': 'must-not-escape'},
        'diarization': {'status': 'ready', 'provider_name': 'x' * 300},
        'summary': {'status': 'disabled'},
        'bogus': {'status': 'ready'},
    }
    conversation = build_conversation(result, data)
    stages = conversation.external_data['local_transcript']['stages']
    assert stages == {
        'stt': {'status': 'ready', 'provider': 'GPU whisper'},
        'diarization': {'status': 'ready', 'provider': 'x' * 100, 'speakers': 2},
        'summary': {'status': 'disabled'},
    }
    assert 'must-not-escape' not in str(conversation.external_data)


def test_summary_stage_preserves_only_published_model_and_template():
    data, result = manifest(), raw()
    result['processing'] = {'summary': {'status': 'ready', 'model': 'Actual model',
        'template_name': 'Saved template', 'prompt': 'private', 'api_key': 'private'}}
    stages = build_conversation(result, data).external_data['local_transcript']['stages']
    assert stages == {'summary': {'status': 'ready', 'model': 'Actual model', 'template_name': 'Saved template'}}
    result['processing']['summary']['status'] = 'failed'
    assert build_conversation(result, data).external_data['local_transcript']['stages'] == {'summary': {'status': 'failed'}}


def test_legacy_results_without_processing_carry_no_stage_block():
    conversation = build_conversation(raw(), manifest())
    assert 'stages' not in conversation.external_data['local_transcript']


def test_unexpected_stage_status_is_reported_as_unknown():
    data, result = manifest(), raw()
    result['processing'] = {'diarization': {'status': 'exploded', 'provider_name': 'GPU pyannote'}}
    stages = build_conversation(result, data).external_data['local_transcript']['stages']
    assert stages == {'diarization': {'status': 'unknown', 'provider': 'GPU pyannote'}}


@pytest.mark.parametrize('state', ['pending', 'processing', 'failed', 'no_speech'])
def test_saved_recording_stays_visible_until_import_succeeds(tmp_path, monkeypatch, state):
    import hashlib
    import json
    import uuid
    from utils import local_recording_rows as rows
    from utils.offline_audio_capture import OfflineAudioCapture

    storage = tmp_path / 'services/storage'
    results = tmp_path / 'services/local-transcripts'
    results.mkdir(parents=True)
    monkeypatch.setattr(rows, 'is_offline_runtime', lambda: True)
    monkeypatch.setattr(rows, 'local_tunnel_enabled', lambda: True)
    monkeypatch.setattr(rows, 'load_pairing', lambda: {'owner_uid': 'synthetic-owner'})
    monkeypatch.setattr(rows, 'local_storage_root_from_env', lambda: storage)
    monkeypatch.setenv('OMI_HARNESS_STATE_ROOT', str(tmp_path))
    capture = OfflineAudioCapture(session_id=str(uuid.uuid4()), input_codec='pcm16', source='phone', root=storage,
                                  origin={'phone_platform': 'ios', 'phone_model': 'iPhone Test'})
    capture.record_decoded_frame(encoded_bytes=32000, pcm=b'\x00\x00' * 16000)
    assert rows.local_recording_rows('synthetic-owner') == []  # unfinished input lives in the capture card
    capture.finalize()
    key = hashlib.sha256(capture.session_id.encode()).hexdigest()
    queue = results / 'watch-queue.json'
    queue.write_text(json.dumps({key: {'state': state, 'profile': {'api_key': 'never-return'}}}))
    processing = results / ('a' * 64)
    processing.mkdir()
    (processing / 'manifest.json').write_text(json.dumps({'capture_key': key, 'profile': {'api_key': 'never-return'}}))
    (processing / 'processing.json').write_text(json.dumps({'summary': {
        'status': 'failed', 'error_code': 'invalid_json', 'detail': 'never-return'}}))
    pending = rows.local_recording_rows('synthetic-owner')
    assert len(pending) == 1
    assert pending[0]['status'] == 'processing'
    origin = {'phone_platform': 'ios', 'phone_model': 'iPhone Test'}
    expected = {'status': state, 'duration_seconds': 1.0, 'origin': origin}
    if state == 'failed':
        expected['failure'] = {'stage': 'summary', 'code': 'invalid_json', 'attempts': 0}
    assert pending[0]['external_data'] == {'local_recording': expected}
    assert rows.local_recording_rows('another-owner') == []
    assert 'never-return' not in str(pending) and str(storage) not in str(pending)
    if state == 'failed':
        job = {'state': state, 'profile': {'api_key': 'never-return'}, 'attempts': 3,
               'attempt_started_at': (processing / 'processing.json').stat().st_mtime + 1,
               'failure': {'stage': 'import', 'code': 'import_failed', 'detail': 'never-return'}}
        queue.write_text(json.dumps({key: job}))
        failure = rows.local_recording_rows('synthetic-owner')[0]['external_data']['local_recording']['failure']
        assert failure == {'stage': 'import', 'code': 'import_failed', 'attempts': 3}
        job['failure'] = {'stage': ['never-return'], 'code': 'never-return'}
        queue.write_text(json.dumps({key: job}))
        failure = rows.local_recording_rows('synthetic-owner')[0]['external_data']['local_recording']['failure']
        assert failure == {'attempts': 3}
    queue.write_text(json.dumps({key: {'state': 'completed'}}))
    assert rows.local_recording_rows('synthetic-owner') == []
    # Manual import also retires the projection even if no queue job exists.
    queue.write_text('{}')
    assert len(rows.local_recording_rows('synthetic-owner')) == 1
    (results / ('b' * 64)).mkdir()
    (results / ('b' * 64) / 'import.json').write_text(json.dumps({'import': 'passed', 'capture_key': key}))
    origins = {}
    assert rows.local_recording_rows('synthetic-owner', origins) == []
    saved_id = str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + 'b' * 64))
    assert rows.attach_saved_origin({'id': saved_id}, origins)['external_data']['local_transcript']['origin'] == origin



def test_pending_projection_obeys_filters_and_merged_page_offsets():
    from datetime import datetime, timezone
    from utils.local_recording_rows import filter_local_recording_rows, merge_local_recording_page

    now = datetime(2026, 9, 17, tzinfo=timezone.utc)
    pending = [{'id': 'pending', 'created_at': now, 'source': 'omi'}]
    filters = dict(statuses=['processing', 'completed'], sources=[], start_date=None, end_date=None,
                   folder_id=None, starred=None)
    assert filter_local_recording_rows(pending, **filters) == pending
    for key, value in [('statuses', ['completed']), ('sources', ['phone']), ('folder_id', 'folder'), ('starred', True)]:
        assert filter_local_recording_rows(pending, **{**filters, key: value}) == []
    completed = [{'id': 'completed', 'created_at': now.replace(day=16)}]
    assert merge_local_recording_page(completed, pending, offset=0, limit=1) == pending
    assert merge_local_recording_page(completed, pending, offset=1, limit=1) == completed


def test_large_grouped_import_projects_small_card_and_hydrates_full_checked_transcript(tmp_path, monkeypatch):
    import json
    from database import local_summary
    from utils.local_transcript import grouped_import_document, hydrate_grouped_transcript

    data = manifest()
    data.update(conversation_group={'start_sample': 0, 'end_sample': 192000},
                duration_seconds=12000)
    root = tmp_path / 'services/local-transcripts'
    folder = root / data['result_key']
    folder.mkdir(parents=True)
    transcript = {'segments': [{'text': 'Синтетическая реплика ' * 15 + str(i), 'start': i, 'end': i + 1}
                                for i in range(1500)]}
    raw_path = folder / 'audio.json'
    raw_path.write_text(json.dumps(transcript))
    (folder / 'manifest.json').write_text(json.dumps(data))
    conversation = build_conversation(transcript, data)
    card = grouped_import_document(conversation, data, raw_path)
    assert len(json.dumps(card, default=str)) < 4096
    assert len(card['transcript_segments']) == 1
    assert card['external_data']['local_transcript']['segment_preview'] is True
    card['starred'] = True
    card['structured']['overview'] = 'Updated summary'
    full = hydrate_grouped_transcript(card, root, 'fixture-owner')
    assert full['starred'] and full['structured']['overview'] == 'Updated summary'
    assert not full['external_data']['local_transcript']['segment_preview']
    assert [s['text'] for s in full['transcript_segments']] == [s['text'] for s in transcript['segments']]
    assert full['transcript_segments'][-1]['id'] == conversation.transcript_segments[-1].id
    monkeypatch.setenv('OMI_HARNESS_STATE_ROOT', str(tmp_path))
    source = local_summary.source(card, 'fixture-owner', background=True)
    assert len(source.transcript) > 120_000
    assert source.segment_ids[-1] == (conversation.transcript_segments[-1].id,)
    raw_path.write_text('{"segments": []}')
    with pytest.raises(ValueError, match='changed'):
        hydrate_grouped_transcript(card, root, 'fixture-owner')
    with pytest.raises(local_summary.SummaryUnavailable):
        local_summary.source(card, 'fixture-owner', background=True)
    assert len(grouped_import_document(conversation, manifest(), raw_path)['transcript_segments']) == 1500
