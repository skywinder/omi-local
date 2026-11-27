"""Private provider drafts and immutable active snapshots for the local audio library.

The registry owns selection, credentials and optimistic edits. It never sends audio.
Legacy engine files are imported once, when the first explicit edit is saved.
"""
from __future__ import annotations

from contextlib import contextmanager
from copy import deepcopy
import fcntl
import json
import os
from pathlib import Path
import re
import tempfile
import uuid

from .local_provider_http import auth_headers, default_summary_model_source, follows_summary_provider, validate_url


STAGES = ('live', 'stt', 'diarization', 'summary', 'translation')
KINDS = {'live': {'external', 'whisperlivekit', 'parakeet-local'},
         'stt': {'whisperkit', 'whisperx', 'parakeet-mlx', 'openai-compatible'},
         'diarization': {'pyannote', 'mycelia'}, 'summary': {'openai-compatible'},
         'translation': {'openai-compatible'}}
ENGINE_FIELDS = {'provider_url', 'model', 'language', 'compute_type', 'batch_size', 'python',
                 'library_path', 'assets_path', 'runtime_revision', 'device', 'chunk_duration',
                 'overlap_duration', 'diarization_model'}
SPEAKER_FIELDS = {'speaker_model', 'speaker_python', 'speaker_device', 'speaker_threads', 'speaker_count', 'speaker_revision'}
LIVE_FIELDS = {'url', 'python', 'model_dir', 'chunk_seconds', 'language', 'diarization'}
NAME_LIMIT = 100
DEFAULT_SUMMARY_TEMPLATE = {
    'id': 'standard',
    'name': 'Standard summary',
    'prompt': 'Summarize the recording accurately. Preserve decisions, important facts and explicit action items.',
}


class SettingsError(ValueError):
    def __init__(self, message, *, status=400, field=None, code=None):
        super().__init__(message)
        self.status = status
        self.field = field
        self.diagnostic_code = code


def summary_templates(state):
    return state.get('summary_templates', {
        'default_template_id': DEFAULT_SUMMARY_TEMPLATE['id'],
        'templates': [DEFAULT_SUMMARY_TEMPLATE],
    })


def validate_summary_templates(templates, default):
    if not isinstance(templates, list) or not 1 <= len(templates) <= 24:
        raise SettingsError('Add between 1 and 24 templates.')
    ids = set()
    for item in templates:
        if (not isinstance(item, dict) or set(item) != {'id', 'name', 'prompt'}
                or not all(isinstance(value, str) for value in item.values())
                or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', item['id']) or item['id'] in ids
                or not item['name'].strip() or not item['name'].isprintable() or len(item['name']) > 100
                or not item['prompt'].strip() or len(item['prompt']) > 8000
                or any(ord(char) < 32 and char not in '\n\r\t' or 0xD800 <= ord(char) <= 0xDFFF
                       for char in item['prompt'])):
            raise SettingsError('Check the template name and text.')
        ids.add(item['id'])
    if not isinstance(default, str) or default not in ids:
        raise SettingsError('Select an existing default template.')


def read_json(path, default=None):
    if not path.exists():
        return deepcopy(default)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 2 * 1024 * 1024:
        raise SettingsError('Settings file unavailable.', status=503)
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        raise SettingsError('Could not read settings.', status=503) from None


