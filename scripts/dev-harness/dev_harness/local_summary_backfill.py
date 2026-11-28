"""Queue missing summaries through the library's existing durable summary worker."""

import threading
import uuid

from . import local_provider_health, local_summary_queue, local_summary_regeneration
from .local_providers import SettingsError, read_json
from .local_stt import atomic_json

POLL_SECONDS = 15
IDLE_POLL_SECONDS = 60


class SummaryBackfill:
    def __init__(self, jobs):
        self.jobs = jobs
        self.path = jobs.root.parent / 'summary-backfill.json'
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.closed = threading.Event()
        self.phase = 'idle'
        self.failed = 0

    def _state(self):
        return read_json(self.path, {'automatic': False, 'requested': False, 'generation': ''})

    def _public(self, state):
        return {'automatic': state['automatic'], 'requested': state['requested'],
                'state': self.phase, 'failed': self.failed}

    def status(self):
        with self.lock:
            return self._public(self._state())

    def change(self, body):
        manual = body == {'run': True} and body.get('run') is True
        if not manual and (set(body) != {'automatic'} or type(body['automatic']) is not bool):
            raise SettingsError('Choose a backfill action.')
        with self.lock:
            state = self._state()
            if manual and not state['requested']:
                state.update(requested=True, generation=uuid.uuid4().hex)
            elif not manual:
                if body['automatic'] and not state['automatic'] and not state['requested']:
                    state['generation'] = uuid.uuid4().hex
                state['automatic'] = body['automatic']
            self.phase = 'checking' if state['automatic'] or state['requested'] else 'idle'
            self.failed = 0
            atomic_json(self.path, state)
            self.wake.set()
            return self._public(state)

    def start(self):
        threading.Thread(target=self._run, name='summary-backfill', daemon=True).start()

    def close(self):
        with self.lock:
            self.closed.set()
            self.wake.set()

    def _run(self):
        while not self.closed.is_set():
            self.wake.clear()
            self.tick()
            self.wake.wait(POLL_SECONDS if self.phase == 'running' else IDLE_POLL_SECONDS)

    def tick(self):
        with self.lock:
            state = self._state()
        if not (state['automatic'] or state['requested']):
            return
        try:
            phase, failed = self._queue_one(state)
        except (SettingsError, OSError, ValueError, KeyError, TypeError):
            phase, failed = 'unavailable', 0
        with self.lock:
            if state != self._state() or self.closed.is_set():
                return
            self.phase, self.failed = phase, failed
            if phase == 'idle' and state['requested']:
                atomic_json(self.path, {**state, 'requested': False})

    def _queue_one(self, state):
        if self.jobs.scheduled:
            return 'running', self.failed
        registry = self.jobs.registry
        profile = registry.snapshot('summary')
        if profile is None or not local_provider_health.observed_summary_ready(self.jobs.cfg, profile):
            return 'waiting_for_model', self.failed
        options = local_summary_regeneration.options(registry)
        binding = options['default_provider_binding']
        if not binding:
            return 'waiting_for_model', self.failed
        template = next(item for item in options['templates'] if item['id'] == options['default_template_id'])
        result = local_summary_queue.backend(self.jobs.cfg, 'backfill_candidates')
        waiting = False
        failed = 0
        for recording_id in result['recording_ids']:
            # A provider or template change admits a fresh attempt. Requests made
            # with the same defaults survive restarts without duplicating jobs.
            request_id = uuid.uuid5(uuid.NAMESPACE_URL,
                                    f"{state['generation']}:{binding}:{template['digest']}:{recording_id}")
            handle = {'scope': result['scope'], 'recording_id': recording_id, 'request_id': str(request_id)}
            status = self.jobs.backfill_status(handle)
            if status in {'waiting', 'queued'}:
                waiting = True
                continue
            if status not in {'missing', 'retry'}:
                failed += status == 'failed'
                continue
            try:
                source = local_summary_queue.backend(
                    self.jobs.cfg, 'describe', recording_id=recording_id, scope=result['scope'], only_missing=True,
                )
            except SettingsError as error:
                if error.status not in {404, 409, 413}:
                    raise
                failed += 1
                continue
            body = {**handle, 'source_revision': source['revision'], 'provider_binding': binding,
                    'template_id': template['id'], 'template_digest': template['digest'], 'prompt': template['prompt']}
            with self.lock:
                if state != self._state() or self.closed.is_set():
                    return 'idle', failed
                self.jobs.submit(body, expected_revision=source['revision'], only_missing=True)
            return 'running', failed
        return ('waiting_for_retry' if waiting else 'idle'), failed
