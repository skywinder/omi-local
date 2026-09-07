import json
import sys
import wave
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dev_harness import local_stt


def audio_file(tmp_path):
    path = tmp_path / 'test.wav'
    with wave.open(str(path), 'wb') as wav:
        wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        wav.writeframes(b'\0\0' * 16000)
    return path


def cfg(tmp_path):
    state = tmp_path / 'state'
    state.mkdir(exist_ok=True)
    return SimpleNamespace(provider_mode='offline', local_transport='ngrok',
                           layout=SimpleNamespace(state_root=state, services_dir=state / 'services'))


def test_import_retry_reuses_finished_engine_output_and_model_change_is_separate(tmp_path, monkeypatch):
    settings = cfg(tmp_path)
    audio = audio_file(tmp_path)
    python = tmp_path / 'python'
    python.write_text('fixture')
    python.chmod(0o700)
    profile_path = settings.layout.state_root / 'stt-engine.json'
    profile_path.write_text(json.dumps({'python': str(python)}))
    monkeypatch.setattr(local_stt.shutil, 'which', lambda _: '/test/ffmpeg')
    calls = []
    def process(command, **kwargs):
        calls.append(command)
        if '-m' in command:
            output = Path(command[command.index('--output_dir') + 1])
            (output / 'audio.json').write_text(json.dumps({'segments': [{'text': 'Synthetic fixture'}]}))
        return SimpleNamespace(returncode=0)
    monkeypatch.setattr(local_stt.subprocess, 'run', process)
    def unavailable(cfg, result_dir=None):
        if result_dir:
            raise local_stt.TranscriptionError('database temporarily unavailable')
        return {'preflight': 'passed'}
    monkeypatch.setattr(local_stt, 'backend_step', unavailable)
    with pytest.raises(local_stt.TranscriptionError):
        local_stt.transcribe(settings, str(audio))
    assert len(calls) == 2
    monkeypatch.setattr(local_stt, 'backend_step', lambda *_: {'import': 'passed'})
    assert local_stt.transcribe(settings, str(audio)) == 0
    assert len(calls) == 2
    profile_path.write_text(json.dumps({'python': str(python), 'model': 'small'}))
    assert local_stt.transcribe(settings, str(audio)) == 0
    assert len(calls) == 4
    assert '--model' in calls[-1] and 'small' in calls[-1]
    assert len(list(settings.layout.services_dir.glob('local-transcripts/*/audio.json'))) == 2


def test_failed_engine_keeps_audio_and_does_not_import(tmp_path, monkeypatch):
    settings = cfg(tmp_path)
    audio = audio_file(tmp_path)
    original = audio.read_bytes()
    monkeypatch.setattr(local_stt, 'backend_step', lambda *args: {'preflight': 'passed'})
    monkeypatch.setattr(local_stt.Path, 'home', lambda: tmp_path)
    with pytest.raises(local_stt.TranscriptionError):
        local_stt.transcribe(settings, str(audio))
    assert audio.read_bytes() == original
    assert not list(settings.layout.services_dir.glob('local-transcripts/*/audio.json'))


def test_model_process_does_not_receive_backend_or_provider_credentials(monkeypatch):
    monkeypatch.setenv('OPENAI_API_KEY', 'synthetic-secret')
    monkeypatch.setenv('HF_TOKEN', 'synthetic-secret')
    monkeypatch.setenv('OMI_LOCAL_PAIRING_FILE', '/private/example')
    env = local_stt.model_environment(local_stt.EngineConfig())
    assert not {'OPENAI_API_KEY', 'HF_TOKEN', 'OMI_LOCAL_PAIRING_FILE'} & env.keys()
    assert env['HF_HUB_OFFLINE'] == '1'


def test_completed_capture_with_stale_metadata_is_accepted_but_active_pcm_is_not(tmp_path):
    audio = audio_file(tmp_path)
    metadata = {'status': 'completed', 'decode_errors': 0, 'duration_seconds': 1,
                'started_at': '2026-01-01T00:00:00Z', 'source': 'phone'}
    audio.with_name('metadata.json').write_text(json.dumps(metadata))
    audio.with_name('metadata.json.part').write_text('stale progress')
    assert local_stt.inspect_audio(audio)['source'] == 'phone'
    audio.with_name('audio.pcm.part').write_bytes(b'\0\0')
    with pytest.raises(local_stt.TranscriptionError):
        local_stt.inspect_audio(audio)