def atomic_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink():
        raise SettingsError('Settings file unavailable.', status=503)
    fd, temporary = tempfile.mkstemp(prefix='.providers-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def identity(profile):
    """Keys cannot follow a draft URL to a different host or protocol."""
    from urllib.parse import urlsplit
    settings = profile.get('settings', {})
    endpoint = settings.get('provider_url') or settings.get('base_url') or settings.get('url') or ''
    parsed = urlsplit(endpoint)
    return profile.get('stage'), profile.get('kind'), parsed.scheme, parsed.netloc


def number(settings, key, default, low, high, *, integer=True):
    value = settings.get(key, default)
    if type(value) not in ((int,) if integer else (int, float)) or not low <= value <= high:
        raise SettingsError('Invalid value: ' + key, field=key)
    settings[key] = value


def text_field(settings, key, default='', *, required=False, limit=2048):
    value = settings.get(key, default)
    if not isinstance(value, str) or len(value) > limit or (value and not value.isprintable()):
        raise SettingsError('Invalid value: ' + key, field=key)
    value = value.strip()
    if required and not value:
        raise SettingsError('Required field: ' + key, field=key)
    if value or key in settings or default:
        settings[key] = value


def validate_profile(value, *, models=False):
    if not isinstance(value, dict):
        raise SettingsError('Invalid provider profile.')
    stage, kind = value.get('stage'), value.get('kind')
    if stage not in KINDS or kind not in KINDS[stage]:
        raise SettingsError('Select a supported provider type.')
    name = value.get('name', '')
    if not isinstance(name, str) or not name.strip() or len(name) > NAME_LIMIT or any(ord(c) < 32 for c in name):
        raise SettingsError('Enter a provider name of up to 100 characters.', field='name')
    data = deepcopy(value.get('settings', {}))
    if not isinstance(data, dict):
        raise SettingsError('Invalid provider parameters.')
    allowed = (ENGINE_FIELDS if stage == 'stt' else LIVE_FIELDS if stage == 'live' else
               SPEAKER_FIELDS if kind == 'pyannote' else
               {'base_url', 'min_speakers', 'max_speakers'} if stage == 'diarization' else
               {'base_url', 'model', 'reasoning', 'model_source'} if stage == 'summary' else
               {'base_url', 'model', 'reasoning'})
    if set(data) - allowed:
        raise SettingsError('The parameters do not match the selected provider type.')
    for key in data:
        if key not in {'diarization', 'batch_size', 'chunk_duration', 'overlap_duration', 'speaker_threads',
                       'speaker_count', 'chunk_seconds', 'min_speakers', 'max_speakers'}:
            text_field(data, key)
    if stage == 'stt':
        text_field(data, 'model', required=not models, limit=256)
        text_field(data, 'language', 'ru' if kind == 'whisperx' else 'auto', limit=32)
        if kind == 'openai-compatible':
            data['provider_url'] = endpoint(data, 'provider_url')
            if not data['provider_url'].endswith('/v1'):
                raise SettingsError('The STT address must end in /v1.', field='provider_url')
        if 'batch_size' in data:
            number(data, 'batch_size', 1, 1, 8)
        if 'chunk_duration' in data:
            number(data, 'chunk_duration', 60, 10, 60)
        if 'overlap_duration' in data:
            number(data, 'overlap_duration', 5, 1, data.get('chunk_duration', 60) - 1)
        if (not re.fullmatch(r'[a-z]{2,3}|auto', data['language'])
                or kind == 'whisperx' and data['language'] == 'auto'
                or kind == 'parakeet-mlx' and data['language'] != 'auto'):
            raise SettingsError('The selected engine does not support this language.', field='language')
    elif stage == 'live':
        data['url'] = endpoint(data, 'url', websocket=True)
        if kind == 'parakeet-local':
            from urllib.parse import urlsplit
            parsed = urlsplit(data['url'])
            if parsed.scheme != 'ws' or parsed.hostname != '127.0.0.1' or parsed.path != '/asr' or set(data) != {'url'}:
                raise SettingsError('Local Parakeet requires a local /asr endpoint.', field='url')
        if kind == 'whisperlivekit':
            from urllib.parse import urlsplit
            parsed = urlsplit(data['url'])
            if parsed.scheme != 'ws' or parsed.hostname != '127.0.0.1' or not parsed.port or parsed.path != '/asr':
                raise SettingsError('Managed WhisperLiveKit must run on 127.0.0.1 at /asr.', field='url')
            text_field(data, 'python', required=True)
            text_field(data, 'model_dir', required=True)
            number(data, 'chunk_seconds', 4, 1, 10, integer=False)
            if data.get('language', 'ru') not in {'ru', 'en', 'auto'}:
                raise SettingsError('Select ru, en, or auto.')
        if data.get('diarization'):
            from .local_stt_services import diarization_settings
            diarization_settings(data)
    elif kind == 'pyannote':
        if data.get('speaker_model') not in {'pyannote/speaker-diarization-community-1', 'pyannote/speaker-diarization-3.1'}:
            raise SettingsError('Select a prepared Pyannote model.', field='speaker_model')
        if data.get('speaker_device', 'cpu') not in {'cpu', 'mps'}:
            raise SettingsError('Choose CPU or MPS.')
        number(data, 'speaker_threads', 4, 1, 16)
        number(data, 'speaker_count', 0, 0, 32)
    else:
        data['base_url'] = endpoint(data, 'base_url')
        if stage in {'summary', 'translation'}:
            if 'model_source' in data and data['model_source'] not in ('profile', 'provider'):
                raise SettingsError('Invalid model selection mode.', field='model_source')
            if data.get('model_source') == 'provider':
                data.pop('model', None)
            else:
                text_field(data, 'model', required=not models, limit=256)
            if data.get('reasoning', 'default') not in {'default', 'off'}:
                raise SettingsError('Select default or disabled reasoning.', field='reasoning')
            if data.get('reasoning') == 'default':
                data.pop('reasoning')
        else:
            for key in ('min_speakers', 'max_speakers'):
                if key in data:
                    number(data, key, 1, 1, 32)
            if data.get('min_speakers', 1) > data.get('max_speakers', 32):
                raise SettingsError('Minimum speaker count exceeds the maximum.')
    result = {'name': name.strip(), 'stage': stage, 'kind': kind, 'settings': data}
    if value.get('id') is not None:
        if not isinstance(value['id'], str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', value['id']):
            raise SettingsError('Invalid provider profile.')
        result['id'] = value['id']
    return result


def endpoint(settings, key, *, websocket=False):
    try:
        return validate_url(settings.get(key, ''), websocket=websocket)
    except ValueError as error:
        raise SettingsError(str(error), field=key) from None


class Registry:
    def __init__(self, cfg):
        self.cfg = cfg
        self.root = cfg.layout.state_root
        self.path = self.root / 'providers.json'
        self.secrets_path = self.root / 'provider-secrets.json'

    @property
    def exists(self):
        return self.path.exists()

    def _legacy(self):
        engine = read_json(self.root / 'stt-engine.json', {})
        live = read_json(self.root / 'live-stt.json', {})
        if not isinstance(engine, dict) or not isinstance(live, dict):
            raise SettingsError('Current engine settings unavailable.', status=503)
        # Resolve exactly the defaults/runtime paths used before the registry exists.
        # Raw omissions differ between managed WhisperX and older engine profiles.
        from .local_stt import EngineConfig, TranscriptionError
        try:
            resolved = EngineConfig.load(self.cfg)
        except (TranscriptionError, ValueError, TypeError):
            raise SettingsError('Current engine settings unavailable.', status=503) from None
        engine = {key: getattr(resolved, key) for key in ENGINE_FIELDS | SPEAKER_FIELDS}
        kind = resolved.engine
        profile = {'id': 'current-stt', 'name': {'whisperkit': 'WhisperKit', 'whisperx': 'WhisperX',
                   'parakeet-mlx': 'Parakeet MLX', 'openai-compatible': 'Current STT server'}.get(kind, kind),
                   'stage': 'stt', 'kind': kind,
                   'settings': {k: v for k, v in engine.items() if k in ENGINE_FIELDS}}
        state = {'version': 1, 'revision': 0, 'profiles': [profile],
                 'effective': dict.fromkeys(STAGES)}
        state['effective']['stt'] = deepcopy(profile)
        if engine.get('speaker_model'):
            speakers = {'id': 'current-diarization', 'name': 'Pyannote on this Mac',
                        'stage': 'diarization', 'kind': 'pyannote',
                        'settings': {k: v for k, v in engine.items() if k in SPEAKER_FIELDS}}
            state['profiles'].append(speakers)
            state['effective']['diarization'] = deepcopy(speakers)
        elif profile['settings'].get('diarization_model', 'none') != 'none':
            speakers = {'id': 'current-diarization', 'name': 'Built-in STT diarization',
                        'stage': 'diarization', 'kind': 'pyannote', 'embedded': True,
                        'settings': {'speaker_model': profile['settings']['diarization_model']}}
            if engine.get('python'):
                speakers['settings']['speaker_python'] = engine['python']
            state['profiles'].append(speakers)
            state['effective']['diarization'] = deepcopy(speakers)
        if live.get('url'):
            snapshot = {'id': 'current-live', 'name': 'Current Live STT', 'stage': 'live',
                        'kind': live.get('provider', 'external'),
                        'settings': {k: v for k, v in live.items() if k in LIVE_FIELDS}}
            state['profiles'].append(snapshot)
            if live.get('enabled'):
                state['effective']['live'] = deepcopy(snapshot)
        elif (not (self.root / 'live-stt.json').exists()
              and getattr(self.cfg, 'local_transport', None) in {'ngrok', 'tailscale'}
              and not getattr(self.cfg, 'container_runtime', False)):
            from . import local_live
            preview = local_live.settings(self.cfg)
            address = f'ws://127.0.0.1:{local_live.port(self.cfg)}/asr'
            default_url = not preview.get('url') or (
                not (self.root / 'live-preview.json').exists() and preview['url'] == address)
            if preview['enabled'] and default_url:
                snapshot = {'id': 'local-parakeet-live', 'name': 'Parakeet on this Mac', 'stage': 'live',
                            'kind': 'parakeet-local',
                            'settings': {'url': address}}
                state['profiles'].append(snapshot)
                state['effective']['live'] = deepcopy(snapshot)
        return state

    def _load(self):
        state = read_json(self.path) if self.exists else self._legacy()
        if (not isinstance(state, dict) or state.get('version') != 1
                or not isinstance(state.get('profiles'), list) or not isinstance(state.get('effective'), dict)):
            raise SettingsError('Unsupported settings version.', status=503)
        return state

    @contextmanager
    def _edit(self, revision):
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock_path = self.root / '.providers.lock'
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise SettingsError('Settings are being applied. Try again later.', status=409) from None
            state = self._load()
            if type(revision) is not int or revision != state['revision']:
                raise SettingsError('Settings changed in another window. Refresh the page.', status=409)
            yield state

    @staticmethod
    def _summary_policy(profile):
        if not isinstance(profile, dict) or profile.get('stage') != 'summary':
            return profile
        settings = profile.get('settings')
        if not isinstance(settings, dict) or not follows_summary_provider(settings):
            return profile
        settings = {**settings, 'model_source': 'provider'}
        settings.pop('model', None)
        return {**profile, 'settings': settings}

    @classmethod
    def _public(cls, profile):
        if profile is None:
            return None
        public = {k: deepcopy(v) for k, v in cls._summary_policy(profile).items() if k != 'credential_ref'}
        if public['settings'].get('model_source') == 'provider':
            # The paired editor represents automatic mode by an empty model field.
            public['settings'].pop('model_source')
        return {**public, 'has_key': bool(profile.get('credential_ref'))}

    def read(self):
        state = self._load()
        effective = {stage: self._public(state['effective'].get(stage)) for stage in STAGES}
        effective['translation'] = self._public(self._translation(state))
        return {'version': 1, 'revision': state['revision'],
                'profiles': [self._public(p) for p in state['profiles']], 'effective': effective,
                'active': {stage: p['id'] if (p := state['effective'].get(stage)) else None for stage in STAGES}}

    @classmethod
    def _translation(cls, state):
        """An explicit translator overrides the connected server's active text LLM.

        Resolve only applied settings, never drafts or speech-recognition models.
        Keep the credential reference pinned to that exact model/endpoint version.
        """
        effective = state['effective']
        if effective.get('translation'):
            return deepcopy(effective['translation'])
        summary = cls._summary_policy(effective.get('summary'))
        if summary and summary['kind'] == 'openai-compatible':
            return {**deepcopy(summary), 'stage': 'translation', 'inherited_from': 'summary'}
        return None

    def snapshot(self, stage):
        if stage not in STAGES:
            raise SettingsError('Unknown processing stage.')
        state = self._load()
        return self._translation(state) if stage == 'translation' else deepcopy(self._summary_policy(state['effective'].get(stage)))

    def pipeline(self):
        state = self._load()
        pipeline = {stage: deepcopy(state['effective'].get(stage)) for stage in ('stt', 'diarization', 'summary')}
        if pipeline['summary']:
            pipeline['summary'] = self._summary_policy(pipeline['summary'])
            config = summary_templates(state)
            template = next(item for item in config['templates'] if item['id'] == config['default_template_id'])
            if template != DEFAULT_SUMMARY_TEMPLATE:
                pipeline['summary']['template'] = deepcopy(template)
        return pipeline

    def summary_settings(self, body=None):
        if body is None:
            return self._summary_settings(self._load())
        templates, default = body.get('templates'), body.get('default_template_id')
        validate_summary_templates(templates, default)
        with self._edit(body.get('revision')) as state:
            state['summary_templates'] = {'templates': templates, 'default_template_id': default}
            state['revision'] += 1
            atomic_json(self.path, state)
            return self._summary_settings(state)

    @staticmethod
    def _summary_profiles(state):
        active = state['effective'].get('summary')
        return ([active] if active else []) + [
            profile for profile in state['profiles']
            if profile['stage'] == 'summary' and (not active or profile['id'] != active['id'])
        ]

    def summary_choices(self):
        state = self._load()
        active = state['effective'].get('summary')
        profiles = []
        for row in self._summary_profiles(state):
            if row is active:
                row = self.resolve_summary(row)
            else:
                row = self._summary_policy(row)
            if row and row['settings'].get('model'):
                profiles.append(row)
        return summary_templates(state), profiles, active['id'] if active else None

    def resolve_summary(self, profile):
        """Freeze the model named by a warm, matching observation for approval-bound requests."""
        profile = self._summary_policy(profile)
        if profile is None or profile['settings'].get('model_source') != 'provider':
            return profile
        from .local_provider_health import observed_summary_model
        model = observed_summary_model(self.cfg, profile)
        if model is None:
            return None
        return {**profile, 'settings': {**profile['settings'], 'model_source': 'profile', 'model': model}}

    def _summary_settings(self, state):
        active = state['effective'].get('summary')
        profiles = []
        for row in self._summary_profiles(state):
            profile = self.resolve_summary(row) if row is active else self._summary_policy(row)
            profiles.append({'id': row['id'], 'name': row['name'], 'model': profile['settings'].get('model') if profile else None})
        return {
            **summary_templates(state), 'revision': state['revision'],
            'profiles': profiles,
            'default_profile_id': active['id'] if active else None,
        }

    def key(self, snapshot):
        ref = snapshot.get('credential_ref') if snapshot else None
        if not ref:
            return ''
        vault = read_json(self.secrets_path, {})
        if ref not in vault:
            raise SettingsError('The API key for this job is unavailable. Reconfigure the provider.',
                                status=409, code='credential_missing')
        key = vault[ref]
        auth_headers(key)
        return key

    def _draft(self, body, state, *, models=False):
        candidate = deepcopy(body.get('profile'))
        if isinstance(candidate, dict) and candidate.get('stage') == 'live' and candidate.get('kind') == 'parakeet-local':
            from . import local_live
            if getattr(self.cfg, 'container_runtime', False):
                raise SettingsError('Local Parakeet requires macOS.')
            settings = candidate.get('settings', {})
            if not isinstance(settings, dict):
                raise SettingsError('Invalid provider parameters.')
            address = f'ws://127.0.0.1:{local_live.port(self.cfg)}/asr'
            if settings.get('url', address) != address:
                raise SettingsError('Local Parakeet must use the port configured for this server.', field='url')
            candidate['settings'] = {**settings, 'url': address}
        if not models and default_summary_model_source() == 'provider':
            candidate = self._summary_policy(candidate)
        profile = validate_profile(candidate, models=models)
        previous = next((p for p in state['profiles'] if p['id'] == profile.get('id')), None)
        if previous and (previous['stage'], previous['kind']) != (profile['stage'], profile['kind']):
            raise SettingsError('Create a separate profile for a different provider type.')
        # Embedded execution is registry-owned metadata, not an editable field.
        # Editing/exporting a legacy card must not turn it into a separate worker.
        if previous and previous.get('embedded'):
            profile['embedded'] = True
        if previous and identity(previous) == identity(profile) and previous.get('credential_ref'):
            profile['credential_ref'] = previous['credential_ref']
        if body.get('clear_key'):
            profile.pop('credential_ref', None)
        key = body.get('api_key')
        if key is not None:
            auth_headers(key)
        return profile, key

    def draft(self, body, *, models=False):
        profile, key = self._draft(body, self._load(), models=models)
        return profile, key if key else self.key(profile)

    def save(self, body):
        with self._edit(body.get('revision')) as state:
            profile, key = self._draft(body, state)
            profile.setdefault('id', uuid.uuid4().hex)
            profile['configuration_revision'] = state['revision'] + 1
            if key:
                vault = read_json(self.secrets_path, {})
                ref = uuid.uuid4().hex
                vault[ref] = key
                atomic_json(self.secrets_path, vault)
                profile['credential_ref'] = ref
            found = next((i for i, p in enumerate(state['profiles']) if p['id'] == profile['id']), None)
            if found is None:
                if len(state['profiles']) >= 64:
                    raise SettingsError('The provider limit is 64.')
                state['profiles'].append(profile)
            else:
                state['profiles'][found] = profile
            state['revision'] += 1
            atomic_json(self.path, state)
        return self.read()

    def activate(self, body, *, prepare=None):
        stage = body.get('stage')
        if stage not in STAGES or (stage == 'stt' and body.get('id') is None):
            raise SettingsError('Select a transcription provider.')
        with self._edit(body.get('revision')) as state:
            selected = next((p for p in state['profiles'] if p['id'] == body.get('id') and p['stage'] == stage), None)
            if body.get('id') is not None and selected is None:
                raise SettingsError('Provider not found.', status=404)
            selected = deepcopy(self._summary_policy(selected))
            next_stt = selected if stage == 'stt' else state['effective'].get('stt')
            next_diarization = selected if stage == 'diarization' else state['effective'].get('diarization')
            if (stage in {'stt', 'diarization'} and next_diarization and next_diarization.get('embedded')
                    and (not next_stt or next_stt['kind'] not in {'whisperx', 'parakeet-mlx'})):
                raise SettingsError('Select a separate diarization provider or disable diarization first: '
                                    'this STT provider does not support built-in diarization.', status=409)
            if stage == 'stt':
                selected['settings']['diarization_model'] = (
                    next_diarization['settings']['speaker_model']
                    if next_diarization and next_diarization.get('embedded') else 'none')
            original = deepcopy(state)
            existed = self.exists
            def publish():
                state['effective'][stage] = selected
                if stage in {'stt', 'diarization'} and state['effective'].get('stt'):
                    state['effective']['stt']['settings']['diarization_model'] = (
                        next_diarization['settings']['speaker_model']
                        if next_diarization and next_diarization.get('embedded') else 'none')
                state['revision'] = original['revision'] + 1
                atomic_json(self.path, state)
            try:
                if prepare:
                    prepare(selected, publish)
                elif stage == 'live':
                    from .local_stt_services import activate
                    activate(self.cfg, selected, publish=publish, rollback=lambda: atomic_json(self.path, original))
                else:
                    from .local_provider_probe import probe
                    if selected:
                        result = probe(self.cfg, selected, key=self.key(selected))
                        if result['state'] not in {'ready', 'available'}:
                            raise SettingsError(result['message'], status=409)
                    publish()
            except Exception:
                # Preparation can publish before verifying the backend bootstrap.
                # Restore the effective selection while preserving the saved draft.
                if existed or self.exists:
                    atomic_json(self.path, original)
                raise
        return self.read()

    def delete(self, profile_id, revision):
        with self._edit(revision) as state:
            if any(p and p['id'] == profile_id for p in state['effective'].values()):
                raise SettingsError('Select another active provider or disable the stage first.', status=409)
            profiles = [p for p in state['profiles'] if p['id'] != profile_id]
            if len(profiles) == len(state['profiles']):
                raise SettingsError('Provider not found.', status=404)
            state['profiles'] = profiles
            state['revision'] += 1
            # Credential versions remain available for immutable queued snapshots.
            atomic_json(self.path, state)
        return self.read()
