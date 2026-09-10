"""Pinned WhisperKit CLI: local model files and network-denied inference."""

from __future__ import annotations

import json
import hashlib
import math
import os
from pathlib import Path
import shutil
import subprocess

from . import stt_install

SOURCE = Path(__file__).resolve().parents[1]
MODEL = 'openai_whisper-large-v3-v20240930_626MB'


class WhisperKitError(ValueError):
    """Only fixed diagnostics; CLI output can contain private speech."""


def recipe():
    return json.loads((SOURCE / 'whisperkit-models.json').read_text())


def revision():
    return stt_install.digest(SOURCE / 'whisperkit-models.json')


def runtime_revision(root: Path):
    try:
        executable = json.loads((root / 'ready.json').read_text())['executable_sha256']
    except (OSError, ValueError, KeyError):
        executable = 'unprepared'
    return hashlib.sha256((revision() + executable + stt_install.digest(Path(__file__))).encode()).hexdigest()


def environment():
    return {key: os.environ[key] for key in ('HOME', 'PATH', 'TMPDIR', 'LANG') if key in os.environ}


def offline(command):
    sandbox = shutil.which('sandbox-exec')
    if not sandbox:
        raise WhisperKitError('WhisperKit requires macOS sandbox-exec for offline inference')
    return [sandbox, '-p', '(version 1)(allow default)(deny network*)', *command]


def installed(root: Path) -> Path:
    try:
        ready = json.loads((root / 'ready.json').read_text())
        if ready['revision'] != revision():
            raise ValueError('revision')
        expected = {asset['path'] for asset in recipe()['assets']} | {'bin/whisperkit-cli'}
        if set(ready['files']) != expected:
            raise ValueError('files')
        for name, stat in ready['files'].items():
            path = root / name
            if path.is_symlink() or [path.stat().st_size, path.stat().st_mtime_ns] != stat:
                raise ValueError('changed')
        binary = root / 'bin/whisperkit-cli'
        if not os.access(binary, os.X_OK) or stt_install.digest(binary) != ready['executable_sha256']:
            raise ValueError('executable')
        return binary
    except (OSError, ValueError, KeyError, TypeError):
        raise WhisperKitError('WhisperKit is incomplete or changed; run bash scripts/install-local-whisperkit.sh') from None


def normalize(raw: dict, duration: float) -> dict:
    """Map WhisperKit word probabilities to the existing local word contract."""
    def timestamp(value, *, allow_padding=False):
        if (type(value) not in (int, float) or not math.isfinite(value)
                or value < 0 or (not allow_padding and value > duration + 0.1)):
            raise WhisperKitError('WhisperKit returned invalid timestamps')
        return value

    try:
        segments = []
        previous = 0
        # WhisperKit's pinned VAD chunker slices consecutive audio chunks, then
        # appends their reports. `seek` is the chunk/window offset in 16 kHz
        # samples. A hypothesis in one chunk's padding can land inside the full
        # WAV, so use the next offset as its source-audio boundary as well.
        seeks = sorted({segment['seek'] for segment in raw['segments']
                        if type(segment.get('seek')) is int and segment['seek'] >= 0})
        source_ends = {seek: min(duration, seeks[index + 1] / 16000)
                       for index, seek in enumerate(seeks[:-1])}
        for segment in raw['segments']:
            text = segment['text'].strip()
            if not text:
                continue
            start = timestamp(segment['start'], allow_padding=True)
            end = timestamp(segment['end'], allow_padding=True)
            if end < start:
                raise WhisperKitError('WhisperKit returned unordered timestamps')
            # Short WAVs can produce extra hypotheses in Whisper's padded window.
            # They contain no source audio and must not discard earlier valid speech.
            source_end = source_ends.get(segment.get('seek'), duration)
            if start >= source_end:
                continue
            if start < previous:
                raise WhisperKitError('WhisperKit returned unordered timestamps')
            words = []
            dropped_words = False
            for word in segment.get('words') or []:
                wstart = timestamp(word['start'], allow_padding=True)
                wend = timestamp(word['end'], allow_padding=True)
                score = word['probability']
                if (wend < wstart or type(score) not in (int, float)
                        or not math.isfinite(score) or not 0 <= score <= 1):
                    raise WhisperKitError('WhisperKit returned invalid word timing or confidence')
                if wstart >= source_end:
                    dropped_words = True
                    continue
                wend = min(wend, source_end)
                words.append({'word': word['word'], 'start': wstart, 'end': wend,
                              'score': score, 'speaker': 'SPEAKER_00'})
            if segment.get('words'):
                if not words:
                    continue
                # The final word can straddle Stop and padding. Keep its real
                # audio interval; exclude words entirely beyond the boundary
                # from the segment text as well as the word list.
                end = min(end, source_end)
                if dropped_words:
                    text = ''.join(word['word'] for word in words).strip()
            else:
                end = timestamp(end)
            previous = start
            segments.append({'text': text, 'start': start, 'end': end,
                             'speaker': 'SPEAKER_00', 'words': words})
        if not segments:
            raise WhisperKitError('No speech segments returned; no conversation created')
        return {'language': raw['language'], 'segments': segments}
    except (KeyError, TypeError, AttributeError):
        raise WhisperKitError('WhisperKit returned an invalid report') from None


def transcribe(root: Path, audio: Path, output: Path, language: str, duration: float) -> dict:
    command = [str(root / 'bin/whisperkit-cli'), 'transcribe', '--audio-path', str(audio),
               '--model-path', str(root / 'models' / MODEL),
               '--download-tokenizer-path', str(root / 'tokenizer'),
               '--audio-encoder-compute-units', 'cpuAndNeuralEngine',
               '--text-decoder-compute-units', 'cpuAndNeuralEngine',
               '--concurrent-worker-count', '1', '--word-timestamps', '--skip-special-tokens',
               '--report', '--report-path', str(output)]
    if language != 'auto':
        command += ['--language', language]
    try:
        result = subprocess.run(offline(command), env=environment(), capture_output=True, timeout=3600)
        report = output / (audio.stem + '.json')
        if result.returncode or not report.is_file():
            raise WhisperKitError('WhisperKit inference failed; original WAV retained')
        return normalize(json.loads(report.read_text()), duration)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        raise WhisperKitError('WhisperKit inference did not produce a valid report; original WAV retained') from None
