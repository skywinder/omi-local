"""Settings operations served exclusively by the library's same-origin admin routes."""
from .local_providers import Registry, SettingsError
from .local_provider_probe import probe


class Settings:
    def __init__(self, cfg):
        self.cfg = cfg
        self.registry = Registry(cfg)

    def read(self):
        return self.registry.read()

    def dispatch(self, method, path, body):
        if not isinstance(body, dict):
            raise SettingsError('Ожидается объект настроек.')
        if method == 'POST':
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
