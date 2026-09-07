"""One finished WAV -> existing WhisperX CLI -> paired local Conversation."""

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

from . import config


class TranscriptionError(ValueError):
    """Diagnostics contain no transcript, user identifier or subprocess output."""


@dataclass(frozen=True)
class EngineConfig:
    """Only the engine adapter consumes these settings; Omi receives segments.

    To add a different engine, add its adapter returning the documented JSON
    contract. Audio validation, result persistence and Conversation import stay
    the same. Models must already be installed; this command never installs them.
    """

    engine: str = 'whisperx'
    model: str = 'large-v3-turbo'
    language: str = 'ru'
    compute_type: str = 'float32'
    batch_size: int = 1
    python: str = ''
    library_path: str = '/opt/homebrew/opt/ffmpeg@7/lib'

    @classmethod
    def load(cls, cfg):
        path = cfg.layout.state_root / 'stt-engine.json'
        data = json.loads(path.read_text()) if path.exists() else {}
        engine = cls(**data)
        if (engine.engine != 'whisperx' or not re.fullmatch(r'[A-Za-z0-9_./-]+', engine.model)
                or not re.fullmatch(r'[a-z]{2,3}', engine.language)
                or engine.compute_type not in {'float32', 'int8', 'int8_float32'}
                or type(engine.batch_size) is not int or not 1 <= engine.batch_size <= 8):
            raise TranscriptionError('Invalid local STT engine settings')
        return engine

    def profile(self):
        return {key: value for key, value in asdict(self).items() if key not in {'python', 'library_path'}}


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


def model_environment(engine: EngineConfig) -> dict[str, str]:
    env = {key: os.environ[key] for key in ('HOME', 'PATH', 'TMPDIR', 'LANG') if key in os.environ}
    env.update({
        'DYLD_LIBRARY_PATH': engine.library_path,
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


def run_whisperx(engine: EngineConfig, audio: Path, folder: Path, manifest: dict) -> dict:
    """Engine adapter: completed WAV in, segments/words/language JSON out."""
    python = Path(engine.python).expanduser() if engine.python else Path.home() / '.venvs/whisperx/bin/python'
    if not python.is_file() or not os.access(python, os.X_OK) or shutil.which('ffmpeg') is None:
        raise TranscriptionError('Existing WhisperX Python or ffmpeg is unavailable')
    env = model_environment(engine)
    probe = subprocess.run([str(python), '-c', 'import torchcodec, whisperx.transcribe, pyannote.audio'],
                           env=env, capture_output=True, timeout=60)
    if probe.returncode:
        raise TranscriptionError('WhisperX imports failed; check its existing FFmpeg library path')
    print('WhisperX: processing finished WAV locally...', flush=True)
    with tempfile.TemporaryDirectory(dir=folder, prefix='.inference-') as temporary:
        temp = Path(temporary)
        shutil.copyfile(audio, temp / 'audio.wav')
        # Protect against the source changing between preflight and copy.
        with (temp / 'audio.wav').open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != manifest['audio_sha256']:
                raise TranscriptionError('WAV changed during preparation')
        command = [str(python), '-m', 'whisperx', str(temp / 'audio.wav'), '--model', engine.model,
                   '--language', engine.language, '--device', 'cpu', '--compute_type', engine.compute_type,
                   '--batch_size', str(engine.batch_size),
                   '--diarize', '--model_cache_only', 'True', '--output_format', 'json', '--output_dir', temporary]
        outcome = subprocess.run(command, env=env, capture_output=True, timeout=3600)
        if outcome.returncode or not (temp / 'audio.json').is_file():
            raise TranscriptionError('WhisperX failed; original WAV retained, no conversation created')
        raw = json.loads((temp / 'audio.json').read_text())
        if not isinstance(raw, dict) or not raw.get('segments'):
            raise TranscriptionError('No speech segments returned; no conversation created')
        return raw


def transcribe(cfg, audio_path: str) -> int:
    if cfg.provider_mode != 'offline' or cfg.local_transport != 'ngrok':
        raise TranscriptionError('Use the paired local Mac offline stack')
    audio = Path(audio_path).expanduser().resolve()
    manifest = inspect_audio(audio)
    engine = EngineConfig.load(cfg)
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
            raise TranscriptionError('Another local transcription is running') from None
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
            raw = run_whisperx(engine, audio, folder, manifest)
            atomic_json(raw_path, raw)
            print(f'WhisperX finished in {time.monotonic() - started:.1f}s; importing transcript...', flush=True)
        result = backend_step(cfg, folder)
        print(json.dumps({**result, 'reused_transcript': reused}, ensure_ascii=False))
        print('Refresh Conversations in the app and open the local recording.')
    return 0
