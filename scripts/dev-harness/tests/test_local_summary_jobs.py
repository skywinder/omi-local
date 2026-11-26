from pathlib import Path
from types import SimpleNamespace

import pytest

from dev_harness import local_summary_queue as module
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
    candidate = {'title': 'Recap', 'overview': 'Decisions'}
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

    def generate(snapshot, key, text, folder: Path, write, *, sourced, deadline):
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
            return {'revision': body['source_revision'], 'scope': body['scope'], 'overview': 'Canonical recap'}
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
