"""Owned loopback live-preview service for the paired Mac stack."""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import stat
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit


class LocalLiveError(ValueError):
    """Fixed diagnostics only; never include paths, credentials or server bodies."""


def port(cfg) -> int:
    value = 6090 + cfg.backend_port - 8000
    if not 1024 <= value <= 65535:
        raise LocalLiveError('Live preview port is outside the supported range')
    return value


def settings(cfg) -> dict:
    path = cfg.layout.state_root / 'live-preview.json'
    try:
        if path.is_symlink():
            raise ValueError('symlink')
        if path.exists():
            data = json.loads(path.read_text())
        else:
            data = {'enabled': True}
            if os.environ.get('OMI_LOCAL_LIVE_PREVIEW_URL'):
                data['url'] = os.environ['OMI_LOCAL_LIVE_PREVIEW_URL']
        if not isinstance(data, dict) or type(data.get('enabled')) is not bool:
            raise ValueError('enabled')
        if set(data) - {'enabled', 'url'}:
            raise ValueError('keys')
        if 'url' in data:
            address = urlsplit(data['url'])
            if (address.scheme != 'ws' or address.hostname != '127.0.0.1'
                    or address.username or address.password or address.path != '/asr'
                    or address.query or address.fragment or not 1024 <= (address.port or 80) <= 65535):
                raise ValueError('url')
        return data
    except (OSError, ValueError, TypeError, AttributeError):
        raise LocalLiveError('Invalid live-preview.json; use enabled and an optional loopback /asr URL') from None


def managed(cfg) -> bool:
    if configured_endpoint(cfg) is not None:
        return False
    data = settings(cfg)
    return data['enabled'] and not data.get('url')


def endpoint(cfg) -> str:
    data = settings(cfg)
    if not data['enabled']:
        return ''
    return data.get('url') or f'ws://127.0.0.1:{port(cfg)}/asr'


def configured_endpoint(cfg) -> str | None:
    """None means no provider choice; an empty URL is an explicit off choice."""
    from .local_stt_services import live_url

    if (cfg.layout.state_root / 'live-stt.json').exists():
        return live_url(cfg)
    return None


def selected_endpoint(cfg) -> str:
    """Return the live endpoint selected for the backend child process."""
    configured = configured_endpoint(cfg)
    return endpoint(cfg) if configured is None else configured


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def health(cfg) -> dict:
    address = selected_endpoint(cfg)
    if not address:
        return {}
    host = urlsplit(address)
    url = f'http://127.0.0.1:{host.port}/health'
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
        with opener.open(url, timeout=2) as response:
            if response.status != 200:
                return {}
            data = json.loads(response.read(65536))
        if (not isinstance(data, dict) or type(data.get('ready')) is not bool
                or type(data.get('active', False)) is not bool):
            return {}
        return {key: data.get(key) is True for key in ('ready', 'active', 'recovering')}
    except (OSError, ValueError, urllib.error.URLError):
        return {}


def require_ready(cfg) -> None:
    if not selected_endpoint(cfg):
        return
    if not health(cfg).get('ready'):
        raise LocalLiveError('Live transcription is not ready; inspect live-preview status and its startup event')


def require_backend_environment(cfg) -> None:
    """A running backend cannot acquire a different URL by editing its parent env."""
    from . import cli

    record = cli._service_record(cfg, 'backend')
    if record and record.get('local_live_preview_url') != selected_endpoint(cfg):
        raise LocalLiveError('Backend uses earlier live settings; finish recording, run local-mac.sh down, then start again')


def inference_lock_path(cfg) -> Path:
    path = cfg.layout.services_dir / 'local-transcripts' / '.lock'
    for item in (path, *path.parents):
        if item == cfg.repo_root:
            break
        if item.is_symlink():
            raise LocalLiveError('Unsafe shared inference lock path')
    return path


def prepare_inference_lock(cfg) -> Path:
    from . import safety

    safety.read_and_validate_sentinel(cfg.layout.state_root, repo_root=cfg.repo_root, instance=cfg.instance)
    path = inference_lock_path(cfg)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise LocalLiveError('Shared inference lock must be a regular file')
    finally:
        os.close(fd)
    return path


def preflight_start(cfg) -> None:
    from . import cli
    from .local_stt_services import live_settings

    if configured_endpoint(cfg) is not None:
        configured = live_settings(cfg)
        # Configured native providers are started by start_configured; an
        # external provider must already be ready. Neither owns Parakeet's port.
        if configured.get('provider') == 'external':
            require_ready(cfg)
        return

    if not settings(cfg)['enabled']:
        return
    if not managed(cfg):
        require_ready(cfg)
        return
    cli._require_port_available_or_owned(cfg, 'live-preview', port(cfg))
    record = cli._service_record(cfg, 'live-preview')
    if record:
        observed = health(cfg)
        if not observed:
            raise LocalLiveError('Live process state is indeterminate; inspect its owned status before restarting')
        if observed.get('ready') or observed.get('recovering') or observed.get('active'):
            return
    # Only observe here; the native worker acquires this same lock during loading.
    lock_path = inference_lock_path(cfg)
    if lock_path.exists():
        try:
            with lock_path.open('r') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(lock, fcntl.LOCK_UN)
        except BlockingIOError:
            raise LocalLiveError('Final transcription is busy; wait for it to finish before starting live preview') from None


def start(cfg) -> None:
    from . import cli, local_live_install

    if configured_endpoint(cfg) is not None:
        return
    if not settings(cfg)['enabled']:
        return
    preflight_start(cfg)
    if not managed(cfg):
        return
    worker, model = local_live_install.installed(cfg.repo_root)
    existing = cli._service_record(cfg, 'live-preview')
    observed = health(cfg) if existing else {}
    if not existing or not any(observed.get(key) for key in ('ready', 'active', 'recovering')):
        lock_path = prepare_inference_lock(cfg)
        cli._start_process(
            cfg, 'live-preview',
            [sys.executable, '-m', 'local_live_preview.serve_parakeet', '--worker', str(worker),
             '--model-dir', str(model), '--inference-lock',
             str(lock_path), '--port', str(port(cfg))],
            cwd=cfg.repo_root / 'scripts', log_name='live-preview.log', port=port(cfg),
        )
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if health(cfg).get('ready'):
            return
        if not cli._service_record(cfg, 'live-preview'):
            raise LocalLiveError('Live startup failed; inspect the startup_failed event in the owned live-preview log')
        time.sleep(0.25)
    raise LocalLiveError('Live readiness is indeterminate after waiting; inspect the owned live-preview status')
