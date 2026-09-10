"""One finished WAV -> configured local engine -> paired local Conversation."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import wave
from datetime import datetime, timezone
from dataclasses import dataclass, asdict
from pathlib import Path

from . import config, stt_install, local_whisperkit, local_openai_stt


class TranscriptionError(ValueError):
    """Diagnostics contain no transcript, user identifier or subprocess output."""


class TranscriptionBusy(TranscriptionError):
    """The shared inference slot is occupied; retry without counting a failure."""


class NoSpeechDetected(TranscriptionError):
    """A successful, cached inference found no speech; do not retry or import."""


@dataclass(frozen=True)
class EngineConfig:
    """Only the engine adapter consumes these settings; Omi receives segments.

    To add a different engine, add its adapter returning the documented JSON
    contract. Audio validation, result persistence and Conversation import stay
    the same. Models must already be installed; this command never installs them.
    """

    provider_url: str = ''
    engine: str = 'whisperx'
    model: str = 'large-v3-turbo'
    language: str = 'ru'
    compute_type: str = 'float32'
    batch_size: int = 1
    python: str = ''
    library_path: str = ''
    assets_path: str = ''
    runtime_revision: str = ''
    device: str = 'cpu'
    chunk_duration: int = 60
    overlap_duration: int = 5
    diarization_model: str = 'pyannote/speaker-diarization-community-1'

    @classmethod
    def load(cls, cfg, *, profile=None):
        path = cfg.layout.state_root / 'stt-engine.json'
        data = json.loads(path.read_text()) if path.exists() else {}
        if profile is not None:
            # Queue profiles pin the engine, but runtime paths belong to that engine.
            # Never inherit a WhisperKit directory/Python override across providers.
            data = {**(data if data.get('engine', 'whisperx') == profile['engine'] else {}), **profile}
        repo_root = getattr(cfg, 'repo_root', None)
        managed = repo_root / '.local/stt' if repo_root is not None else None
        standard = (not data or (data.get('model', 'large-v3-turbo') == 'large-v3-turbo'
                                and data.get('language', 'ru') == 'ru' and data.get('diarization_model') == 'none'))
        if (standard and data.get('engine', 'whisperx') == 'whisperx'
                and not data.get('python') and managed is not None and managed.exists()):
            python = stt_install.installed(managed)
            if python is None:
                raise TranscriptionError('Managed WhisperX is incomplete; run bash scripts/install-local-stt.sh')
            data = {'diarization_model': 'none', **data, 'python': str(python),
                    'assets_path': str(managed / 'assets'), 'runtime_revision': stt_install.fingerprint()}
        if data.get('engine') == 'parakeet-mlx':
            data = {'model': 'mlx-community/parakeet-tdt-0.6b-v3', 'language': 'auto', 'device': 'gpu', **data}
        if data.get('engine') == 'whisperkit':
            if not data.get('assets_path') and repo_root is None:
                raise TranscriptionError('WhisperKit requires a local repository/runtime path')
            root = Path(data['assets_path']).expanduser() if data.get('assets_path') else repo_root / '.local/whisperkit'
            data = {'model': local_whisperkit.MODEL, 'device': 'cpuAndNeuralEngine',
                    'diarization_model': 'none', **data, 'assets_path': str(root),
                    'runtime_revision': local_whisperkit.runtime_revision(root)}
        if data.get('engine') == 'openai-compatible':
            data = {'language': 'auto', 'device': 'server', 'diarization_model': 'none', **data}
            local_openai_stt.validate_url(data.get('provider_url', ''))
        engine = cls(**data)
        if (engine.engine not in {'whisperx', 'parakeet-mlx', 'whisperkit', 'openai-compatible'} or not re.fullmatch(r'[A-Za-z0-9_./-]+', engine.model)
                or not (re.fullmatch(r'[a-z]{2,3}', engine.language) or engine.language == 'auto')
                or engine.compute_type not in {'float32', 'int8', 'int8_float32'}
                or type(engine.batch_size) is not int or not 1 <= engine.batch_size <= 8):
            raise TranscriptionError('Invalid local STT engine settings')
        if engine.engine == 'openai-compatible':
            if engine.device != 'server' or engine.diarization_model != 'none':
                raise TranscriptionError('Custom STT requires server device and single-speaker mode')
        elif engine.engine == 'whisperkit':
            if (engine.model != local_whisperkit.MODEL or engine.device != 'cpuAndNeuralEngine'
                    or engine.diarization_model != 'none' or engine.python or engine.library_path):
                raise TranscriptionError('WhisperKit requires the prepared Core ML turbo model and single-speaker mode')
        elif engine.engine == 'parakeet-mlx':
            if (engine.compute_type != 'float32' or engine.device != 'gpu' or engine.language != 'auto'
                    or type(engine.chunk_duration) is not int or not 10 <= engine.chunk_duration <= 60
                    or type(engine.overlap_duration) is not int or not 1 <= engine.overlap_duration < engine.chunk_duration
                    or engine.diarization_model not in {'pyannote/speaker-diarization-community-1', 'none'}):
                raise TranscriptionError('Parakeet requires GPU/float32/auto language and bounded overlapping chunks')
        elif (engine.language == 'auto' or engine.device != 'cpu'
              or engine.diarization_model not in {'pyannote/speaker-diarization-community-1', 'none'}):
            raise TranscriptionError('WhisperX requires CPU, explicit language and a supported diarization mode')
        return engine

    def profile(self):
        excluded = {'python', 'library_path', 'assets_path'}
        if self.engine != 'openai-compatible':
            excluded.add('provider_url')
        else:
            excluded.update({'compute_type', 'batch_size', 'chunk_duration', 'overlap_duration'})
        if not self.runtime_revision:
            excluded.add('runtime_revision')
        if self.engine == 'whisperx':
            # Preserve existing result keys and pinned queue entries exactly.
            excluded.update({'device', 'chunk_duration', 'overlap_duration'})
            if self.diarization_model != 'none':
                excluded.add('diarization_model')
        if self.engine == 'whisperkit':
            excluded.update({'compute_type', 'batch_size', 'chunk_duration', 'overlap_duration'})
        return {key: value for key, value in asdict(self).items() if key not in excluded}


def atomic_json(path: Path, data: dict) -> None:
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.transcript-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, ensure_ascii=False, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


def inspect_audio(path: Path) -> dict:
    if not path.is_file() or path.suffix.lower() != '.wav':
        raise TranscriptionError('Choose a completed WAV file')
    with wave.open(str(path)) as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, 16000, 'NONE'):
            raise TranscriptionError('Expected PCM16 mono 16 kHz WAV')
        duration = audio.getnframes() / audio.getframerate()
        if not 0 < duration <= 14400:
            raise TranscriptionError('Expected a nonempty recording up to four hours')
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    started = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat()
    source = 'omi'
    metadata = path.with_name('metadata.json')
    if metadata.exists():
        data = json.loads(metadata.read_text())
        if data.get('status') != 'completed' or data.get('decode_errors') != 0 or path.with_name('audio.pcm.part').exists():
            raise TranscriptionError('Capture is unfinished or has decode errors')
        if abs(data['duration_seconds'] - duration) > 0.001 or data['source'] not in {'omi', 'phone'}:
            raise TranscriptionError('Capture metadata does not match WAV')
        started, source = data['started_at'], data['source']
    return {'version': 1, 'audio_sha256': digest, 'duration_seconds': duration, 'started_at': started, 'source': source}


def ffmpeg_library_path(engine: EngineConfig) -> str:
    if engine.library_path:
        return str(Path(engine.library_path).expanduser())
    # The existing WhisperX/TorchCodec combination needs FFmpeg 7 libraries.
    # Find their installed location without fixing it to one Homebrew prefix.
    if brew := shutil.which('brew'):
        found = subprocess.run([brew, '--prefix', 'ffmpeg@7'], capture_output=True, text=True, timeout=10)
        if found.returncode == 0 and found.stdout.strip():
            libraries = Path(found.stdout.strip()) / 'lib'
            if libraries.is_dir():
                return str(libraries)
    if ffmpeg := shutil.which('ffmpeg'):
        libraries = Path(ffmpeg).resolve().parent.parent / 'lib'
        if libraries.is_dir():
            return str(libraries)
    return ''


def model_environment(engine: EngineConfig) -> dict[str, str]:
    cache_keys = ('HF_HOME', 'HF_HUB_CACHE', 'TRANSFORMERS_CACHE', 'TORCH_HOME', 'XDG_CACHE_HOME', 'NLTK_DATA')
    env = {key: os.environ[key] for key in ('HOME', 'PATH', 'TMPDIR', 'LANG', *cache_keys) if key in os.environ}
    if libraries := ffmpeg_library_path(engine):
        env['DYLD_LIBRARY_PATH'] = libraries
    env.update({
        'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1', 'HF_HUB_DISABLE_TELEMETRY': '1',
        'PYANNOTE_METRICS_ENABLED': '0', 'DO_NOT_TRACK': '1', 'TOKENIZERS_PARALLELISM': 'false',
    })
    return env


def backend_step(cfg, result_dir: Path | None = None) -> dict:
    env = config.child_env_for(cfg)
    env['PYTHONPATH'] = str(cfg.repo_root / 'backend')
    command = [sys.executable, '-m', 'scripts.import_local_transcript']
    if result_dir is not None:
        command.append(str(result_dir))
    completed = subprocess.run(command, cwd=cfg.repo_root / 'backend', env=env, capture_output=True, text=True, timeout=60)
    if completed.returncode:
        raise TranscriptionError('Local database/import preflight failed; result retained for retry')
    try:
        return json.loads(completed.stdout)
    except ValueError:
        raise TranscriptionError('Local import returned an invalid response') from None


def check_model(engine: EngineConfig) -> Path:
    if engine.engine == 'openai-compatible':
        try:
            local_openai_stt.check(engine.provider_url, engine.model)
        except local_openai_stt.ProviderError as error:
            raise TranscriptionError(str(error)) from None
        return Path(sys.executable)
    if engine.engine == 'whisperkit':
        try:
            binary = local_whisperkit.installed(Path(engine.assets_path))
            if engine.runtime_revision and engine.runtime_revision != local_whisperkit.runtime_revision(Path(engine.assets_path)):
                raise TranscriptionError('WhisperKit runtime changed after the job was prepared')
            probe = subprocess.run(local_whisperkit.offline([str(binary), '--help']),
                                   env=local_whisperkit.environment(), capture_output=True, timeout=30)
            if probe.returncode:
                raise TranscriptionError('WhisperKit executable preflight failed')
            return binary
        except local_whisperkit.WhisperKitError as error:
            raise TranscriptionError(str(error)) from None
    default = 'parakeet_env/bin/python' if engine.engine == 'parakeet-mlx' else '.venvs/whisperx/bin/python'
    python = Path(engine.python).expanduser() if engine.python else Path.home() / default
    if not python.is_file() or not os.access(python, os.X_OK) or shutil.which('ffmpeg') is None:
        raise TranscriptionError('Configured local STT Python or ffmpeg is unavailable')
    env = model_environment(engine)
    if engine.engine == 'parakeet-mlx':
        command = [str(python), str(Path(__file__).with_name('local_parakeet.py')), '--check',
                   '--model', engine.model, '--diarization-model', engine.diarization_model]
        probe = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90)
        try:
            passed = probe.returncode == 0 and json.loads(probe.stdout).get('status') == 'passed'
        except ValueError:
            passed = False
        if not passed:
            raise TranscriptionError('Parakeet GPU/dependency/cache preflight failed; no model downloads attempted')
        return python
    if engine.assets_path:
        if (engine.model, engine.language, engine.diarization_model) != ('large-v3-turbo', 'ru', 'none'):
            raise TranscriptionError('Managed WhisperX supplies large-v3-turbo/ru/one speaker; use an explicit Python for another prepared model')
        command = [str(python), str(Path(__file__).with_name('local_whisperx.py')),
                   '--quick-check', '--assets', engine.assets_path]
        probe = subprocess.run(stt_install.offline_command(command, env),
                               env=env, capture_output=True, timeout=60)
        if probe.returncode:
            raise TranscriptionError('WhisperX dependencies/assets failed verification; run bash scripts/install-local-stt.sh')
        return python
    probe = subprocess.run([str(python), '-c', 'import torchcodec, whisperx.transcribe, pyannote.audio'],
                           env=env, capture_output=True, timeout=60)
    if probe.returncode:
        raise TranscriptionError('WhisperX imports failed; check its existing FFmpeg library path')
    return python


def run_parakeet(engine: EngineConfig, audio: Path, folder: Path, manifest: dict) -> dict:
    python = check_model(engine)
    mode = 'single-speaker output' if engine.diarization_model == 'none' else 'then local diarization'
    print(f'Parakeet-MLX: GPU/FP32 transcription, {mode}...', flush=True)
    with tempfile.TemporaryDirectory(dir=folder, prefix='.inference-') as temporary:
        temp = Path(temporary)
        shutil.copyfile(audio, temp / 'audio.wav')
        with (temp / 'audio.wav').open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != manifest['audio_sha256']:
                raise TranscriptionError('WAV changed during preparation')
        command = [str(python), str(Path(__file__).with_name('local_parakeet.py')),
                   '--audio', str(temp / 'audio.wav'), '--output', str(temp / 'audio.json'),
                   '--model', engine.model, '--diarization-model', engine.diarization_model,
                   '--chunk-duration', str(engine.chunk_duration), '--overlap-duration', str(engine.overlap_duration)]
        outcome = subprocess.run(command, env=model_environment(engine), capture_output=True, text=True, timeout=3600)
        if outcome.returncode or not (temp / 'audio.json').is_file():
            raise TranscriptionError('Parakeet/diarization failed; original WAV retained, no conversation created')
        raw = json.loads((temp / 'audio.json').read_text())
        if not isinstance(raw, dict) or not raw.get('segments'):
            raise TranscriptionError('No speech segments returned; no conversation created')
        return raw


def run_whisperx(engine: EngineConfig, audio: Path, folder: Path, manifest: dict) -> dict:
    """Engine adapter: completed WAV in, segments/words/language JSON out."""
    python = check_model(engine)
    env = model_environment(engine)
    print('WhisperX: processing finished WAV locally...', flush=True)
    with tempfile.TemporaryDirectory(dir=folder, prefix='.inference-') as temporary:
        temp = Path(temporary)
        shutil.copyfile(audio, temp / 'audio.wav')
        # Protect against the source changing between preflight and copy.
        with (temp / 'audio.wav').open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != manifest['audio_sha256']:
                raise TranscriptionError('WAV changed during preparation')
        entrypoint = ([str(Path(__file__).with_name('local_whisperx.py')), '--assets', engine.assets_path]
                      if engine.assets_path else ['-m', 'whisperx'])
        command = [str(python), *entrypoint, str(temp / 'audio.wav'), '--model', engine.model,
                   '--language', engine.language, '--device', 'cpu', '--compute_type', engine.compute_type,
                   '--batch_size', str(engine.batch_size),
                   '--model_cache_only', 'True', '--output_format', 'json', '--output_dir', temporary]
        if engine.diarization_model != 'none':
            command.append('--diarize')
        if engine.assets_path:
            command = stt_install.offline_command(command, env)
        outcome = subprocess.run(command, env=env, capture_output=True, timeout=3600)
        if outcome.returncode or not (temp / 'audio.json').is_file():
            raise TranscriptionError('WhisperX failed; original WAV retained, no conversation created')
        raw = json.loads((temp / 'audio.json').read_text())
        if not isinstance(raw, dict) or not raw.get('segments'):
            raise TranscriptionError('No speech segments returned; no conversation created')
        if engine.diarization_model == 'none':
            for segment in raw['segments']:
                segment['speaker'] = 'SPEAKER_00'
                for word in segment.get('words', []):
                    word['speaker'] = 'SPEAKER_00'
        return raw


def run_whisperkit(engine: EngineConfig, audio: Path, folder: Path, manifest: dict) -> dict:
    check_model(engine)
    print('WhisperKit: processing finished WAV locally...', flush=True)
    with tempfile.TemporaryDirectory(dir=folder, prefix='.inference-') as temporary:
        temp = Path(temporary)
        shutil.copyfile(audio, temp / 'audio.wav')
        if stt_install.digest(temp / 'audio.wav') != manifest['audio_sha256']:
            raise TranscriptionError('WAV changed during preparation')
        try:
            return local_whisperkit.transcribe(Path(engine.assets_path), temp / 'audio.wav', temp,
                                               engine.language, manifest['duration_seconds'])
        except local_whisperkit.WhisperKitError as error:
            raise TranscriptionError(str(error)) from None


def run_openai(engine: EngineConfig, audio: Path, folder: Path, manifest: dict) -> dict:
    check_model(engine)
    with tempfile.TemporaryDirectory(dir=folder, prefix='.inference-') as temporary:
        snapshot = Path(temporary) / 'audio.wav'
        shutil.copyfile(audio, snapshot)
        if stt_install.digest(snapshot) != manifest['audio_sha256']:
            raise TranscriptionError('WAV changed during preparation')
        try:
            return local_openai_stt.transcribe(engine.provider_url, engine.model, engine.language,
                                               snapshot, manifest['duration_seconds'])
        except local_openai_stt.ProviderError as error:
            raise TranscriptionError(str(error)) from None


def transcribe(cfg, audio_path: str, *, engine: EngineConfig | None = None) -> int:
    if cfg.provider_mode != 'offline' or cfg.local_transport != 'ngrok':
        raise TranscriptionError('Use the paired local Mac offline stack')
    audio = Path(audio_path).expanduser().resolve()
    manifest = inspect_audio(audio)
    engine = engine or EngineConfig.load(cfg)
    manifest['profile'] = engine.profile()
    manifest['result_key'] = hashlib.sha256(
        (manifest['audio_sha256'] + json.dumps(engine.profile(), sort_keys=True)).encode()
    ).hexdigest()
    backend_step(cfg)  # Actual paired-owner/database read before ML or result writes.
    root = cfg.layout.services_dir / 'local-transcripts'
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_fd = os.open(root / '.lock', os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(lock_fd, 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise TranscriptionBusy('Another local transcription is running') from None
        folder = root / manifest['result_key']
        folder.mkdir(mode=0o700, exist_ok=True)
        manifest_path, raw_path = folder / 'manifest.json', folder / 'audio.json'
        if manifest_path.exists():
            saved = json.loads(manifest_path.read_text())
            if saved['audio_sha256'] != manifest['audio_sha256'] or saved['profile'] != manifest['profile']:
                raise TranscriptionError('Saved result belongs to another audio/model profile')
            manifest = saved
        else:
            atomic_json(manifest_path, manifest)
        reused = raw_path.exists()
        if not reused:
            started = time.monotonic()
            adapter = {'whisperx': run_whisperx, 'parakeet-mlx': run_parakeet, 'whisperkit': run_whisperkit, 'openai-compatible': run_openai}[engine.engine]
            raw = adapter(engine, audio, folder, manifest)
            atomic_json(raw_path, raw)
        else:
            raw = json.loads(raw_path.read_text())
        if raw.get('outcome') == 'no_speech' and raw.get('segments') == []:
            raise NoSpeechDetected('No speech detected; original WAV retained')
        if not reused:
            print(f'Local STT finished in {time.monotonic() - started:.1f}s; importing transcript...', flush=True)
        result = backend_step(cfg, folder)
        print(json.dumps({**result, 'reused_transcript': reused}, ensure_ascii=False))
        print('Refresh Conversations in the app and open the local recording.')
    return 0
