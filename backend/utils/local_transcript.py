"""Local engine segments projected into the existing Conversation contract."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import re
from unicodedata import category as unicode_category
import uuid
from datetime import datetime, timedelta

from models.conversation import Conversation
from models.structured import Structured
from models.conversation_enums import CategoryEnum
from models.transcript_segment import TranscriptSegment


def _time(value: object, duration: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError('Transcript timestamp must be numeric')
    value = float(value)
    if not math.isfinite(value) or value < 0 or value > duration + 0.1:
        raise ValueError('Transcript timestamp is outside the recording')
    return value


def normalize_segments(raw: dict, duration: float, conversation_id: str,
                       provider: str = 'whisperx-local', *, summary_sources=None) -> list[TranscriptSegment]:
    """Preserve sentence boundaries/case; split only actual word-speaker changes.

    Untimed words remain in the original sentence. A mixed-speaker sentence
    requires complete word timing/text before it can be split without data loss.
    """
    segments = raw.get('segments')
    if not isinstance(segments, list) or not segments:
        raise ValueError('No transcript segments; no conversation was created')
    result = []
    for segment in segments:
        first_part = len(result)
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
        if summary_sources is not None:
            summary_sources.append(tuple(part.id for part in result[first_part:]))
    return result


STAGE_STATUSES = {'ready', 'failed', 'disabled', 'no_speech', 'pending', 'processing'}


def stage_outcomes(raw: dict) -> dict | None:
    """Fixed per-stage outcome fields for the phone; provider names only, never settings or keys."""
    processing = raw.get('processing')
    if not isinstance(processing, dict):
        return None
    stages = {}
    for stage in ('stt', 'diarization', 'summary'):
        entry = processing.get(stage)
        if not isinstance(entry, dict):
            continue
        status = entry.get('status')
        row = {'status': status if status in STAGE_STATUSES else 'unknown'}
        provider = entry.get('provider_name')
        if isinstance(provider, str) and provider.strip() and provider.isprintable():
            row['provider'] = provider[:100]
        if stage == 'summary' and status == 'ready':
            for key, limit in (('model', 300), ('template_name', 100)):
                value = entry.get(key)
                if isinstance(value, str) and 0 < len(value) <= limit and value.isprintable():
                    row[key] = value
        if stage == 'diarization':
            speakers = (raw.get('diarization') or {}).get('speakers') if isinstance(raw.get('diarization'), dict) else None
            if type(speakers) is int and 0 <= speakers <= 10_000:
                row['speakers'] = speakers
        stages[stage] = row
    return stages


def summary_labels(summary: dict, *, user_category: str | None = None) -> dict:
    """Return validated classifier fields for a new or regenerated recording summary."""
    labels = {}
    category = summary.get('category')
    if not user_category and isinstance(category, str) and category in CategoryEnum._value2member_map_:
        labels['category'] = category
    emoji = summary.get('emoji')
    if isinstance(emoji, str) and 0 < len(emoji) <= 12:
        kinds = [unicode_category(char) for char in emoji]
        if 'So' in kinds and all(
            kind in {'So', 'Sk'} or char in {'\u200d', '\ufe0f'}
            for char, kind in zip(emoji, kinds)
        ):
            labels['emoji'] = emoji
    return labels


def summary_note_fields(summary, sources):
    """Resolve provider-local source numbers to canonical transcript segment IDs."""
    fields = {'overview': summary['overview'].strip(), 'sections': []}
    rows = summary.get('sections')
    if not isinstance(rows, list):
        return fields
    sections = []
    # Section prose must not cause remote images or links to load in a paired client.
    literal_markup = str.maketrans({'\\': '\\\\', '[': '\\[', '<': '\\<'})
    for row in rows[:5]:
        if not isinstance(row, dict):
            continue
        heading, body, refs = (row.get(key) for key in ('heading', 'body_markdown', 'source_refs'))
        if not isinstance(heading, str) or not isinstance(body, str) or not isinstance(refs, list):
            continue
        heading, body = ' '.join(heading.split()).translate(literal_markup), body.strip().translate(literal_markup)
        if not 0 < len(heading) <= 96 or not 0 < len(body) <= 625:
            continue
        ids = list(dict.fromkeys(
            identifier for ref in refs[:8] if type(ref) is int and 0 < ref <= len(sources)
            for identifier in sources[ref - 1]
        ))[:8]
        if ids:
            sections.append({'heading': heading, 'body_markdown': body, 'source_segment_ids': ids})
    fields['sections'] = sections
    if sections:
        # Match Omi's first-party Markdown projection so both older readers and
        # the section-and-source view render the same current recap.
        fields['overview'] = '\n\n'.join(f"## {row['heading']}\n\n{row['body_markdown']}" for row in sections)
    return fields


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
                'whisperkit': 'whisperkit-local', 'openai-compatible': 'openai-compatible-local'}[manifest['profile']['engine']]
    if manifest['profile'].get('pipeline') and manifest['profile']['engine'] == 'openai-compatible':
        provider = 'openai-compatible'
    summary_sources = [] if isinstance(raw.get('structured'), dict) and 'sections' in raw['structured'] else None
    segments = normalize_segments(raw, duration, conversation_id, provider, summary_sources=summary_sources)
    structured = {'title': 'Локальная запись', 'overview': ''}
    if 'structured' in raw:
        summary = raw['structured']
        if (not isinstance(summary, dict) or not isinstance(summary.get('title'), str)
                or not isinstance(summary.get('overview'), str) or not summary['title'].strip()
                or not summary['overview'].strip() or len(summary['title']) > 300 or len(summary['overview']) > 4000):
            raise ValueError('Invalid local recording summary')
        structured = {'title': summary['title'].strip(), **summary_note_fields(summary, summary_sources or [])}
        structured.update(summary_labels(summary))
    return Conversation(
        id=conversation_id, created_at=started, started_at=started,
        finished_at=started + timedelta(seconds=duration),
        source=manifest['source'], language=raw.get('language'),
        structured=Structured(**({'emoji': '🎙️'} | structured)),
        transcript_segments=segments, status='completed', uses_custom_stt=True,
        discarded=False, deferred=False,
        external_data={'local_transcript': {'version': 1, 'audio_sha256': digest, 'result_key': result_key,
                                            'profile': manifest['profile'],
                                            **({'stages': stages} if (stages := stage_outcomes(raw)) is not None else {})}},
    )


# Reserve Firestore document space for summary metadata and subsequent user edits.
GROUPED_INLINE_TRANSCRIPT_BYTES = 512 * 1024
GROUPED_TRANSCRIPT_EDIT_BYTES = 192 * 1024


class TranscriptEditLimit(ValueError):
    pass


def local_transcript_root() -> Path:
    return Path(os.environ['OMI_HARNESS_STATE_ROOT']) / 'services' / 'local-transcripts'


def read_grouped_transcript_edits(document: dict, uid: str) -> dict:
    if 'local_transcript_edits' not in document:
        return {}
    from utils import encryption

    payload = document['local_transcript_edits']
    if not isinstance(payload, str) or len(payload) > 4 * ((GROUPED_TRANSCRIPT_EDIT_BYTES + 30) // 3):
        raise ValueError('Invalid transcript edits')
    edits = json.loads(encryption.decrypt(payload, uid))
    if not isinstance(edits, dict):
        raise ValueError('Invalid transcript edits')
    for patch in edits.values():
        if not isinstance(patch, dict) or not patch or patch.keys() - {'text', 'person_id', 'is_user'}:
            raise ValueError('Invalid transcript edit')
        if 'text' in patch and (not isinstance(patch['text'], str) or not patch['text'].strip()):
            raise ValueError('Invalid edited text')
        if 'is_user' in patch or 'person_id' in patch:
            if (type(patch.get('is_user')) is not bool or 'person_id' not in patch
                    or (patch['person_id'] is not None and (patch['is_user'] or not isinstance(patch['person_id'], str)))):
                raise ValueError('Invalid edited speaker')
    return edits


def encode_grouped_transcript_edits(edits: dict, uid: str) -> str:
    from utils import encryption

    payload = json.dumps(edits, ensure_ascii=False, separators=(',', ':'))
    if len(payload.encode('utf-8')) > GROUPED_TRANSCRIPT_EDIT_BYTES:
        raise TranscriptEditLimit('Recording exceeds its stored transcript edit budget')
    return encryption.encrypt(payload, uid)


def grouped_import_document(conversation: Conversation, manifest: dict, raw_path: Path) -> dict:
    document = conversation.model_dump()
    if 'conversation_group' not in manifest:
        return document
    segments = document['transcript_segments']
    estimated = 0
    for segment in segments:
        estimated += len(json.dumps(segment, ensure_ascii=True).encode())
        if estimated > GROUPED_INLINE_TRANSCRIPT_BYTES:
            with raw_path.open('rb') as stream:
                checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
            local = document['external_data']['local_transcript']
            local.update(segment_storage='result-file', segment_preview=True,
                         segment_count=len(segments), segment_source_sha256=checksum)
            document['transcript_segments'] = [{**segments[0], 'text': segments[0]['text'][:180]}]
            break
    return document


def hydrate_grouped_transcript(document: dict, root: Path, uid: str, *, original_segments: dict | None = None) -> dict:
    """Resolve only a validated imported local result under the paired owner's service directory."""
    local = (document.get('external_data') or {}).get('local_transcript') or {}
    if local.get('segment_storage') != 'result-file':
        return document
    key = local.get('result_key')
    if not isinstance(key, str) or not re.fullmatch(r'[a-f0-9]{64}', key):
        raise ValueError('Invalid transcript reference')
    if document['id'] != str(uuid.uuid5(uuid.NAMESPACE_URL, 'omi-local-stt:' + key)):
        raise ValueError('Conversation reference mismatch')
    folder = root / key
    if folder.is_symlink() or folder.resolve().parent != root.resolve():
        raise ValueError('Invalid result folder')
    manifest_path, raw_path = folder / 'manifest.json', folder / 'audio.json'
    if manifest_path.is_symlink() or raw_path.is_symlink() or manifest_path.stat().st_size > 1024 * 1024:
        raise ValueError('Invalid result file')
    manifest = json.loads(manifest_path.read_bytes())
    if (manifest.get('result_key') != key or manifest.get('audio_sha256') != local.get('audio_sha256')
            or not isinstance(manifest.get('conversation_group'), dict)):
        raise ValueError('Recording source mismatch')
    with raw_path.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != local.get('segment_source_sha256'):
            raise ValueError('Recording transcript has changed')
        stream.seek(0)
        raw = json.load(stream)
    full = build_conversation(raw, manifest)
    if len(full.transcript_segments) != local.get('segment_count'):
        raise ValueError('Incomplete transcript')
    edits = read_grouped_transcript_edits(document, uid)
    segments = []
    for segment in full.transcript_segments:
        entry = segment.model_dump()
        if original_segments is not None and segment.id in original_segments:
            original_segments[segment.id] = entry.copy()
        if patch := edits.pop(segment.id, None):
            entry.update(patch)
            if 'is_user' in patch:
                entry['speaker_identity_status'] = 'user' if patch['is_user'] else 'unknown'
        segments.append(entry)
    if edits:
        raise ValueError('Edited segment missing from transcript')
    result = {**document, 'transcript_segments': segments,
              'external_data': {**document['external_data'], 'local_transcript': {**local, 'segment_preview': False}}}
    result.pop('local_transcript_edits', None)
    return result
