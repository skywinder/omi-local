"""Live-only tuning, scoped to the selected provider and acknowledged per stream."""
import asyncio
from copy import deepcopy
import hashlib
import json
import math
import re
from urllib.parse import urlsplit

import httpx

from .local_providers import SettingsError, atomic_json, read_json
from .local_provider_http import auth_headers

ACK_TIMEOUT_SECONDS = 5
STATUS_SEND_TIMEOUT_SECONDS = 1


def source_language(value):
    """Accept only the provider's explicit, bounded language configuration."""
    return value if isinstance(value, str) and re.fullmatch(r'[a-z]{2,3}|auto', value) else None


def validate(value):
    if not isinstance(value, dict) or set(value) != {'asr_coalesce_min_s', 'max_speakers', 'preview_mode'}:
        raise SettingsError('Check live transcription settings.')
    seconds, speakers = value['asr_coalesce_min_s'], value['max_speakers']
    if type(seconds) not in (int, float) or not math.isfinite(seconds) or not 0 <= seconds <= 10:
        raise SettingsError('Audio buffer must be between 0 and 10 seconds.', field='asr_coalesce_min_s')
    if type(speakers) is not int or not 1 <= speakers <= 4:
        raise SettingsError('Choose between 1 and 4 speakers.', field='max_speakers')
    if value['preview_mode'] not in {'draft', 'stable'}:
        raise SettingsError('Select a text mode.', field='preview_mode')
    return {**value, 'asr_coalesce_min_s': float(seconds)}


def provider_key(snapshot):
    return hashlib.sha256(json.dumps(snapshot, sort_keys=True).encode()).hexdigest()


async def capabilities(snapshot, key):
    if not snapshot or snapshot['kind'] != 'external':
        return None
    parsed = urlsplit(snapshot['settings']['url'])
    endpoint = parsed._replace(scheme='https' if parsed.scheme == 'wss' else 'http', path='/health').geturl()
    try:
        async with asyncio.timeout(3):
            async with httpx.AsyncClient(trust_env=False, follow_redirects=False, timeout=3) as client:
                headers = {'Accept-Encoding': 'identity', **auth_headers(key)}
                async with client.stream('GET', endpoint, headers=headers) as response:
                    response.raise_for_status()
                    if response.headers.get('Content-Encoding', 'identity').lower().strip() not in {'', 'identity'}:
                        return None
                    body = bytearray()
                    async for chunk in response.aiter_bytes(chunk_size=4097):
                        if len(body) + len(chunk) > 4096:
                            return None
                        body.extend(chunk)
            health = json.loads(body)
            if not isinstance(health, dict):
                return None
            data = health.get('live_tuning')
            if not isinstance(data, dict) or data.get('version') != 1:
                return None
            validate({**data['settings'], 'preview_mode': 'stable'})
            values = [value for value in (health.get('source_language'), data.get('source_language'))
                      if value is not None]
            language = source_language(values[0]) if values and all(value == values[0] for value in values) else None
            return {**data, 'source_language': language}
    except (TimeoutError, httpx.HTTPError, ValueError, KeyError, TypeError):
        return None


class Session:
    def __init__(self, settings, revision):
        self.settings = deepcopy(settings)
        self.revision = revision
        self.applied_revision = None
        self.applied_settings = None
        self.error = False
        self.changed = asyncio.Event()
        self.changed.set()
        self.ready = asyncio.Event()
        self.ack = None
        self.pending_revision = None

    def update(self, settings, revision):
        self.settings, self.revision = deepcopy(settings), revision
        self.changed.set()

    def acknowledge(self, message):
        if message.get('type') != 'live_tuning_ack':
            return False
        revision = message.get('revision')
        if self.ack and not self.ack.done() and type(revision) is int and revision == self.pending_revision:
            self.ack.set_result(message)
        return True

    async def run(self, provider, snapshot, on_status=None):
        while True:
            await self.changed.wait()
            self.changed.clear()
            settings, revision = deepcopy(self.settings), self.revision
            self.ack = asyncio.get_running_loop().create_future()
            self.pending_revision = revision
            wire = {key: value for key, value in settings.items() if key != 'preview_mode'}
            status = None
            try:
                async with asyncio.timeout(ACK_TIMEOUT_SECONDS):
                    await provider.send(json.dumps({'type': 'live_tuning', 'revision': revision, 'settings': wire}))
                    reply = await self.ack
                if reply.get('status') != 'applied' or reply.get('revision') != revision or reply.get('settings') != wire:
                    raise ValueError()
                validate({**reply['settings'], 'preview_mode': settings['preview_mode']})
                snapshot['settings']['preview_mode'] = settings['preview_mode']
                self.applied_revision, self.error = revision, False
                self.applied_settings = deepcopy(settings)
                status = 'applied'
            except (TimeoutError, ValueError):
                self.error = True
                status = 'failed'
            finally:
                self.ready.set()  # Status delivery must never hold up audio.
                if on_status and status:
                    try:
                        await asyncio.wait_for(on_status({'type': 'live_tuning_status', 'status': status,
                                                        'revision': revision,
                                                        'max_speakers': settings['max_speakers']}),
                                               STATUS_SEND_TIMEOUT_SECONDS)
                    except Exception:
                        pass  # A slow or disconnected observer cannot interrupt capture.


