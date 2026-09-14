"""Portable runtime contracts; no Docker daemon, models or network required."""
import io
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import wave

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'scripts/dev-harness'), str(ROOT / 'docker')]
import runtime
import stt
from dev_harness import config, local_env


def wav_bytes():
    out = io.BytesIO()
    with wave.open(out, 'wb') as wav:
        wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        wav.writeframes(b'\0\0' * 16000)
    return out.getvalue()


def test_timed_stt_core_and_bad_input():
    calls = []

    class Model:
        def transcribe(self, audio, **kwargs):
            calls.append(kwargs)
            segment = SimpleNamespace(start=0., end=1., text=' test',
                                      words=[SimpleNamespace(start=0., end=1., word=' test')])
            return iter([segment]), SimpleNamespace(language='en', duration=1.)

    with TestClient(stt.create_app(Model)) as client:
        assert client.get('/v1/models').json()['data'][0]['id'] == stt.MODEL
        payload = {'model': stt.MODEL, 'response_format': 'verbose_json'}
        response = client.post('/v1/audio/transcriptions', data=payload, files={'file': ('audio.wav', wav_bytes())})
        assert response.status_code == 200
        assert response.json()['segments'][0]['words'][0]['end'] == 1.
        assert calls == [{'language': None, 'word_timestamps': True, 'vad_filter': True, 'beam_size': 5}]
        assert client.post('/v1/audio/transcriptions', data=payload, files={'file': ('bad.wav', b'bad')}).status_code == 400
        payload['model'] = 'unknown'
        assert client.post('/v1/audio/transcriptions', data=payload, files={'file': ('audio.wav', wav_bytes())}).status_code == 400
        assert len(calls) == 1


def test_inference_failure_does_not_leak_content_or_keep_lock():
    class Model:
        def transcribe(self, *args, **kwargs):
            raise RuntimeError('private fixture text')
    with TestClient(stt.create_app(Model)) as client:
        for _ in range(2):
            response = client.post('/v1/audio/transcriptions', data={'model': stt.MODEL},
                                   files={'file': ('audio.wav', wav_bytes())})
            assert response.status_code == 503
            assert 'private fixture' not in response.text


def test_missing_model_or_gpu_fails_startup():
    def unavailable():
        raise RuntimeError('No CUDA or cache')
    with pytest.raises(RuntimeError):
        with TestClient(stt.create_app(unavailable)):
            pass


def test_initialization_preserves_identity_settings_and_existing_archive(tmp_path):
    root, data = tmp_path / 'repo', tmp_path / 'data'
    root.mkdir()
    data.mkdir()
    env = {'PROVIDER_MODE': 'offline', 'OMI_LOCAL_TRANSPORT': 'ngrok', 'OMI_DEV_BIND_HOST': '127.0.0.1',
           'OMI_LOCAL_INSTANCE': 'docker', 'OMI_LOCAL_STATE_ROOT': str(data / 'harness'),
           'OMI_HARNESS_PORT_OFFSET': '13000'}
    cfg = config.load_config(root, env, create_layout=True)
    capture = cfg.layout.services_dir / 'storage/listen-captures/existing'
    capture.mkdir(parents=True)
    first = runtime.prepare(cfg, root, data)
    assert config.child_env_for(cfg)['OMI_LOCAL_LIVE_PREVIEW_URL'] == ''
    live = cfg.layout.state_root / 'live-preview.json'
    live.write_text('{"enabled": true, "url": "ws://127.0.0.1:19090/asr"}')
    settings = cfg.layout.state_root / 'stt-engine.json'
    settings.write_text('{"custom": true}')
    second = runtime.prepare(cfg, root, data)
    assert first == second == local_env.read_env(root / '.env')
    assert config.child_env_for(cfg)['OMI_LOCAL_LIVE_PREVIEW_URL'] == 'ws://127.0.0.1:19090/asr'
    assert json.loads(settings.read_text()) == {'custom': True}
    assert len(json.loads((cfg.layout.state_root / 'stt-watch.json').read_text())['excluded']) == 1
    assert (root / '.env').stat().st_mode & 0o077 == 0
    assert (data / 'connection.env').stat().st_mode & 0o077 == 0


def test_backend_reload_is_explicit_and_loopback_only():
    cfg = SimpleNamespace(repo_root=ROOT, backend_port=21000)
    assert '--reload' not in runtime.backend_command(cfg)
    command = runtime.backend_command(cfg, reload=True)
    assert command[command.index('--host') + 1] == '127.0.0.1'
    assert '--no-proxy-headers' in command and '--reload' in command


def test_runtime_pins_keep_vcs_commit_and_platform_markers():
    result = subprocess.run([sys.executable, str(ROOT / 'docker/export_pins.py'),
                             str(ROOT / 'backend/pylock.runtime.toml')], capture_output=True, text=True, check=True)
    assert 'git+https://github.com/TeamPyOgg/PyOgg@6871a4f234e8a3a346c4874a12509bfa02c4c63a' in result.stdout
    assert "lc3py==1.1.3; platform_machine == 'x86_64'" in result.stdout


def test_supervisor_exit_is_detected_even_before_parent_reaps(tmp_path):
    process = tmp_path / '42'
    process.mkdir()
    (process / 'stat').write_text('42 (python worker) S 1 42 42')
    assert runtime.supervisor_running(42, tmp_path)
    (process / 'stat').write_text('42 (python worker) Z 1 42 42')
    assert not runtime.supervisor_running(42, tmp_path)
    assert not runtime.supervisor_running(43, tmp_path)


def test_shutdown_reaps_owned_children(monkeypatch):
    import os
    import time
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
    monkeypatch.setattr(runtime.cli, '_process_records', lambda cfg: [{'pid': child.pid}])

    def stop(cfg):
        child.terminate()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(child.pid, 0)
            except ProcessLookupError:
                return
            time.sleep(.05)
        pytest.fail('Exited supervisor was not reaped')

    monkeypatch.setattr(runtime.cli, '_stop_owned', stop)
    try:
        runtime.stop_owned(None)
    finally:
        child.wait(timeout=3)
