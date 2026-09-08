"""Private batch worker, executed only in the separate Parakeet ML environment.

No ML imports enter the backend. stdout is a bounded diagnostic response;
transcript text goes only to the caller's private result file.
"""

from __future__ import annotations

import argparse
import gc
import importlib.metadata
import json
import math
import os
import re
import sys
import time
import wave
from pathlib import Path


def timed_words(tokens, duration):
    """Join Parakeet subword pieces without inserting spaces inside words."""
    words = []
    pending = None
    for token in tokens:
        start, end = float(token.start), float(token.end)
        if (not math.isfinite(start) or not math.isfinite(end) or start < -0.1
                or end > duration + 0.1 or end < start):
            raise ValueError('Invalid Parakeet timing')
        start, end = max(0.0, min(duration, start)), max(0.0, min(duration, end))
        for piece in re.findall(r'\s+|\S+', token.text):
            if piece.isspace():
                if pending:
                    words.append(pending)
                    pending = None
            elif pending:
                pending['word'] += piece
                pending['end'] = max(pending['end'], end)
            else:
                pending = {'word': piece, 'start': start, 'end': end}
    if pending:
        words.append(pending)
    return words


def assign_speakers(segments, turns):
    """Assign by temporal overlap; absent diarization remains explicitly unknown."""
    for segment in segments:
        for word in segment['words']:
            overlap = {}
            for start, end, speaker in turns:
                amount = max(0.0, min(word['end'], end) - max(word['start'], start))
                if amount:
                    overlap[speaker] = overlap.get(speaker, 0.0) + amount
            word['speaker'] = max(overlap, key=overlap.get) if overlap else None
        labels = {word['speaker'] for word in segment['words']}
        segment['speaker'] = next(iter(labels)) if len(labels) == 1 else None


def single_speaker(segments):
    """Explicit user-selected placeholder, not inferred speaker identity."""
    for segment in segments:
        segment['speaker'] = 'SPEAKER_00'
        for word in segment['words']:
            word['speaker'] = 'SPEAKER_00'


def dependencies(model_id, diarization_id):
    import mlx.core as mx
    from huggingface_hub import hf_hub_download
    from parakeet_mlx import from_pretrained

    if not mx.metal.is_available():
        raise RuntimeError('GPU unavailable')
    mx.set_default_device(mx.gpu)
    x = mx.ones((1, 12, 4), dtype=mx.float32)
    y = mx.conv1d(x, mx.ones((8, 3, 4), dtype=mx.float32))
    mx.eval(y)
    mx.synchronize()
    for filename in ('config.json', 'model.safetensors'):
        path = Path(hf_hub_download(model_id, filename, local_files_only=True))
        if path.stat().st_size == 0:
            raise ValueError('Empty model cache')
    packages = ['parakeet-mlx', 'mlx', 'numpy']
    if diarization_id != 'none':
        from pyannote.audio import Pipeline
        import torchcodec
        hf_hub_download(diarization_id, 'config.yaml', local_files_only=True)
        packages.extend(['pyannote.audio', 'torch', 'torchcodec'])
    return {name: importlib.metadata.version(name) for name in packages}


