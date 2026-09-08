import json
import sys
import wave
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dev_harness import local_stt, local_parakeet, local_whisperkit


def test_whisperkit_report_is_offline_and_keeps_words(tmp_path, monkeypatch):
    audio = tmp_path / 'audio.wav'
    audio.write_bytes(b'synthetic')
    monkeypatch.setenv('OPENAI_API_KEY', 'synthetic-secret')
    monkeypatch.setattr(local_whisperkit.shutil, 'which', lambda _: '/usr/bin/sandbox-exec')
    def process(command, **kwargs):
        assert command[:3] == ['/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)']
        assert '--model-path' in command and '--download-tokenizer-path' in command
        assert command[command.index('--concurrent-worker-count') + 1] == '1'
        assert kwargs['capture_output'] and 'OPENAI_API_KEY' not in kwargs['env']
        (tmp_path / 'audio.json').write_text(json.dumps({'language': 'ru', 'segments': [{
            'text': ' Проверка.', 'start': 0.1, 'end': 0.8,
            'words': [{'word': ' Проверка.', 'start': 0.1, 'end': 0.8, 'probability': 0.9}]}]}))
        return SimpleNamespace(returncode=0)
    monkeypatch.setattr(local_whisperkit.subprocess, 'run', process)
    raw = local_whisperkit.transcribe(tmp_path, audio, tmp_path, 'ru', 1)
    segment = raw['segments'][0]
    assert segment['text'] == 'Проверка.' and segment['speaker'] == 'SPEAKER_00'
    assert segment['words'][0]['score'] == 0.9 and segment['words'][0]['end'] == 0.8


def test_whisperkit_failure_has_no_transcript_and_does_not_fall_back(tmp_path, monkeypatch):
    monkeypatch.setattr(local_whisperkit.shutil, 'which', lambda _: '/usr/bin/sandbox-exec')
    monkeypatch.setattr(local_whisperkit.subprocess, 'run', lambda *a, **kw:
                        SimpleNamespace(returncode=1, stdout=b'private synthetic speech'))
    with pytest.raises(local_whisperkit.WhisperKitError, match='original WAV retained') as error:
        local_whisperkit.transcribe(tmp_path, tmp_path / 'audio.wav', tmp_path, 'ru', 1)
    assert 'private' not in str(error.value)
    monkeypatch.setattr(local_whisperkit.shutil, 'which', lambda _: None)
    with pytest.raises(local_whisperkit.WhisperKitError, match='sandbox-exec'):
        local_whisperkit.transcribe(tmp_path, tmp_path / 'audio.wav', tmp_path, 'ru', 1)


@pytest.mark.parametrize('end', [float('nan'), 3, -1, True])
def test_whisperkit_rejects_invalid_timestamps(end):
    with pytest.raises(local_whisperkit.WhisperKitError):
        local_whisperkit.normalize({'language': 'ru', 'segments': [
            {'text': 'Synthetic', 'start': 0.1, 'end': end}]}, 1)


def test_pinned_queue_profile_does_not_inherit_another_engine_runtime(tmp_path):
    settings = cfg(tmp_path)
    settings.repo_root = tmp_path
    path = settings.layout.state_root / 'stt-engine.json'
    path.write_text(json.dumps({'engine': 'whisperkit', 'language': 'ru'}))
    current = local_stt.EngineConfig.load(settings)
    assert current.assets_path == str(tmp_path / '.local/whisperkit')
    assert current.profile()['engine'] == 'whisperkit'
    assert 'compute_type' not in current.profile()
    legacy = local_stt.EngineConfig(engine='whisperx', diarization_model='none')
    old_job = local_stt.EngineConfig.load(settings, profile=legacy.profile())
    assert old_job.engine == 'whisperx' and not old_job.assets_path
    path.write_text(json.dumps({'engine': 'whisperx', 'python': '/old/python', 'diarization_model': 'none'}))
    retried = local_stt.EngineConfig.load(settings, profile=current.profile())
    assert retried.engine == 'whisperkit' and not retried.python
    assert retried.assets_path == current.assets_path


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
    monkeypatch.setattr(local_stt.shutil, 'which', lambda tool: '/test/ffmpeg' if tool == 'ffmpeg' else None)
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
    monkeypatch.setenv('HF_HOME', '/tmp/models')
    monkeypatch.setenv('HF_HUB_CACHE', '/tmp/hub')
    monkeypatch.setenv('TORCH_HOME', '/tmp/torch')
    monkeypatch.setenv('NLTK_DATA', '/tmp/nltk-data')
    monkeypatch.setenv('HF_HUB_OFFLINE', '0')
    monkeypatch.setattr(local_stt.shutil, 'which', lambda _: None)
    env = local_stt.model_environment(local_stt.EngineConfig())
    assert not {'OPENAI_API_KEY', 'HF_TOKEN', 'OMI_LOCAL_PAIRING_FILE'} & env.keys()
    assert env['HF_HUB_OFFLINE'] == '1'
    assert env['HF_HOME'] == '/tmp/models'
    assert env['HF_HUB_CACHE'] == '/tmp/hub'
    assert env['TORCH_HOME'] == '/tmp/torch'
    assert env['NLTK_DATA'] == '/tmp/nltk-data'


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
    monkeypatch.setattr(local_stt.shutil, 'which', lambda _: None)
    monkeypatch.setattr(local_stt.subprocess, 'run', lambda *a, **k: SimpleNamespace(returncode=1))
    imports = []
    monkeypatch.setattr(local_stt, 'backend_step', lambda _cfg, folder=None: imports.append(folder) or {})
    audio = audio_file(tmp_path)
    with pytest.raises(local_stt.TranscriptionError):
        local_stt.transcribe(settings, str(audio))
    assert imports == [None] and audio.exists()
    assert not list(settings.layout.services_dir.glob('local-transcripts/*/audio.json'))


