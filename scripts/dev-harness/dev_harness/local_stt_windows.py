"""Bounded finished-recording inference with one sample clock and resumable windows."""
import hashlib
import os
import tempfile
import wave
from collections import Counter
from contextlib import ExitStack
from pathlib import Path

from . import local_pipeline, stt_install
from .local_capture_wav import read_wave

RATE = 16000
WINDOW = 600 * RATE
CONTEXT = 2 * RATE
# Keep a short acoustic release after the last positive VAD frame for final consonants.
SPEECH_RELEASE = RATE // 4


def needed(manifest):
    group = manifest.get('conversation_group')
    return group is not None and ('speech_end_sample' in group or manifest['duration_seconds'] * RATE > WINDOW)


def _write_slice(source, path, start, stop):
    source.setpos(start)
    remaining = stop - start
    with wave.open(str(path), 'wb') as target:
        target.setparams((1, 2, RATE, 0, 'NONE', 'not compressed'))
        while remaining:
            pcm = source.readframes(min(remaining, RATE * 10))
            if not pcm or len(pcm) % 2:
                raise local_pipeline.PipelineError('Incomplete conversation audio')
            target.writeframesraw(pcm)
            remaining -= len(pcm) // 2


def _merge_segment(segment, offset, left, right, last, label):
    def shifted(item):
        result = dict(item)
        for key in ('start', 'end'):
            if result.get(key) is not None:
                result[key] = result[key] + offset
        if result.get('speaker') is not None:
            result['speaker'] = label(result['speaker'])
        return result

    def owns(item):
        middle = (item['start'] + item['end']) / 2
        return left <= middle and (middle < right or (last and middle == right))

    result = shifted(segment)
    words = [shifted(word) for word in segment.get('words', [])]
    if words and all(word.get('start') is not None and word.get('end') is not None for word in words):
        selected = [word for word in words if owns(word)]
        if not selected:
            return None
        if len(selected) < len(words):
            result['text'] = ' '.join(word['word'].strip() for word in selected).strip()
            if not result['text']:
                return None
            result['start'] = min(word['start'] for word in selected)
            result['end'] = max(word['end'] for word in selected)
            if result['start'] == result['end']:
                result['start'], result['end'] = max(left, segment['start'] + offset), min(right, segment['end'] + offset)
        result['words'] = selected
    elif owns(result):
        if words:
            result['words'] = words
        result['start'] = max(left, result['start'])
        result['end'] = min(right, result['end'])
    else:
        return None
    return result if result['start'] < result['end'] else None


def _speaker_aliases(previous, current):
    # Window-local labels are arbitrary. Carry one across a seam only when
    # both sides identify the same voice throughout the shared speech.
    evidence = Counter()
    for start, end, name in current:
        for old_start, old_end, old_name in previous:
            overlap = min(end, old_end) - max(start, old_start)
            if overlap > 0:
                evidence[name, old_name] += overlap
    return {name: old for (name, old), seconds in evidence.items()
            if seconds >= .25 and sum(a == name for a, _ in evidence) == 1
            and sum(b == old for _, b in evidence) == 1}


def run(audio, folder, manifest, stage, infer, write, *, speakers=False):
    """Run one adapter per window, using the same slices for ASR and speakers."""
    segments, languages = [], Counter()
    speaker_count, previous = 0, []
    cache = folder / 'windows-v1'
    cache.mkdir(exist_ok=True, mode=0o700)
    with ExitStack() as resources:
        stream = resources.enter_context(audio.open('rb'))
        stat = os.fstat(stream.fileno())
        if hashlib.file_digest(stream, 'sha256').hexdigest() != manifest['audio_sha256']:
            raise local_pipeline.PipelineError('Conversation WAV changed before inference')
        stream.seek(0)
        wav = resources.enter_context(read_wave(stream))
        total = wav.getnframes()
        group = manifest['conversation_group']
        if 'speech_end_sample' in group:
            total = min(total, group['speech_end_sample'] - group['start_sample'] + SPEECH_RELEASE)
        for first in range(0, total, WINDOW):
            end = min(total, first + WINDOW)
            start, stop = max(0, first - CONTEXT), min(total, end + CONTEXT)
            offset, left, right = start / RATE, first / RATE, end / RATE
            key = cache / f'{start}-{stop}-{first}'
            key.mkdir(exist_ok=True, mode=0o700)
            with tempfile.TemporaryDirectory(dir=key) as tmp:
                piece = Path(tmp) / 'audio.wav'
                _write_slice(wav, piece, start, stop)
                digest = stt_install.digest(piece)
                info = {'duration_seconds': (stop - start) / RATE, 'audio_sha256': digest, 'conversation_window': True}
                saved_path = key / (stage + '.json')
                if saved_path.exists():
                    saved = local_pipeline._read(saved_path)
                    if saved.get('digest') != digest:
                        raise local_pipeline.PipelineError('Window does not match saved audio')
                    value = saved['transcript']
                else:
                    partial = None
                    if stage == 'diarization':
                        asr = local_pipeline._read(key / 'stt.json')
                        if asr['digest'] != digest:
                            raise local_pipeline.PipelineError('Window does not match saved ASR')
                        partial = asr['transcript']
                    value = partial if partial is not None and not partial['segments'] else infer(piece, key, info, partial)
                    local_pipeline.validate_transcript(value, info['duration_seconds'])
                    write(saved_path, {'digest': digest, 'transcript': value})
                local_pipeline.validate_transcript(value, info['duration_seconds'])
            if value.get('language'):
                languages[value['language']] += len(value['segments'])
            turns = []
            if speakers:
                local_turns = (value.get('diarization') or {}).get('turns')
                if local_turns is None:
                    local_turns = [(s['start'], s['end'], s.get('speaker')) for s in value['segments']]
                turns = [(a + offset, b + offset, name) for a, b, name in local_turns if name]
            aliases = _speaker_aliases(previous, (turn for turn in turns if turn[0] < left + CONTEXT / RATE))

            def label(name):
                nonlocal speaker_count
                if not speakers:
                    return name
                if name not in aliases:
                    aliases[name] = f'SPEAKER_{speaker_count:02d}'
                    speaker_count += 1
                return aliases[name]

            for row in value['segments']:
                merged = _merge_segment(row, offset, left, right, end == total, label)
                if merged is not None:
                    segments.append(merged)
            previous = [(a, b, label(name)) for a, b, name in turns if b > right - CONTEXT / RATE]
        if os.fstat(stream.fileno()).st_ctime_ns != stat.st_ctime_ns:
            raise local_pipeline.PipelineError('Conversation WAV changed during inference')
    result = {'segments': sorted(segments, key=lambda row: row['start']),
              'language': languages.most_common(1)[0][0] if languages else ''}
    if speakers:
        used_labels = {row['speaker'] for row in segments if row.get('speaker')}
        used_labels.update(word['speaker'] for row in segments for word in row.get('words', []) if word.get('speaker'))
        result['diarization'] = {'speakers': len(used_labels), 'window_seconds': WINDOW / RATE}
    if not segments:
        result['outcome'] = 'no_speech'
    return result