def process(args, versions):
    import mlx.core as mx
    from mlx.utils import tree_flatten
    from parakeet_mlx import from_pretrained, DecodingConfig, Greedy

    with wave.open(args.audio) as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, 16000, 'NONE'):
            raise ValueError('Expected PCM16 mono 16 kHz')
        duration = audio.getnframes() / 16000
    if not 0 < duration <= 14400:
        raise ValueError('Invalid audio length')
    started = time.monotonic()
    model = from_pretrained(args.model, dtype=mx.float32)
    mx.eval(model.parameters())
    dtypes = {str(value.dtype) for _, value in tree_flatten(model.parameters())}
    if dtypes != {'mlx.core.float32'}:
        raise ValueError('Model weights are not FP32')
    loaded = time.monotonic()
    result = model.transcribe(args.audio, dtype=mx.float32,
                              decoding_config=DecodingConfig(decoding=Greedy()),
                              chunk_duration=args.chunk_duration, overlap_duration=args.overlap_duration)
    mx.synchronize()
    segments = []
    for sentence in result.sentences:
        words = timed_words(sentence.tokens, duration)
        if not words:
            continue
        if ' '.join(word['word'] for word in words).split() != sentence.text.split():
            raise ValueError('Subword text was not preserved')
        segments.append({'text': sentence.text.strip(), 'start': min(w['start'] for w in words),
                         'end': max(w['end'] for w in words), 'words': words})
    if not segments:
        raise ValueError('No speech segments')
    asr_done = time.monotonic()
    metrics = {'engine': 'parakeet-mlx', 'device': str(mx.default_device()),
               'compute_type': 'float32', 'parameter_dtypes': sorted(dtypes),
               'load_seconds': round(loaded - started, 3),
               'asr_seconds': round(asr_done - loaded, 3),
               'gpu_peak_bytes': mx.get_peak_memory(), 'versions': versions}
    del model, result
    gc.collect()
    mx.clear_cache()

    if args.diarization_model == 'none':
        single_speaker(segments)
        metrics.update(diarization_enabled=False, diarization_seconds=0,
                       speaker_assignment='single_speaker_placeholder',
                       total_seconds=round(time.monotonic() - started, 3))
        return {'language': None, 'language_mode': 'automatic', 'segments': segments, 'runtime': metrics}

    import numpy as np
    import torch
    from pyannote.audio import Pipeline

    torch.set_num_threads(4)
    pipeline = Pipeline.from_pretrained(args.diarization_model)
    if pipeline is None:
        raise RuntimeError('Diarization unavailable')
    pipeline.to(torch.device('cpu'))
    with wave.open(args.audio) as audio:
        waveform = np.frombuffer(audio.readframes(audio.getnframes()), dtype='<i2').astype(np.float32) / 32768.0
    diarized = pipeline({'waveform': torch.from_numpy(waveform).unsqueeze(0), 'sample_rate': 16000})
    turns = [(float(turn.start), float(turn.end), speaker)
             for turn, _, speaker in diarized.exclusive_speaker_diarization.itertracks(yield_label=True)]
    assign_speakers(segments, turns)
    metrics.update(diarization_enabled=True, diarization_device='cpu', diarization_seconds=round(time.monotonic() - asr_done, 3),
                   total_seconds=round(time.monotonic() - started, 3))
    # Parakeet v3 detects language internally but does not expose a language code.
    return {'language': None, 'language_mode': 'automatic', 'segments': segments, 'runtime': metrics}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--model', required=True)
    parser.add_argument('--diarization-model', required=True)
    parser.add_argument('--audio')
    parser.add_argument('--output')
    parser.add_argument('--chunk-duration', type=int, default=60)
    parser.add_argument('--overlap-duration', type=int, default=5)
    args = parser.parse_args()
    if not args.check and (not args.audio or not args.output):
        parser.error('Audio and output required')
    if not 1 <= args.overlap_duration < args.chunk_duration <= 60:
        parser.error('Invalid chunk settings')
    os.umask(0o077)
    report = os.fdopen(os.dup(1), 'w')
    with open(os.devnull, 'w') as sink:
        os.dup2(sink.fileno(), 1)
        os.dup2(sink.fileno(), 2)

    def no_network(event, _args):
        if event in {'socket.connect', 'socket.getaddrinfo'}:
            raise RuntimeError('Local model network access disabled')

    sys.addaudithook(no_network)
    stage = 'dependencies'
    try:
        versions = dependencies(args.model, args.diarization_model)
        if args.check:
            report.write(json.dumps({'status': 'passed', 'gpu': True, 'compute_type': 'float32', 'versions': versions}))
        else:
            stage = 'inference'
            result = process(args, versions)
            with Path(args.output).open('x') as output:
                json.dump(result, output, ensure_ascii=False, allow_nan=False)
            report.write(json.dumps({'status': 'passed', **result['runtime']}))
    except Exception as error:
        report.write(json.dumps({'status': 'failed', 'stage': stage, 'error_type': type(error).__name__}))
        return 1
    finally:
        report.flush()
    return 0


if __name__ == '__main__':
    sys.exit(main())
