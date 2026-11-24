"""Choose bounded, source-addressable transcript text for a local recording chat."""

import json
import math
import re
from unicodedata import normalize


def _terms(text):
    return set(re.findall(r'[^\W_]{2,}', normalize('NFKC', text).casefold()))


def _milliseconds(value):
    if isinstance(value, (int, float)) and math.isfinite(value) and 0 <= value < 86_400_000:
        return round(value * 1000)
    return None


def select_sources(segments, query):
    if not isinstance(segments, list):
        return [], False
    terms = _terms(query)
    candidates = []
    for segment in segments:
        text = segment.get('text') if isinstance(segment, dict) else None
        if not isinstance(text, str) or not text.strip():
            continue
        line = text.strip()
        identifier = segment.get('id')
        candidates.append((
            len(_terms(line) & terms),
            {
                'text': line[:1200],
                'segment_id': identifier if isinstance(identifier, str) and 0 < len(identifier) <= 256 else None,
                'start_ms': _milliseconds(segment.get('start')),
                'end_ms': _milliseconds(segment.get('end')),
            },
            len(line) > 1200,
        ))
    order = sorted(range(len(candidates)), key=lambda index: (-candidates[index][0], index))
    selected = {}
    bytes_left, chars_left = 25_000, 10_000
    limited = False
    for index in order:
        _, source, shortened = candidates[index]
        text = source['text']
        size = len(json.dumps(text, ensure_ascii=False).encode('utf-8'))
        if len(selected) == 120 or len(text) > chars_left or size > bytes_left:
            limited = True
            continue
        selected[index] = source
        limited |= shortened
        bytes_left -= size
        chars_left -= len(text)
    return [selected[index] for index in sorted(selected)], limited


def provider_history(turns):
    history = []
    remaining = 16_000
    for turn in turns[:3]:
        item = {key: turn[key] for key in ('question', 'answer')}
        size = len(json.dumps(item, ensure_ascii=False).encode('utf-8'))
        if size > remaining:
            break
        history.append(item)
        remaining -= size
    return history[::-1]
