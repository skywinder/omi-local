import json
import sys
import wave
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dev_harness import local_stt, local_parakeet


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


def test_parakeet_selection_dispatch_and_existing_whisper_profile_stays_compatible(tmp_path, monkeypatch):
    settings = cfg(tmp_path)
    assert local_stt.EngineConfig().profile() == {
        'engine': 'whisperx', 'model': 'large-v3-turbo', 'language': 'ru', 'compute_type': 'float32', 'batch_size': 1}
    path = settings.layout.state_root / 'stt-engine.json'
    path.write_text(json.dumps({'engine': 'parakeet-mlx'}))
    engine = local_stt.EngineConfig.load(settings)
    assert engine.device == 'gpu' and engine.compute_type == 'float32' and engine.language == 'auto'
    calls = []
    monkeypatch.setattr(local_stt, 'run_parakeet', lambda e, *args: calls.append(e.profile()) or {
        'segments': [{'text': 'Fixture', 'start': 0, 'end': 1}]})
    monkeypatch.setattr(local_stt, 'backend_step', lambda *_: {'import': 'passed'})
    local_stt.transcribe(settings, str(audio_file(tmp_path)))
    assert calls == [engine.profile()]
    path.write_text(json.dumps({'engine': 'parakeet-mlx', 'compute_type': 'int8'}))
    with pytest.raises(local_stt.TranscriptionError):
        local_stt.EngineConfig.load(settings)
    path.write_text(json.dumps({'engine': 'parakeet-mlx', 'diarization_model': 'none'}))
    assert local_stt.EngineConfig.load(settings).profile()['diarization_model'] == 'none'


def test_parakeet_failed_process_never_imports_or_writes_raw_result(tmp_path, monkeypatch):
    settings = cfg(tmp_path)
    (settings.layout.state_root / 'stt-engine.json').write_text(json.dumps({'engine': 'parakeet-mlx'}))
    monkeypatch.setattr(local_stt, 'check_model', lambda _: Path('/fixture/python'))
    monkeypatch.setattr(local_stt.subprocess, 'run', lambda *a, **k: SimpleNamespace(returncode=1))
    imports = []
    monkeypatch.setattr(local_stt, 'backend_step', lambda _cfg, folder=None: imports.append(folder) or {})
    audio = audio_file(tmp_path)
    with pytest.raises(local_stt.TranscriptionError):
        local_stt.transcribe(settings, str(audio))
    assert imports == [None] and audio.exists()
    assert not list(settings.layout.services_dir.glob('local-transcripts/*/audio.json'))


def test_parakeet_subwords_preserve_text_and_actual_speaker_boundaries():
    tokens = [SimpleNamespace(text=' Про', start=0.0, end=0.2),
              SimpleNamespace(text='верка.', start=0.2, end=0.6),
              SimpleNamespace(text=' Да.', start=1.0, end=1.4)]
    words = local_parakeet.timed_words(tokens, 2)
    assert [w['word'] for w in words] == ['Проверка.', 'Да.']
    segments = [{'words': words}]
    local_parakeet.assign_speakers(segments, [(0, 0.8, 'SPEAKER_00'), (0.9, 1.6, 'SPEAKER_01')])
    assert [w['speaker'] for w in words] == ['SPEAKER_00', 'SPEAKER_01']
    assert segments[0]['speaker'] is None
    local_parakeet.assign_speakers(segments, [])
    assert all(w['speaker'] is None for w in words)
    local_parakeet.single_speaker(segments)
    assert segments[0]['speaker'] == 'SPEAKER_00'
    assert all(w['speaker'] == 'SPEAKER_00' for w in words)
    with pytest.raises(ValueError):
        local_parakeet.timed_words([SimpleNamespace(text='bad', start=0, end=float('nan'))], 2)
