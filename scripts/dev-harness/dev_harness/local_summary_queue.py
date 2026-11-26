"""Durable summary-only processing in the library process, shared by its clients."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from time import monotonic, time_ns

import httpx

from . import config, local_pipeline, local_summary_regeneration
from .local_providers import SettingsError, read_json
from .local_stt import atomic_json

INFERENCE_BUDGET_SECONDS = 6 * 3600


def backend(cfg, operation, **body):
    env = config.child_env_for(cfg)
    scripts = cfg.repo_root / 'backend'
    env['PYTHONPATH'] = str(scripts)
    try:
        result = subprocess.run([sys.executable, '-m', 'scripts.local_summary_worker'], cwd=scripts, env=env,
                                input=json.dumps({'operation': operation, **body}), text=True,
                                capture_output=True, timeout=60, check=True)
        data = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        raise SettingsError('Summary storage unavailable.', status=503, code='database_failure') from None
    if error := data.get('error'):
        status = {'recording_unavailable': 404, 'recording_changed': 409, 'recording_too_large': 413}.get(error, 503)
        raise SettingsError('Summary source or publication unavailable.', status=status, code=error)
    return data


class SummaryJobs:
    def __init__(self, cfg, registry):
        self.cfg = cfg
        self.registry = registry
        self.root = cfg.layout.services_dir / 'summary-jobs'
        self.worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix='summary-jobs')
        self.scheduled = set()
        if self.root.is_dir():
            with self.lock():
                queued = []
                for file in self.root.glob('*/*/*/job.json'):
                    try:
                        if (job := read_json(file, {})).get('state') == 'queued':
                            queued.append((job['created_at'], file))
                    except (OSError, ValueError, KeyError):
                        continue
                for _, file in sorted(queued):
                    self.schedule(file)

    @contextmanager
    def lock(self):
        self.root.mkdir(mode=0o700, exist_ok=True)
        fd = os.open(self.root / '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def close(self):
        self.worker.shutdown(wait=False, cancel_futures=True)

    def file(self, body):
        key = r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}'
        scope, recording_id, request_id = (body.get(k, '') for k in ('scope', 'recording_id', 'request_id'))
        if (not re.fullmatch(r'[a-f0-9]{64}', scope) or not re.fullmatch(key, recording_id)
                or not re.fullmatch(key, request_id)):
            raise SettingsError('Invalid summary request.')
        return self.root / scope / recording_id / request_id / 'job.json'

    @staticmethod
    def public(job):
        return {key: job[key] for key in ('request_id', 'state', 'error', 'model', 'template_name') if key in job}

    def status(self, body):
        job = read_json(self.file(body))
        return self.public(job) if job is not None else {'request_id': body['request_id'], 'state': 'missing'}

    def records(self, body):
        sample = self.file({**body, 'request_id': '00000000-0000-0000-0000-000000000000'})
        return [job for file in sample.parent.parent.glob('*/job.json') if (job := read_json(file))]

    def latest(self, body):
        job = max(self.records(body), key=lambda job: job['created_at'], default=None)
        return {'job': self.public(job) if job else None}

    def web(self, recording_id, body=None):
        source = backend(self.cfg, 'describe', recording_id=recording_id)
        handle = {'recording_id': recording_id, 'scope': source['scope']}
        if body is not None:
            return self.submit({**body, **handle}, expected_revision=source['revision'])
        return {**local_summary_regeneration.options(self.registry), 'source_revision': source['revision'],
                **self.latest(handle), 'overview': source['overview']}

    def submit(self, body, *, expected_revision=None):
        file = self.file(body)
        fields = ('scope', 'recording_id', 'request_id', 'source_revision', 'provider_binding',
                  'template_id', 'template_digest', 'prompt')
        request = {k: body[k] for k in fields}
        fingerprint = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
        with self.lock():
            if job := read_json(file):
                if job['fingerprint'] != fingerprint:
                    raise SettingsError('Summary request changed.', status=409)
                if job['state'] == 'queued':
                    self.schedule(file)
                return self.public(job)
            if expected_revision is not None and request['source_revision'] != expected_revision:
                raise SettingsError('Summary source changed.', status=409)
            if any(read_json(existing, {}).get('state') == 'queued' for existing in file.parent.parent.glob('*/job.json')):
                raise SettingsError('A summary is already queued for this recording.', status=409)
            snapshot = local_summary_regeneration.prepare(self.registry, request)
            # Persist the selected model and credential reference, never the key or transcript.
            job = {k: request[k] for k in ('scope', 'recording_id', 'request_id', 'source_revision')}
            job.update(state='queued', fingerprint=fingerprint, snapshot=snapshot, created_at=time_ns(),
                       model=snapshot['settings']['model'], template_name=snapshot['template']['name'])
            file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            atomic_json(file, job)
            self.schedule(file)
        return self.public(job)

    def schedule(self, file):
        if file not in self.scheduled:
            self.scheduled.add(file)
            self.worker.submit(self.process, file)

    def process(self, file):
        job = {}
        try:
            job = read_json(file, {})
            if job.get('state') != 'queued':
                return
            source_args = dict(recording_id=job['recording_id'], scope=job['scope'], revision=job['source_revision'])
            if 'candidate' not in job:
                source = backend(self.cfg, 'source', **source_args)
                snapshot = job['snapshot']
                candidate = local_pipeline.summarize_text(
                    snapshot, self.registry.key(snapshot), source['transcript'], file.parent, atomic_json, sourced=True,
                    deadline=monotonic() + INFERENCE_BUDGET_SECONDS,
                )
                job['candidate'] = {**candidate, 'model': job['model'], 'template_name': job['template_name']}
                atomic_json(file, job)
            publication = {k: job[k] for k in ('request_id', 'fingerprint', 'model', 'template_name')}
            for attempt in range(2):
                try:
                    backend(self.cfg, 'publish', **source_args, candidate=job['candidate'], publication=publication)
                    break
                except SettingsError as error:
                    if attempt or error.status != 503:
                        raise
            job['state'] = 'ready'
        except SettingsError as error:
            job.update(state='failed', error=error.diagnostic_code or 'summary_unavailable')
        except local_pipeline.PipelineError as error:
            job.update(state='failed', error=error.diagnostic_code or 'summary_unavailable')
        except (httpx.HTTPError, OSError, ValueError, KeyError, TypeError):
            job.update(state='failed', error='summary_unavailable')
        finally:
            with self.lock():
                if job.get('request_id') and job['state'] in {'ready', 'failed'}:
                    job.pop('snapshot', None)
                    job.pop('candidate', None)
                    cache = file.parent / 'summaries'
                    if cache.is_dir():
                        shutil.rmtree(cache)
                    atomic_json(file, job)
                self.scheduled.discard(file)
