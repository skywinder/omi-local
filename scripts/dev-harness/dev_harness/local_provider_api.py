"""Settings operations served exclusively by the library's same-origin admin routes."""
from copy import deepcopy
import re

import httpx

from .local_providers import Registry, SettingsError
from .local_provider_probe import probe
from .local_recording_chat import answer_recording, chat_provider, daily_recap, suggest_tasks
from . import local_summary_regeneration


class Settings:
    def __init__(self, cfg):
        self.cfg = cfg
        self.registry = Registry(cfg)

    def read(self):
        return self.registry.read()

    def live_tuning(self, body=None):
        return self._live_tuning_request(body)

    def live_tuning_next_session(self, body):
        return self._live_tuning_request(body, next_session=True)

    def _live_tuning_request(self, body, *, next_session=False):
        from .local_provider_relay import port
        try:
            with httpx.Client(trust_env=False, follow_redirects=False, timeout=8) as client:
                endpoint = f'http://127.0.0.1:{port(self.cfg)}/tuning'
                if next_session:
                    endpoint += '/next-session'
                response = client.get(endpoint) if body is None else client.post(endpoint, json=body)
                data = response.json()
                if response.is_error:
                    raise SettingsError(data.get('error', 'Настройки недоступны.'),
                                        status=response.status_code, field=data.get('field'))
                return data
        except SettingsError:
            raise
        except (httpx.HTTPError, ValueError):
            message = ('Результат сохранения не подтверждён. Обновите настройки и проверьте значение.'
                       if next_session else 'Нет связи с сервисом Live. Проверьте, что он запущен.')
            raise SettingsError(message, status=503) from None

    def dispatch(self, method, path, body):
        if not isinstance(body, dict):
            raise SettingsError('Ожидается объект настроек.')
        if method == 'POST':
            if path == '/api/settings/summary-settings':
                return self.registry.summary_settings(body)
            if path == '/api/settings/live-tuning':
                return self.live_tuning(body)
            if path == '/api/settings/save':
                return self.registry.save(body)
            if path == '/api/settings/activate':
                return self.registry.activate(body)
            if path in {'/api/settings/probe', '/api/settings/models'}:
                profile, key = self.registry.draft(body, models=path.endswith('/models'))
                return probe(self.cfg, profile, key=key, models=path.endswith('/models'))
        if method == 'DELETE' and path.startswith('/api/settings/profiles/'):
            return self.registry.delete(path.rsplit('/', 1)[-1], body.get('revision'))
        raise SettingsError('Не найдено.', status=404)


class Processing(Settings):
    """Paired-phone controls: select prepared engines, edit network adapters only."""

    STAGES = {'live', 'stt', 'diarization'}
    FIELDS = {
        ('live', 'external'): {'url'},
        ('stt', 'openai-compatible'): {'provider_url', 'model', 'language', 'device', 'diarization_model'},
        ('diarization', 'mycelia'): {'base_url', 'min_speakers', 'max_speakers'},
    }
    PRIVATE_FIELDS = {'python', 'model_dir', 'library_path', 'assets_path', 'speaker_python'}

    def __init__(self, cfg, summary_jobs=None):
        super().__init__(cfg)
        self.summary_jobs = summary_jobs

    @classmethod
    def can_edit(cls, profile):
        if not isinstance(profile, dict):
            return False
        fields = cls.FIELDS.get((profile.get('stage'), profile.get('kind')))
        settings = profile.get('settings', {})
        return (fields is not None and isinstance(settings, dict) and not set(settings) - fields
                and settings.get('diarization_model', 'none') == 'none')

    @classmethod
    def public(cls, state):
        result = deepcopy(state)
        for profile in [*result['profiles'], *result['effective'].values()]:
            if profile is None:
                continue
            profile['can_edit'] = cls.can_edit(profile)
            settings = profile.get('settings', {})
            for key in cls.PRIVATE_FIELDS:
                settings.pop(key, None)
            if isinstance(settings.get('diarization'), dict):
                settings['diarization'].pop('python', None)
        return result

    def read(self):
        return self.public(self.registry.read())

    def recording_chat_provider(self):
        return chat_provider(self.registry)

    def summary_regeneration_options(self):
        return local_summary_regeneration.options(self.registry)

    def dispatch(self, method, path, body):
        if not isinstance(body, dict):
            raise SettingsError('Ожидается объект настроек.')
        operation = path.removeprefix('/api/processing/')
        if method == 'POST' and operation == 'daily-recap':
            return daily_recap(self.registry, body)
        if method == 'POST' and operation == 'regenerate-summary':
            return local_summary_regeneration.regenerate(self.registry, body)
        if method == 'POST' and self.summary_jobs is not None:
            if operation == 'summary-job':
                return self.summary_jobs.submit(body)
            if operation == 'summary-job-status':
                return self.summary_jobs.status(body) if 'request_id' in body else self.summary_jobs.latest(body)
        if method == 'POST' and operation == 'summary-settings':
            return self.registry.summary_settings(body)
        if method == 'POST' and operation in {'recording-chat', 'archive-chat'}:
            return answer_recording(self.registry, body, archive=operation == 'archive-chat')
        if method == 'POST' and operation == 'task-suggestions':
            return suggest_tasks(self.registry, body)
        if method == 'POST' and operation == 'live-tuning':
            return self.live_tuning_next_session(body)
        if method == 'POST' and operation in {'save', 'probe', 'models'}:
            profile = body.get('profile')
            if not self.can_edit(profile):
                raise SettingsError('Этот профиль настраивается на сервере. В приложении можно выбрать подготовленный профиль.', status=403)
            previous = next((p for p in self.registry.read()['profiles'] if p['id'] == profile.get('id')), None)
            if previous and not self.can_edit(previous):
                raise SettingsError('Подготовленный локальный профиль доступен только для выбора.', status=403)
        elif method == 'POST' and operation == 'activate':
            if body.get('stage') not in self.STAGES:
                raise SettingsError('Выберите этап распознавания или диаризации.')
        elif method == 'DELETE' and re.fullmatch(r'profiles/[A-Za-z0-9_-]{1,64}', operation):
            previous = next((p for p in self.registry.read()['profiles'] if p['id'] == operation.rsplit('/', 1)[-1]), None)
            if previous and not self.can_edit(previous):
                raise SettingsError('Подготовленный локальный профиль удаляется на сервере.', status=403)
        else:
            raise SettingsError('Не найдено.', status=404)
        result = super().dispatch(method, '/api/settings/' + operation, body)
        return self.public(result) if 'profiles' in result else result
