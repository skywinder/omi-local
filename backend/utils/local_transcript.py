"""Local engine segments projected into the existing Conversation contract."""

from __future__ import annotations

import math
import re
import uuid
from datetime import datetime, timedelta

from models.conversation import Conversation
from models.structured import Structured
from models.transcript_segment import TranscriptSegment


def _time(value: object, duration: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError('Transcript timestamp must be numeric')
    value = float(value)
    if not math.isfinite(value) or value < 0 or value > duration + 0.1:
        raise ValueError('Transcript timestamp is outside the recording')
    return value


def normalize_segments(raw: dict, duration: float, conversation_id: str,
                       provider: str = 'whisperx-local') -> list[TranscriptSegment]:
    """Preserve sentence boundaries/case; split only actual word-speaker changes.

    Untimed words remain in the original sentence. A mixed-speaker sentence
    requires complete word timing/text before it can be split without data loss.
    """
    segments = raw.get('segments')
    if not isinstance(segments, list) or not segments:
        raise ValueError('No transcript segments; no conversation was created')
    result = []
    for segment in segments:
        if not isinstance(segment, dict) or not isinstance(segment.get('text'), str) or not segment['text'].strip():
            raise ValueError('Invalid transcript text')
        parts = [segment]
        words = segment.get('words', [])
        if not isinstance(words, list) or any(not isinstance(word, dict) for word in words):
            raise ValueError('Invalid transcript words')
        speakers = {word.get('speaker', segment.get('speaker')) for word in words}
        if len(speakers) > 1:
            if ' '.join(str(word.get('word', '')).strip() for word in words).split() != segment['text'].split():
                raise ValueError('Word text does not match the sentence')
            parts = []
            for word in words:
                start = _time(word.get('start'), duration)
                end = _time(word.get('end'), duration)
                if end < start:
                    raise ValueError('Reversed word timestamps')
                speaker = word.get('speaker', segment.get('speaker'))
                if parts and parts[-1]['speaker'] == speaker:
                    parts[-1]['text'] += ' ' + word['word'].strip()
                    parts[-1]['end'] = max(parts[-1]['end'], end)
                else:
                    parts.append({'text': word['word'].strip(), 'start': start, 'end': end, 'speaker': speaker})
        for part in parts:
            start, end = _time(part.get('start'), duration), _time(part.get('end'), duration)
            if end < start or (result and start < result[-1].start):
                raise ValueError('Transcript timestamps are not ordered')
            speaker = part.get('speaker')
            if speaker is not None and (not isinstance(speaker, str) or not re.fullmatch(r'SPEAKER_\d+', speaker)):
                raise ValueError('Unsupported speaker label')
            result.append(TranscriptSegment(
                id=str(uuid.uuid5(uuid.UUID(conversation_id), str(len(result)))),
                text=part['text'].strip(), start=start, end=end, speaker=speaker,
                speaker_id=int(speaker.split('_')[1]) if speaker else -1,
                is_user=False, speaker_identity_status='unknown',
                speaker_id_scope=conversation_id, stt_provider=provider,
            ))
    return result


def build_conversation(raw: dict, manifest: dict) -> Conversation:
    digest = manifest['audio_sha256']
    if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
        raise ValueError('Invalid audio digest')
    duration = manifest['duration_seconds']
    if isinstance(duration, bool) or not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration <= 0:
        raise ValueError('Invalid recording duration')
    started = datetime.fromisoformat(manifest['started_at'].replace('Z', '+00:00'))
    if started.tzinfo is None:
        raise ValueError('Recording timestamp must include timezone')
    result_key = manifest['result_key']
    if not isinstance(result_key, str) or not re.fullmatch(r'[0-9a-f]{64}', result_key):
        raise ValueError('Invalid result key')
    conversation_id = str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + result_key))
    provider = {'whisperx': 'whisperx-local', 'parakeet-mlx': 'parakeet-mlx-local',
                'whisperkit': 'whisperkit-local'}[manifest['profile']['engine']]
    segments = normalize_segments(raw, duration, conversation_id, provider)
    return Conversation(
        id=conversation_id, created_at=started, started_at=started,
        finished_at=started + timedelta(seconds=duration),
        source=manifest['source'], language=raw.get('language'),
        structured=Structured(title='Локальная запись', overview='', emoji='🎙️'),
        transcript_segments=segments, status='completed', uses_custom_stt=True,
        discarded=False, deferred=False,
        external_data={'local_transcript': {'version': 1, 'audio_sha256': digest, 'result_key': result_key,
                                            'profile': manifest['profile']}},
    )
