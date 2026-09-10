"""Owned local STT services. Live and finished-WAV providers are independent."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import subprocess
import time
from urllib.parse import urlsplit

import httpx

from . import local_openai_stt


class ServiceError(ValueError):
    """Content-free diagnostics suitable for the local launcher."""


def settings(cfg, filename):
    path = cfg.layout.state_root / filename
    return json.loads(path.read_text()) if path.exists() else {}


def live_settings(cfg):
    data = settings(cfg, 'live-stt.json')
    if not data or not data.get('enabled', False):
        return {}
    try:
        url = urlsplit(data['url'])
        if (url.scheme != 'ws' or url.hostname != '127.0.0.1' or not url.port or url.path != '/asr'
                or url.query or url.fragment or url.username or url.password
                or data['provider'] not in {'external', 'whisperlivekit'}):
            raise ValueError()
        if data['provider'] == 'whisperlivekit':
            chunk = data.get('chunk_seconds', 4)
            if type(chunk) not in (int, float) or not 1 <= chunk <= 10:
                raise ValueError()
            if data.get('language', 'ru') not in {'ru', 'en', 'auto'}:
                raise ValueError()
        return data
    except (KeyError, TypeError, ValueError):
        raise ServiceError('Invalid local live STT settings') from None


def live_url(cfg):
    return live_settings(cfg).get('url', '')


def health(cfg, service):
    try:
        with httpx.Client(trust_env=False, follow_redirects=False, timeout=2) as client:
            if service == 'live-stt':
                url = live_url(cfg).replace('ws://', 'http://').removesuffix('/asr') + '/health'
                response = client.get(url)
                data = response.json()
                return response.status_code == 200 and data.get('ready') is True, 'live STT readiness'
            data = settings(cfg, 'argmax-stt.json')
            local_openai_stt.check(f"http://127.0.0.1:{data['port']}/v1", data['model'])
            return True, 'Argmax model ready'
    except (httpx.HTTPError, ValueError, KeyError):
        return False, 'STT service unavailable'


def start_configured(cfg):
    from . import cli, config
    if cfg.provider_mode != 'offline' or cfg.local_transport != 'ngrok':
        return
    argmax = settings(cfg, 'argmax-stt.json')
    live = live_settings(cfg)
    commands = []
    if argmax.get('enabled'):
        port = argmax['port']
        local_openai_stt.validate_url(f'http://127.0.0.1:{port}/v1')
        for key in ('binary', 'model_dir', 'tokenizer_dir'):
            Path(argmax[key]).resolve(strict=True)
        commands.append(('argmax-stt', [sys.executable, str(Path(__file__).with_name('run_argmax.py')),
                                      '--settings', str(cfg.layout.state_root / 'argmax-stt.json')],
                         cfg.repo_root, port))
    if live.get('provider') == 'whisperlivekit':
        python = Path(live['python']).expanduser().absolute()
        if not python.is_file():
            raise ServiceError('Live STT Python is unavailable')
        model = Path(live['model_dir']).resolve(strict=True)
        root = cfg.layout.services_dir / 'local-transcripts'
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        (root / '.lock').touch(mode=0o600, exist_ok=True)
        commands.append(('live-stt', [str(python), '-m', 'local_live_preview.serve',
                                    '--model-dir', str(model), '--inference-lock', str(root / '.lock'),
                                    '--port', str(urlsplit(live['url']).port),
                                    '--language', live.get('language', 'ru'),
                                    '--chunk-seconds', str(live.get('chunk_seconds', 4))],
                         cfg.repo_root / 'scripts', urlsplit(live['url']).port))
    for name, command, cwd, port in commands:
        env = config.child_env_for(cfg)
        env['OMI_HARNESS_PRIVATE_UMASK'] = '077'
        cli._start_process(cfg, name, command, cwd=cwd, log_name=name + '.log', port=port, env=env)
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            if health(cfg, name)[0]:
                break
            record = cli._service_record(cfg, name)
            if record is None:
                raise ServiceError('Local STT process exited before readiness')
            observer = subprocess.run(['ps', '-p', str(record['pid']), '-o', 'stat='],
                                      capture_output=True, text=True, timeout=5)
            if observer.returncode == 0 and observer.stdout.strip().startswith('Z'):
                raise ServiceError('Local STT process exited before readiness')
            time.sleep(1)
        else:
            raise ServiceError('Local STT startup did not become ready; inspect owned service diagnostics')


def apply(cfg):
    """Validate idle capture before restarting only the owned backend."""
    from . import cli, local_env
    data = local_env.read_env(cfg.repo_root / '.env')
    # Credentials remain transient and never enter process arguments or diagnostics.
    def require_idle():
        with httpx.Client(trust_env=False, follow_redirects=False, timeout=5) as client:
            response = client.get(cfg.backend_url + '/v1/local/status',
                                  headers={'Authorization': 'Bearer ' + data['OMI_LOCAL_APP_KEY']})
            if response.status_code != 200 or response.json()['capture']['state'] != 'idle':
                raise ServiceError('Stop the current recording before applying STT settings')
    require_idle()
    start_configured(cfg)
    require_idle()  # Model startup may take minutes; recheck immediately before restart.
    record = cli._service_record(cfg, 'backend')
    if record is None:
        raise ServiceError('Owned backend is unavailable')
    cli._stop_single_service(cfg, record)
    cli._start_app_services(cfg)
    for _ in range(30):
        if cli._service_health(cfg, "backend")[0]:
            return
        time.sleep(1)
    raise ServiceError("Backend readiness is indeterminate after applying STT")
