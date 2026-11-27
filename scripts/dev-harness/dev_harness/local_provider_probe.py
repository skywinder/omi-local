"""Metadata-only checks. A reachable server is not evidence of successful inference."""
from __future__ import annotations

import subprocess
import time
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import httpx

from . import local_provider_http as transport


def probe(cfg, profile, *, key='', models=False):
    started = time.monotonic()
    def result(state, message, **extra):
        return {'state': state, 'message': message,
                'latency_ms': round((time.monotonic() - started) * 1000), **extra}
    kind, stage, settings = profile['kind'], profile['stage'], profile['settings']
    try:
        if stage == 'stt' and kind != 'openai-compatible':
            from .local_stt import EngineConfig, check_model
            engine = EngineConfig.load(cfg, profile={'engine': kind, **settings})
            check_model(engine)
            return result('available', 'Local files and dependencies verified. Process a recording to verify transcription.',
                          models=[engine.model])
        if kind == 'pyannote':
            python = Path(settings.get('speaker_python') or cfg.repo_root / '.local/diarization/venv/bin/python').expanduser()
            if not python.is_file():
                return result('misconfigured', 'Local diarization Python executable missing. Select a prepared environment.')
            program = ("import sys; import importlib.util; "
                       "sys.addaudithook(lambda event,args: (_ for _ in ()).throw(RuntimeError()) "
                       "if event in {'socket.connect','socket.getaddrinfo'} else None); "
                       "assert importlib.util.find_spec('pyannote.audio'); "
                       "from huggingface_hub import snapshot_download; "
                       "snapshot_download(sys.argv[1],local_files_only=True)")
            checked = subprocess.run([str(python), '-c', program, settings['speaker_model']],
                                     capture_output=True, timeout=30)
            if checked.returncode:
                return result('misconfigured', 'Pyannote environment or model cache unavailable. No downloads were attempted.')
            return result('available', 'Pyannote cache found. Process a recording to verify the model.',
                          models=[settings['speaker_model']])
        if stage in {'stt', 'summary', 'translation'}:
            base = transport.validate_url(settings.get('provider_url') or settings.get('base_url', ''))
            with transport.client(key=key, timeout=8) as client:
                if not models and (stage == 'summary' or profile.get('inherited_from') == 'summary'):
                    if transport.follows_summary_provider(settings):
                        model = transport.summary_model(client, base)
                        return result('ready', 'Provider model available.', models=[model], model=model)
                response = transport.metadata_get(client, base + '/models')
                if response.status_code in {404, 405}:
                    return result('available', 'Server reachable. Enter a model manually because model listing is unavailable.', models=[])
                catalogue = transport.model_ids(transport.json_response(response))
            model = settings.get('model')
            if model and model not in catalogue and not models:
                return result('misconfigured', 'The selected model is missing from the server list.', models=catalogue)
            return result('ready', 'Server and model list available. Inference has not been tested.', models=catalogue)
        if stage == 'live':
            base = transport.validate_url(settings['url'], websocket=True)
            parsed = urlsplit(base)
            endpoint = urlunsplit(('https' if parsed.scheme == 'wss' else 'http', parsed.netloc,
                                  parsed.path.rsplit('/', 1)[0] + '/health', '', ''))
        else:
            base = transport.validate_url(settings['base_url'])
            endpoint = base + '/ready'
        with transport.client(key=key, timeout=8) as client:
            response = transport.metadata_get(client, endpoint)
            if stage == 'diarization' and response.status_code in {404, 405}:
                response = transport.metadata_get(client, base + '/health')
            if stage == 'live' and response.status_code in {404, 405}:
                return result('available', 'Server reachable without a /health endpoint. The protocol will be checked on connection.')
            if response.status_code == 503:
                return result('unavailable', 'Server pending. The model is loading or unavailable.')
            data = transport.json_response(response)
        if data.get('ready') is True:
            return result('ready', 'The server reports that the model is ready.')
        if data.get('ready') is False:
            return result('unavailable', 'The server reports that the model is not ready.')
        return result('available', 'Server reachable. Model readiness unconfirmed.')
    except transport.ProviderResponseError as error:
        return result('misconfigured' if error.diagnostic_code == 'configuration' else 'unavailable', str(error))
    except subprocess.TimeoutExpired:
        return result('unavailable', 'Local environment check timed out.')
    except (httpx.HTTPError, OSError):
        return result('unavailable', 'Cannot reach the server. Check its address and availability.')
    except (ValueError, KeyError, TypeError):
        return result('misconfigured', 'Check the address, key, model, and protocol compatibility.')
