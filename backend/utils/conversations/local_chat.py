"""Choose bounded, source-addressable transcript text for a local recording chat."""

import json
import math
import re
from heapq import nlargest
from itertools import zip_longest
from unicodedata import normalize


def _terms(text):
    return set(re.findall(r'[^\W_]{2,}', normalize('NFKC', text).casefold()))


def _milliseconds(value):
    if isinstance(value, (int, float)) and math.isfinite(value) and 0 <= value < 86_400_000:
        return round(value * 1000)
    return None


def _segment_source(segment):
    text = segment.get('text') if isinstance(segment, dict) else None
    if not isinstance(text, str) or not text.strip():
        return None
    line = text.strip()
    identifier = segment.get('id')
    start = _milliseconds(segment.get('start'))
    end = _milliseconds(segment.get('end'))
    return line, {
        'text': line[:1200],
        'segment_id': identifier if isinstance(identifier, str) and 0 < len(identifier) <= 256 else None,
        'start_ms': start,
        'end_ms': None if start is not None and end is not None and end < start else end,
    }


def select_sources(segments, query):
    if not isinstance(segments, list):
        return [], False
    terms = _terms(query)
    candidates = []
    for segment in segments:
        extracted = _segment_source(segment)
        if extracted is None:
            continue
        line, source = extracted
        candidates.append((len(_terms(line) & terms), source, len(line) > 1200))
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


_QUESTION_WORDS = set(
    'the and for this that was were are who what when where which about from you how your tell '
    'это что кто когда где как про или был была были еще ещё какой какая какие расскажи мне об'.split()
)


def _archive_source(identifier, row, source):
    structured = row.get('structured')
    title = structured.get('title') if isinstance(structured, dict) else None
    return {**source, 'conversation_id': identifier, 'revision': row['_local_read_version'],
            'title': title[:160] if isinstance(title, str) else None,
            'started_at': row.get('started_at') or row.get('created_at')}


def rank_archive_sources(rows, query, previous_question=''):
    """Choose evidence from a stream of owner rows using Unicode keyword overlap."""
    query_terms = _terms(query) - _QUESTION_WORDS
    previous_terms = _terms(previous_question) - _QUESTION_WORDS
    if not query_terms and not previous_terms:
        return []

    def from_recording(row):
        segments = row.get('transcript_segments')
        if not isinstance(segments, list):
            return
        for line_index, segment in enumerate(segments):
            extracted = _segment_source(segment)
            if extracted is None:
                continue
            line, source = extracted
            if source['segment_id'] is None:
                continue
            words = _terms(line)
            overlap = words & query_terms
            earlier_overlap = words & previous_terms
            if not overlap and not earlier_overlap:
                continue
            score = 3 * sum(min(len(term), 12) for term in overlap) + sum(min(len(term), 12) for term in earlier_overlap)
            yield score, -line_index, source

    def candidates():
        for row in rows:
            for score, line_index, source in nlargest(4, from_recording(row)):
                yield score, row['id'], line_index, _archive_source(row['id'], row, source)

    return [source for _, _, _, source in nlargest(34, candidates())]


def semantic_archive_source(identifier, row, passage):
    """Use only text from the cited segment, excluding summary and neighbor text."""
    snippet = passage.snippet
    if not snippet or not passage.source_text:
        return None
    extracted = _segment_source({**snippet, 'id': snippet['segment_id'], 'text': passage.source_text})
    if extracted is None:
        return None
    _, source = extracted
    if source['segment_id'] is None:
        return None
    return _archive_source(identifier, row, source)


def merge_archive_sources(keyword, semantic):
    """Alternate ranks with exact matches first, retaining the shared evidence budget."""
    selected = []
    seen = set()
    remaining, chars = 22_000, 9000
    for pair in zip_longest(keyword, semantic):
        for source in pair:
            if source is None:
                continue
            key = (source['conversation_id'], source['segment_id'])
            text = source['text']
            size = len(json.dumps(text, ensure_ascii=False).encode('utf-8'))
            if key in seen or size > remaining or len(text) > chars:
                continue
            selected.append(source)
            seen.add(key)
            remaining -= size
            chars -= len(text)
            if len(selected) == 34:
                return selected
    return selected


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