@pytest.mark.parametrize('diarization', ['none', 'pyannote/speaker-diarization-community-1'])
def test_whisperx_diarization_mode_controls_cli_speakers_and_cache_identity(tmp_path, monkeypatch, diarization):
    settings = cfg(tmp_path)
    (settings.layout.state_root / 'stt-engine.json').write_text(json.dumps({'diarization_model': diarization}))
    engine = local_stt.EngineConfig.load(settings)
    monkeypatch.setattr(local_stt, 'check_model', lambda _: Path('/fixture/python'))
    monkeypatch.setattr(local_stt.shutil, 'which', lambda _: None)
    commands = []
    def process(command, **kwargs):
        commands.append(command)
        output = Path(command[command.index('--output_dir') + 1])
        (output / 'audio.json').write_text(json.dumps({
            'segments': [{'text': 'Fixture', 'start': 0, 'end': 1,
                          'words': [{'word': 'Fixture', 'start': 0, 'end': 1}]}]}))
        return SimpleNamespace(returncode=0)
    monkeypatch.setattr(local_stt.subprocess, 'run', process)
    audio = audio_file(tmp_path)
    raw = local_stt.run_whisperx(engine, audio, tmp_path, local_stt.inspect_audio(audio))
    assert ('--diarize' in commands[0]) == (diarization != 'none')
    if diarization == 'none':
        assert raw['segments'][0]['speaker'] == 'SPEAKER_00'
        assert raw['segments'][0]['words'][0]['speaker'] == 'SPEAKER_00'
        assert engine.profile()['diarization_model'] == 'none'
        assert engine.profile() != local_stt.EngineConfig().profile()
    else:
        assert engine.profile() == local_stt.EngineConfig().profile()


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


@pytest.mark.parametrize('explicit', [False, True])
def test_model_finds_ffmpeg_in_another_prefix_or_respects_override(tmp_path, monkeypatch, explicit):
    prefix = tmp_path / 'Other Brew' / 'ffmpeg@7'
    libraries = prefix / 'lib'
    libraries.mkdir(parents=True)
    calls = []
    monkeypatch.setattr(local_stt.shutil, 'which', lambda name: '/test/brew' if name == 'brew' else None)
    def find(command, **kwargs):
        calls.append(command)
        return SimpleNamespace(returncode=0, stdout=str(prefix) + '\n')
    monkeypatch.setattr(local_stt.subprocess, 'run', find)
    engine = local_stt.EngineConfig(library_path=str(libraries) if explicit else '')
    assert local_stt.model_environment(engine)['DYLD_LIBRARY_PATH'] == str(libraries)
    assert calls == ([] if explicit else [['/test/brew', '--prefix', 'ffmpeg@7']])


def test_model_uses_libraries_next_to_ffmpeg_when_no_brew(tmp_path, monkeypatch):
    binary = tmp_path / 'ffmpeg/bin/ffmpeg'
    binary.parent.mkdir(parents=True)
    binary.write_text('fixture')
    (binary.parent.parent / 'lib').mkdir()
    monkeypatch.setattr(local_stt.shutil, 'which', lambda name: str(binary) if name == 'ffmpeg' else None)
    assert local_stt.ffmpeg_library_path(local_stt.EngineConfig()) == str(binary.parent.parent / 'lib')
