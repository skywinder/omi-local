"""Offline model readiness and CLI entrypoint for the managed WhisperX runtime."""

import argparse
from importlib import metadata
import json
import os
import runpy
import re
import sys
import tempfile
import wave
from pathlib import Path

from stt_install import InstallError, SOURCE, digest, recipe, verify_assets


def verify_runtime(data: dict, source: Path = SOURCE) -> None:
    if tuple(sys.version_info[:3]) != tuple(map(int, data['python'].split('.'))):
        raise InstallError('Версия Python изменилась. Повторите install-local-stt.sh.')
    pins = re.findall(r'^([A-Za-z0-9_.-]+)==(\S+)',
                      (source / 'requirements-whisperx-macos.txt').read_text(), re.MULTILINE)
    try:
        if not pins or any(metadata.version(name) != version for name, version in pins):
            raise ValueError('dependency drift')
    except (metadata.PackageNotFoundError, ValueError):
        raise InstallError('Зависимости изменились. Повторите install-local-stt.sh.') from None


def offline(assets: Path) -> None:
    os.environ.update({
        'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1', 'HF_HUB_DISABLE_IMPLICIT_TOKEN': '1',
        'HF_HUB_DISABLE_TELEMETRY': '1', 'PYANNOTE_METRICS_ENABLED': '0', 'DO_NOT_TRACK': '1',
        'TOKENIZERS_PARALLELISM': 'false', 'NLTK_DATA': str(assets / 'nltk'),
        'HF_HOME': str(assets / 'cache/huggingface'), 'TORCH_HOME': str(assets / 'cache/torch'),
    })
    # Reject Python network operations even when a library ignores its offline flag.
    def guard(event, args):
        if event in ('socket.connect', 'socket.getaddrinfo', 'socket.gethostbyname', 'socket.sendto'):
            raise InstallError('Попытка сетевого обращения во время локального распознавания.')
    sys.addaudithook(guard)


def check(assets: Path, *, load: bool = False) -> None:
    import sysconfig
    data = recipe()
    verify_runtime(data)
    verify_assets(assets, data)
    for name, hashes in data['patches'].items():
        if digest(Path(sysconfig.get_path('purelib')) / name) != hashes['patched']:
            raise InstallError('Правки WhisperX отсутствуют. Повторите install-local-stt.sh.')
    import onnxruntime
    onnxruntime.disable_telemetry_events()
    import torchcodec  # noqa: F401 — verifies the actual FFmpeg dynamic libraries
    import whisperx
    import whisperx.transcribe  # noqa: F401
    import nltk
    nltk.data.load('tokenizers/punkt_tab/russian.pickle')
    if load:
        fixture = SOURCE / data['smoke']['path']
        if digest(fixture) != data['smoke']['sha256']:
            raise InstallError('Проверочный аудиофайл изменился.')
        with tempfile.TemporaryDirectory(prefix='omiloc-speech-check-') as temporary:
            transcribe(assets, [str(fixture), '--language', 'ru', '--device', 'cpu', '--compute_type', 'float32',
                               '--batch_size', '1', '--output_format', 'json', '--output_dir', temporary])
            raw = json.loads((Path(temporary) / 'speech-check.json').read_text())
            with wave.open(str(fixture)) as stream:
                duration = stream.getnframes() / stream.getframerate()
            validate_smoke(raw, data['smoke']['words'], duration)


def validate_smoke(raw: dict, expected: list[str], duration: float) -> None:
    segments = raw.get('segments', [])
    text = ' '.join(segment.get('text', '') for segment in segments).lower()
    words = set(re.findall(r'[а-яё]+', text))
    timed = [word for segment in segments for word in segment.get('words', [])
             if isinstance(word.get('start'), (int, float)) and isinstance(word.get('end'), (int, float))
             and 0 <= word['start'] < word['end'] <= duration + 0.1]
    if len(words.intersection(expected)) < 3 or len(timed) < 4:
        raise InstallError('Проверочная речь или таймкоды не распознаны.')


def transcribe(assets: Path, extra: list[str]) -> None:
    data = recipe()
    previous = sys.argv
    try:
        sys.argv = ['whisperx', *extra, '--model', str(assets / data['asr_path']),
                    '--align_model', str(assets / data['alignment_path']), '--model_cache_only', 'True']
        runpy.run_module('whisperx', run_name='__main__')
    finally:
        sys.argv = previous


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--assets', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--quick-check', action='store_true')
    args, extra = parser.parse_known_args()
    offline(args.assets)
    check(args.assets, load=args.check)
    if args.check or args.quick_check:
        print('WhisperX: offline readiness passed')
        return
    transcribe(args.assets, extra)


if __name__ == '__main__':
    main()
