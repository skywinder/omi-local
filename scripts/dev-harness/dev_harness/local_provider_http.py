"""Explicit provider destinations; never inherit proxy credentials or redirect audio."""
from __future__ import annotations

import ipaddress
import math
import os
import time
from urllib.parse import urlsplit

import httpx


PRIVATE_NETWORKS = tuple(ipaddress.ip_network(value) for value in (
    '127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
    '100.64.0.0/10', '::1/128', 'fc00::/7',
))


class ProviderResponseError(ValueError):
    """A fixed diagnostic and a safe code, without a provider URL or body."""

    def __init__(self, code, message):
        super().__init__(message)
        self.diagnostic_code = code


def default_summary_model_source():
    return 'provider' if os.environ.get('OMI_SUMMARY_MODEL_DEFAULT') == 'provider' else 'profile'


def follows_summary_provider(settings, *, allow_legacy_default=True):
    source = settings.get('model_source')
    return source == 'provider' or (source is None and (
        not settings.get('model') or
        allow_legacy_default and default_summary_model_source() == 'provider'
    ))


def summary_model(client, base):
    """Select a usable text model from the configured provider's catalogue."""
    response = metadata_get(client, validate_url(base) + '/models')
    if response.status_code in {404, 405, 503}:
        raise ProviderResponseError(f'http_{response.status_code}', 'Список моделей суммаризации недоступен.')
    data = json_response(response)
    valid_ids = set(model_ids(data))
    first = None
    non_text = ('embedding', 'embeddings', 'rerank', 'reranker', 'transcription', 'stt', 'speech', 'tts')
    for row in data['data'][:2000]:
        if not isinstance(row, dict) or not isinstance(model := row.get('id'), str) or model not in valid_ids:
            continue
        status = row.get('status')
        if isinstance(status, dict):
            status = status.get('value')
        if status in ('unloaded', 'loading', 'failed', 'unavailable') or row.get('type') in non_text:
            continue
        capabilities = row.get('capabilities')
        if isinstance(capabilities, list) and capabilities and all(item in non_text for item in capabilities):
            continue
        if status in ('loaded', 'ready', 'running'):
            return model
        first = first or model
    if first:
        return first
    raise ProviderResponseError('summary_model_unavailable', 'Нет доступных моделей суммаризации.')


def rejected_response(status):
    return ProviderResponseError(f'http_{status}', 'Сервер отклонил запрос. Проверьте адрес, ключ и модель.')


def private_address(value):
    address = ipaddress.ip_address(value)
    return any(address.version == network.version and address in network for network in PRIVATE_NETWORKS)


def validate_url(value, *, websocket=False):
    """Allow TLS publicly and plain transport only to explicit local/VPN addresses."""
    message = 'Укажите HTTPS/WSS адрес сервера; HTTP/WS доступны только для Mac и LAN/VPN.'
    try:
        if not isinstance(value, str) or len(value) > 2048 or any(ord(c) < 33 for c in value):
            raise ValueError()
        parsed = urlsplit(value)
        schemes = {'ws', 'wss'} if websocket else {'http', 'https'}
        if (parsed.scheme not in schemes or not parsed.hostname or parsed.username is not None
                or parsed.password is not None or parsed.query or parsed.fragment or '\\' in value
                or parsed.port == 0):
            raise ValueError()
        try:
            address = ipaddress.ip_address(parsed.hostname)
        except ValueError:
            address = None
        if address is not None and (address.is_link_local or address.is_multicast or address.is_unspecified):
            raise ValueError()
        if parsed.scheme in {'http', 'ws'}:
            if address is not None:
                if not private_address(str(address)):
                    raise ValueError()
            elif parsed.hostname != 'localhost':
                # A second DNS lookup by the client must not change this decision.
                # Use a private IP for plain LAN/VPN transport; names require TLS.
                raise ValueError()
        return value.rstrip('/')
    except (ValueError, TypeError, OSError):
        raise ProviderResponseError('configuration', message) from None


def auth_headers(key):
    if not isinstance(key, str) or len(key) > 8192 or any(ord(c) < 32 or ord(c) > 126 for c in key):
        raise ProviderResponseError('configuration', 'Недопустимый API-ключ.')
    return {'Authorization': 'Bearer ' + key} if key else {}