class Controls:
    def __init__(self, cfg, registry, capability_probe=capabilities):
        self.path = cfg.layout.state_root / 'live-tuning.json'
        self.registry = registry
        self.capability_probe = capability_probe
        self.sessions = set()
        self.lock = asyncio.Lock()

    def state(self, snapshot, capability):
        saved = read_json(self.path, {})
        revision = saved.get('revision', 0)
        settings = validate({**capability['settings'], 'preview_mode': snapshot['settings'].get('preview_mode', 'draft')})
        if saved.get('provider') == provider_key(snapshot):
            settings = validate(saved['settings'])
        return revision, settings

    async def current(self):
        snapshot = await asyncio.to_thread(self.registry.snapshot, 'live')
        key = await asyncio.to_thread(self.registry.key, snapshot) if snapshot else ''
        capability = await self.capability_probe(snapshot, key)
        return snapshot, capability

    def view(self, snapshot, capability):
        if not capability:
            return {'available': False, 'source_language': None,
                    'message': 'Live controls are unavailable. Check the connection and Live server support.'}
        revision, settings = self.state(snapshot, capability)
        sessions = [s for p, s in self.sessions if p == provider_key(snapshot)]
        return {'available': True, 'revision': revision, 'settings': settings,
                'source_language': source_language(capability.get('source_language')),
                'active_sessions': len(sessions),
                'applied_sessions': sum(not s.error and s.settings == settings and s.applied_settings == settings
                                        for s in sessions),
                'pending_sessions': sum(s.settings != settings for s in sessions),
                'failed_sessions': sum(s.error for s in sessions)}

    async def read(self):
        snapshot, capability = await self.current()
        return self.view(snapshot, capability)

    async def update(self, body):
        async with self.lock:
            snapshot, capability = await self.current()
            if not capability:
                raise SettingsError('The Live server did not confirm support for quick settings.', status=409)
            settings = validate(body.get('settings'))
            revision, previous = self.state(snapshot, capability)
            if type(body.get('revision')) is not int or body['revision'] != revision:
                raise SettingsError('Settings changed. Refresh and try again.', status=409)
            fields = body.get('changed_fields', [])
            if (not isinstance(fields, list) or any(not isinstance(field, str) or field not in settings
                                                     for field in fields) or len(fields) != len(set(fields))):
                raise SettingsError('Check live transcription settings.')
            changed = {field for field in settings if settings[field] != previous[field]} | set(fields)
            revision += 1
            await asyncio.to_thread(atomic_json, self.path, {
                'version': 1, 'revision': revision, 'provider': provider_key(snapshot), 'settings': settings})
            for p, session in self.sessions:
                if p == provider_key(snapshot) and changed:
                    session.update({**session.settings, **{field: settings[field] for field in changed}}, revision)
            return self.view(snapshot, capability)

    async def update_next_session(self, body):
        """Save only the speaker limit without mutating already attached streams."""
        if not isinstance(body, dict) or set(body) != {'revision', 'max_speakers'}:
            raise SettingsError('Check live transcription settings.')
        async with self.lock:
            snapshot, capability = await self.current()
            if not capability:
                raise SettingsError('The Live server did not confirm support for quick settings.', status=409)
            revision, settings = self.state(snapshot, capability)
            if type(body['revision']) is not int or body['revision'] != revision:
                raise SettingsError('Settings changed. Refresh and try again.', status=409)
            settings = validate({**settings, 'max_speakers': body['max_speakers']})
            revision += 1
            await asyncio.to_thread(atomic_json, self.path, {
                'version': 1, 'revision': revision, 'provider': provider_key(snapshot), 'settings': settings})
            return self.view(snapshot, capability)

    def attach(self, snapshot, config):
        capability = config.get('live_tuning')
        if not isinstance(capability, dict) or type(capability.get('version')) is not int or capability['version'] != 1:
            return None
        try:
            revision, settings = self.state(snapshot, capability)
        except (KeyError, TypeError, ValueError):
            return None
        session = Session(settings, revision)
        self.sessions.add((provider_key(snapshot), session))
        return session

    def detach(self, session):
        self.sessions = {(p, s) for p, s in self.sessions if s is not session}
