"""Stable passage positions within one canonical transcript revision."""

import hashlib
import math
from dataclasses import dataclass


@dataclass(frozen=True)
class Passage:
    text: str
    snippet: dict | None = None
    source_text: str | None = None


def owner_digest(uid: str) -> str:
    return hashlib.sha256(uid.encode('utf-8')).hexdigest()


def source_revision(update_time) -> str:
    # Firestore's DatetimeWithNanoseconds preserves the original revision precision.
    if callable(rfc3339 := getattr(update_time, 'rfc3339', None)):
        return rfc3339()
    return update_time.isoformat()


def _string(value):
    return value.strip() if isinstance(value, str) else ''


def _windows(text):
    # Preserve every character while bounding tokenizer input and keeping a short overlap.
    for offset in range(0, len(text), 640):
        yield text[offset:offset + 800]
        if offset + 800 >= len(text):
            break


def _seconds(value):
    return float(value) if type(value) in {int, float} and math.isfinite(value) and value >= 0 else None


def passages(row: dict):
    structured = row.get('structured')
    if isinstance(structured, dict):
        summary = '\n'.join(filter(None, (_string(structured.get('title')), _string(structured.get('overview')))))
        for text in _windows(summary):
            yield Passage(text)

    segments = row.get('transcript_segments')
    if not isinstance(segments, list):
        return
    for index, segment in enumerate(segments):
        if not isinstance(segment, dict) or not (text := _string(segment.get('text'))):
            continue
        source_text = text
        start = _seconds(segment.get('start'))
        end = _seconds(segment.get('end'))
        snippet = {
            'segment_id': _string(segment.get('id')) or None,
            'start': start,
            'end': end,
        }
        if len(text) < 80:
            # Short replies benefit from their preceding context, but still open at the reply itself.
            previous = segments[index - 1] if index else None
            previous_end = _seconds(previous.get('end')) if isinstance(previous, dict) else None
            if start is not None and previous_end is not None and -3 <= start - previous_end <= 12:
                context = _string(previous.get('text'))[-380:]
                if context:
                    text = f'{context}\n{text}'
        for chunk in _windows(text):
            # Neighboring context helps rank short replies, but belongs to a
            # different segment and cannot be cited under this segment's ID.
            evidence = source_text if len(source_text) < 80 else chunk
            yield Passage(chunk, {**snippet, 'text': evidence[:360]}, evidence)
