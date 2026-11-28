from pathlib import Path
from types import SimpleNamespace

import pytest

from dev_harness import local_summary_queue as module
from dev_harness import local_summary_backfill
from dev_harness.local_providers import SettingsError, read_json


class ManualExecutor:
    def __init__(self, **kwargs):
        self.pending = []

    def submit(self, function, file):
        self.pending.append((function, file))

    def step(self):
        function, file = self.pending.pop(0)
        function(file)

    def shutdown(self, **kwargs):
        self.pending.clear()


class Interrupted(BaseException):
    pass


@pytest.fixture
def summary(monkeypatch, tmp_path):
    monkeypatch.setattr(module, 'ThreadPoolExecutor', ManualExecutor)
    registry = SimpleNamespace(key=lambda snapshot: 'fixture-key')
    monkeypatch.setattr(module.local_summary_regeneration, 'prepare', lambda registry, body: {
        'settings': {'model': 'local'}, 'template': {'name': 'Standard', 'prompt': body['prompt']},
    })
    cfg = SimpleNamespace(layout=SimpleNamespace(services_dir=tmp_path))
    body = {'request_id': '00000000-0000-4000-8000-000000000001',
            'recording_id': '00000000-0000-4000-8000-000000000002', 'scope': 'a' * 64,
            'source_revision': 'b' * 64, 'provider_binding': 'c' * 64,
            'template_id': 'standard', 'template_digest': 'd' * 64, 'prompt': 'Decisions and evidence.'}
    return cfg, registry, body


def test_summary_queue_recovers_long_input_and_candidate_without_repeating_inference(summary, monkeypatch):
    cfg, registry, body = summary
    calls = []
    transcript = '[src:1] ' + 'a' * 125_000
    candidate = {'title': 'Recap', 'overview': 'Decisions', 'model': 'actually-loaded'}
    def back(cfg, operation, **payload):
        calls.append(operation)
        assert payload['scope'] == body['scope'] and payload['revision'] == body['source_revision']
        if operation == 'source':
            return {'transcript': transcript}
        assert payload['candidate']['title'] == candidate['title']
        assert payload['publication']['request_id'] == body['request_id']
        if calls.count('publish') == 1:
            raise Interrupted()
        return {'publication': payload['publication']}

    def generate(snapshot, key, text, folder: Path, write, *, sourced, deadline, progress, include_model):
        assert include_model
        assert key == 'fixture-key' and text == transcript and sourced
        assert deadline > module.monotonic()
        calls.append('inference')
        return candidate

    monkeypatch.setattr(module, 'backend', back)
    monkeypatch.setattr(module.local_pipeline, 'summarize_text', generate)
    jobs = module.SummaryJobs(cfg, registry)
    assert jobs.submit(body)['state'] == 'queued'
    assert jobs.submit(body)['state'] == 'queued'
    assert len(jobs.worker.pending) == 1
    with pytest.raises(SettingsError) as error:
        jobs.submit({**body, 'request_id': '00000000-0000-4000-8000-000000000003'})
    assert error.value.status == 409
    with pytest.raises(Interrupted):
        jobs.worker.step()
    assert calls == ['source', 'inference', 'publish']
    pending = read_json(jobs.file(body))
    assert pending['candidate']['title'] == candidate['title']
    assert 'fixture-key' not in str(pending) and transcript not in str(pending)

    recovered = module.SummaryJobs(cfg, registry)
    recovered.worker.step()
    assert calls == ['source', 'inference', 'publish', 'publish']
    assert recovered.status(body)['state'] == 'ready'
    assert recovered.status(body)['model'] == 'actually-loaded'
    assert recovered.latest(body)['job'] == recovered.status(body)
    assert recovered.status({**body, 'scope': 'e' * 64})['state'] == 'missing'
    assert 'snapshot' not in read_json(recovered.file(body))
    assert 'candidate' not in read_json(recovered.file(body))
    with pytest.raises(SettingsError):
        recovered.submit({**body, 'prompt': 'An altered request'})


def test_web_and_next_share_active_summary_and_reject_stale_input(summary, monkeypatch):
    cfg, registry, body = summary

    def back(cfg, operation, **payload):
        if operation == 'describe':
            return {'revision': body['source_revision'], 'scope': body['scope'], 'overview': 'Canonical recap',
                    'published': {'model': 'previous-model', 'template_name': 'Previous template'}}
        assert operation == 'source'
        raise SettingsError('Source changed.', status=409, code='recording_changed')

    monkeypatch.setattr(module, 'backend', back)
    monkeypatch.setattr(module.local_summary_regeneration, 'options', lambda registry: {'providers': [], 'templates': []})
    jobs = module.SummaryJobs(cfg, registry)
    assert jobs.web(body['recording_id'])['overview'] == 'Canonical recap'
    assert jobs.web(body['recording_id'], body)['state'] == 'queued'
    assert jobs.submit(body)['state'] == 'queued'
    jobs.worker.step()
    result = jobs.status(body)
    assert result['state'] == 'failed' and result['error'] == 'recording_changed'
    assert jobs.web(body['recording_id'])['job'] == result
    assert jobs.web(body['recording_id'])['published'] == {'model': 'previous-model', 'template_name': 'Previous template'}