def client(*, key='', timeout=10):
    return httpx.Client(trust_env=False, follow_redirects=False, timeout=timeout, headers=auth_headers(key))


def metadata_get(client, url, *, limit=2 * 1024 * 1024, deadline_seconds=15):
    chunks, size = [], 0
    deadline = time.monotonic() + deadline_seconds
    with client.stream('GET', url) as response:
        for chunk in response.iter_bytes():
            size += len(chunk)
            if time.monotonic() > deadline:
                raise ProviderResponseError('timeout', 'Превышено время ожидания ответа сервера.')
            if size > limit:
                raise ProviderResponseError('response_too_large', 'Ответ сервера слишком большой.')
            chunks.append(chunk)
        return httpx.Response(response.status_code, content=b''.join(chunks))


def post_json(client, url, *, limit=2 * 1024 * 1024, deadline_seconds=180, **kwargs):
    """Read a bounded provider response before parsing it or retaining its content.

    HTTPX's timeout is per I/O operation. Check elapsed time between chunks as
    well, so a provider cannot keep a job alive by indefinitely trickling bytes.
    Request identity encoding: decoding a compressed chunk before checking its
    size could allocate an arbitrarily large intermediate buffer.
    """
    if type(limit) is not int or limit <= 0 or not math.isfinite(deadline_seconds) or deadline_seconds <= 0:
        raise ValueError('Недопустимые ограничения ответа сервера.')
    deadline = time.monotonic() + deadline_seconds
    timeout = {name: min(value, deadline_seconds) if value is not None else deadline_seconds
               for name, value in client.timeout.as_dict().items()}
    try:
        with client.stream('POST', url, headers={'Accept-Encoding': 'identity'},
                           timeout=httpx.Timeout(**timeout), follow_redirects=False, **kwargs) as response:
            if not 200 <= response.status_code < 300:
                raise rejected_response(response.status_code)
            if response.headers.get('Content-Encoding', 'identity').lower().strip() not in {'', 'identity'}:
                raise ProviderResponseError('response_encoding', 'Сервер вернул неподдерживаемый ответ.')
            body = bytearray()
            for chunk in response.iter_bytes():
                if time.monotonic() > deadline:
                    raise ProviderResponseError('timeout', 'Превышено время ожидания ответа сервера.')
                if len(chunk) > limit - len(body):
                    raise ProviderResponseError('response_too_large', 'Ответ сервера слишком большой.')
                body.extend(chunk)
            if time.monotonic() > deadline:
                raise ProviderResponseError('timeout', 'Превышено время ожидания ответа сервера.')
            # Deliberately discard upstream headers, request URL and credentials.
            return json_response(httpx.Response(response.status_code, content=bytes(body)), limit=limit)
    except httpx.TimeoutException:
        raise ProviderResponseError('timeout', 'Превышено время ожидания ответа сервера.') from None
    except (httpx.HTTPError, OSError):
        raise ProviderResponseError('connection', 'Не удалось получить ответ сервера.') from None


def json_response(response, *, limit=2 * 1024 * 1024):
    if not 200 <= response.status_code < 300:
        raise rejected_response(response.status_code)
    if len(response.content) > limit:
        raise ProviderResponseError('response_too_large', 'Ответ сервера слишком большой.')
    try:
        value = response.json()
    except (ValueError, TypeError):
        raise ProviderResponseError('invalid_json', 'Сервер вернул неподдерживаемый ответ.') from None
    if not isinstance(value, dict):
        raise ProviderResponseError('invalid_provider_response', 'Сервер вернул неподдерживаемый ответ.')
    return value


def model_ids(data):
    rows = data.get('data')
    if not isinstance(rows, list):
        raise ProviderResponseError('invalid_provider_response', 'Сервер не предоставил список моделей.')
    return sorted({row['id'] for row in rows[:2000] if isinstance(row, dict)
                   and isinstance(row.get('id'), str) and 0 < len(row['id']) <= 256
                   and row['id'].strip() and row['id'].isprintable()})