def test_resuming_summary_keeps_the_last_progress_visible(summary, monkeypatch):
    cfg, registry, body = summary
    monkeypatch.setattr(module, 'backend', lambda cfg, operation, **payload: {'transcript': 'Synthetic transcript.'})
    first = module.SummaryJobs(cfg, registry)
    assert first.submit(body)['progress'] == {'phase': 'waiting'}

    def interrupt(*args, progress, **kwargs):
        progress('sections', 0, 4)
        progress('sections', 2, 4)
        raise Interrupted()

    monkeypatch.setattr(module.local_pipeline, 'summarize_text', interrupt)
    with pytest.raises(Interrupted):
        first.worker.step()
    assert first.status(body)['progress'] == {'phase': 'sections', 'completed': 2, 'total': 4}

    resumed = module.SummaryJobs(cfg, registry)

    def complete(*args, progress, **kwargs):
        progress('sections', 0, 4)
        assert resumed.status(body)['progress']['completed'] == 2
        progress('sections', 4, 4)
        progress('combining')
        assert resumed.status(body)['progress'] == {'phase': 'combining'}
        return {'title': 'Recap', 'overview': 'Saved.', 'model': 'actual'}

    monkeypatch.setattr(module.local_pipeline, 'summarize_text', complete)
    resumed.worker.step()
    assert resumed.status(body)['state'] == 'ready'
    assert 'progress' not in resumed.status(body)


@pytest.mark.parametrize('automatic', [False, True])
def test_backfill_waits_for_the_model_and_reuses_the_durable_queue(summary, monkeypatch, automatic):
    cfg, registry, body = summary
    registry.snapshot = lambda stage: {'id': 'local'}
    ready = False
    published = False
    calls = []
    monkeypatch.setattr(local_summary_backfill.local_provider_health, 'observed_summary_ready', lambda *args: ready)
    monkeypatch.setattr(module.local_summary_regeneration, 'options', lambda registry: {
        'default_provider_binding': body['provider_binding'],
        'templates': [{'id': 'standard', 'digest': body['template_digest'], 'prompt': body['prompt']}],
        'default_template_id': 'standard',
    })

    def backend(cfg, operation, **payload):
        nonlocal published
        calls.append(operation)
        if operation == 'backfill_candidates':
            return {'scope': body['scope'], 'recording_ids': [] if published else [body['recording_id']]}
        assert payload['only_missing'] is True
        if operation == 'describe':
            return {'revision': body['source_revision']}
        if operation == 'source':
            return {'transcript': 'Synthetic transcript.'}
        assert operation == 'publish' and payload['candidate']['overview'] == 'Saved.'
        published = True
        return {'publication': payload['publication']}

    monkeypatch.setattr(module, 'backend', backend)
    monkeypatch.setattr(module.local_pipeline, 'summarize_text',
                        lambda *args, **kwargs: {'title': 'Recap', 'overview': 'Saved.', 'model': 'local'})
    jobs = module.SummaryJobs(cfg, registry)
    backfill = local_summary_backfill.SummaryBackfill(jobs)
    backfill.change({'automatic': True} if automatic else {'run': True})
    backfill.tick()
    assert backfill.status()['state'] == 'waiting_for_model'
    assert not calls
    recovered = local_summary_backfill.SummaryBackfill(jobs)
    assert recovered.status()['requested'] is not automatic
    assert recovered.status()['automatic'] is automatic
    ready = True
    recovered.tick()
    recovered.tick()
    assert len(jobs.worker.pending) == 1
    jobs.worker.step()
    recovered.tick()
    assert recovered.status() == {'state': 'idle', 'requested': False, 'automatic': automatic, 'failed': 0}
    assert calls == ['backfill_candidates', 'describe', 'source', 'publish', 'backfill_candidates']


def test_backfill_job_retries_a_transient_provider_failure(summary, monkeypatch):
    cfg, registry, body = summary
    now = 0
    monkeypatch.setattr(module, 'time_ns', lambda: now)
    monkeypatch.setattr(module, 'backend', lambda *args, **kwargs: {'transcript': 'Test transcript.'})
    jobs = module.SummaryJobs(cfg, registry)

    def unavailable(*args, **kwargs):
        raise module.local_pipeline.PipelineError('Unavailable', code='http_503')

    monkeypatch.setattr(module.local_pipeline, 'summarize_text', unavailable)
    jobs.submit(body, only_missing=True)
    jobs.worker.step()
    assert jobs.backfill_status(body) == 'waiting'
    now += module.BACKFILL_RETRY_NS
    assert jobs.backfill_status(body) == 'retry'
    jobs.submit(body, only_missing=True)
    assert jobs.backfill_status(body) == 'queued'
