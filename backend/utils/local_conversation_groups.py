"""Turn ordered, durable 16 kHz audio parts into completed conversation WAVs."""

from __future__ import annotations

import errno
import itertools
import json
import os
import shutil
import struct
import tempfile
import uuid
import wave
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path

from utils.offline_audio_capture import CAPTURE_DIRECTORY, _atomic_json, _capture_metadata

RATE = 16000
FRAME = 160  # WebRTC VAD accepts 10 ms frames at 16 kHz.
SILENCE_OPTIONS = (0, 15, 30, 60, 120)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read_json(path):
    return json.loads(path.read_text())


class SpeechDetector:
    def __init__(self):
        # The pinned webrtcvad 2.0.10 wrapper imports retired pkg_resources solely
        # for its version string. Use the same packaged native engine directly.
        import _webrtcvad

        self.engine = _webrtcvad
        self.handle = _webrtcvad.create()
        _webrtcvad.init(self.handle)
        _webrtcvad.set_mode(self.handle, 2)

    def voiced(self, frame):
        return self.engine.process(self.handle, RATE, frame, FRAME)

    def runs(self, pcm):
        """Return half-open speech intervals, retaining the exact final sample."""
        speech = None
        samples = len(pcm) // 2
        for start in range(0, samples, FRAME):
            frame = pcm[2 * start : 2 * (start + FRAME)]
            voiced = self.voiced(frame.ljust(FRAME * 2, b'\0'))
            if voiced and speech is None:
                speech = start
            elif not voiced and speech is not None:
                yield speech, start
                speech = None
        if speech is not None:
            yield speech, samples


class LiveSilenceBoundary:
    """Early flush hint only. Durable ordered audio decides the actual boundaries."""

    @classmethod
    def from_headers(cls, headers):
        group = headers.get('x-omi-local-recording-group', '')
        seconds = headers.get('x-omi-local-group-silence', '')
        if seconds not in {str(s) for s in SILENCE_OPTIONS if s} or len(group) != 36:
            return None
        try:
            group_id = str(uuid.UUID(group))
        except ValueError:
            return None
        return cls(group_id, int(seconds), stop_capture=headers.get('x-omi-local-group-stop') == '1')

    def __init__(self, group_id, seconds, *, stop_capture=False):
        self.group_id = group_id
        self.stop_capture = stop_capture
        self.threshold = seconds * RATE
        self.detector = SpeechDetector()
        self.tail = b''
        self.quiet = None
        self.samples_seen = 0
        self.closed_at = None
        self.onset = None

    @property
    def activity_status(self):
        if self.quiet is not None:
            return 'speech_resumed'
        if self.samples_seen >= self.threshold:
            return 'awaiting_speech'
        return None

    def feed(self, pcm):
        data = self.tail + pcm
        complete = len(data) // (2 * FRAME) * (2 * FRAME)
        self.tail = data[complete:]
        emitted = False
        for start in range(0, complete, 2 * FRAME):
            frame = data[start : start + 2 * FRAME]
            if self.detector.voiced(frame):
                if self.quiet is None:
                    self.onset = max(self.closed_at or 0, self.samples_seen - RATE // 5)
                self.quiet = 0
            elif self.quiet is not None:
                self.quiet += FRAME
                if self.quiet >= self.threshold:
                    self.quiet = None
                    self.closed_at = self.samples_seen + FRAME
                    self.onset = None
                    emitted = True
            self.samples_seen += FRAME
        return emitted


def _new_progress():
    return dict(next_index=0, next_sample=0, open_start=None, last_voice=None, open_index=None,
                waiting_for_parts=False, completed=False, last_boundary=0, archived_before=0)


@contextmanager
def _conversation_wav(path, frames):
    """Write canonical mono PCM16, with an RF64 ds64 chunk above the RIFF size limit."""
    pcm_bytes = frames * 2
    fmt = struct.pack('<4sIHHIIHH', b'fmt ', 16, 1, 1, RATE, RATE * 2, 2, 16)
    if pcm_bytes + 36 <= 0xffffffff:
        header = struct.pack('<4sI4s', b'RIFF', pcm_bytes + 36, b'WAVE')
        data = struct.pack('<4sI', b'data', pcm_bytes)
    else:
        # EBU Tech 3306. riffSize counts all bytes after the size field.
        header = struct.pack('<4sI4s4sIQQQI', b'RF64', 0xffffffff, b'WAVE', b'ds64',
                             28, pcm_bytes + 72, pcm_bytes, frames, 0)
        data = struct.pack('<4sI', b'data', 0xffffffff)
    with path.open('wb') as stream:
        stream.write(header + fmt + data)
        expected = stream.tell() + pcm_bytes
        yield stream
        if stream.tell() != expected:
            raise ValueError('Incomplete conversation audio')


def _publish(root, group, config, first_index, start, end, speech_end):
    identifier = str(uuid.uuid5(uuid.UUID(group.name), f'conversation:{start}'))
    captures = root / CAPTURE_DIRECTORY
    captures.mkdir(exist_ok=True)
    target = captures / identifier
    provenance = dict(recording_id=group.name, start_sample=start, end_sample=end)
    if speech_end is not None:
        provenance['speech_end_sample'] = speech_end
    if target.exists():
        saved = read_json(target / 'metadata.json').get('conversation_group')
        # An older producer may have published this same audio immediately before restart.
        legacy = {k: v for k, v in provenance.items() if k != 'speech_end_sample'}
        if saved != provenance and saved != legacy:
            raise ValueError('Conflicting completed conversation')
        if not (target / 'audio.wav').is_file():
            raise ValueError('Completed conversation audio is missing')
        sync_dir(captures)
        return
    if shutil.disk_usage(root).free < 2 * (end - start) + 80:
        raise OSError(errno.ENOSPC, 'Insufficient storage for grouped conversation')
    staging = root / 'local-audio-staging'
    staging.mkdir(exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix='conversation-', dir=staging) as temp:
        folder = Path(temp) / identifier
        folder.mkdir(mode=0o700)
        samples = 0
        started = ended = None
        origin = None
        with _conversation_wav(folder / 'audio.wav', end - start) as out:
            for index in itertools.count(first_index):
                part = group / 'parts' / str(index)
                info = read_json(part / 'metadata.json')
                offset = info['delivery']['first_sample']
                with wave.open(str(part / 'audio.wav'), 'rb') as inp:
                    length = inp.getnframes()
                    left = max(start - offset, 0)
                    right = min(end - offset, length)
                    if right > left:
                        part_time = datetime.fromisoformat(info['started_at'].replace('Z', '+00:00'))
                        if started is None:
                            started = (part_time + timedelta(seconds=left / RATE)).isoformat()
                            origin = info.get('origin')
                        ended = (part_time + timedelta(seconds=right / RATE)).isoformat()
                        inp.setpos(left)
                        remaining = right - left
                        while remaining:
                            chunk = inp.readframes(min(remaining, RATE * 30))
                            if not chunk:
                                raise OSError('Incomplete source WAV')
                            out.write(chunk)
                            remaining -= len(chunk) // 2
                        samples += right - left
                if offset + length >= end:
                    break
        if samples != end - start:
            raise ValueError('Noncontiguous conversation')
        with (folder / 'audio.wav').open('rb') as audio:
            os.fsync(audio.fileno())
        meta = _capture_metadata(session_id=identifier, source=config['source'], input_codec=config['codec'],
                                 started_at=started, ended_at=ended, frames_received=None,
                                 encoded_bytes=None, decoded_pcm_bytes=samples * 2, decode_errors=0, status='completed',
                                 origin=origin)
        meta['conversation_group'] = provenance
        _atomic_json(folder / 'metadata.json', meta)
        sync_dir(folder)
        folder.rename(target)
        sync_dir(captures)


def advance_group(root: Path, group: Path, config: dict) -> int | None:
    progress_path = group / 'progress.json'
    state = read_json(progress_path) if progress_path.exists() else _new_progress()
    finish = group / 'finish.json'
    expected = read_json(finish)['index'] if finish.exists() else None
    threshold = config['silence_seconds'] * RATE

    def close(end, *, by_silence=False):
        if state['open_start'] is not None:
            speech_end = state['last_voice'] if by_silence else None
            _publish(root, group, config, state['open_index'], state['open_start'], end, speech_end)
            state.update(open_start=None, last_voice=None, open_index=None, last_boundary=end)
            if by_silence:
                state['last_silence_boundary'] = end

    parts = group / 'parts'
    while (folder := parts / str(state['next_index'])).exists():
        meta = read_json(folder / 'metadata.json')
        base = state['next_sample']
        if base != meta['delivery']['first_sample']:
            raise ValueError('Noncontiguous audio sample position')
        end = base + meta['decoded_pcm_bytes'] // 2
        if not threshold and state['open_start'] is None:
            state.update(open_start=base, open_index=state['next_index'])
        for first, last in meta['speech_runs']:
            first += base
            last += base
            if threshold and state['last_voice'] is not None and first - state['last_voice'] >= threshold:
                close(state['last_voice'] + threshold, by_silence=True)
            if state['open_start'] is None:
                # Include up to 200 ms of onset preceding the first VAD-positive frame.
                # Parts before the current part are immutable and available for this pre-roll.
                start = max(state['last_boundary'], first - RATE // 5)
                idx = state['next_index']
                while idx > 0 and start < read_json(parts / str(idx) / 'metadata.json')['delivery']['first_sample']:
                    idx -= 1
                state.update(open_start=start, open_index=idx)
            state['last_voice'] = last
        if threshold and state['last_voice'] is not None and end - state['last_voice'] >= threshold:
            close(state['last_voice'] + threshold, by_silence=True)
        state.update(next_index=state['next_index'] + 1, next_sample=end)
        _atomic_json(progress_path, state)
    if expected is not None and state['next_index'] == expected:
        close(state['next_sample'])
        state['completed'] = True
    state['waiting_for_parts'] = ((expected is not None and state['next_index'] < expected)
                                  or any(p.name.isdecimal() and int(p.name) > state['next_index']
                                         for p in parts.iterdir()))
    if state['waiting_for_parts']:
        start = state['open_start'] if state['open_start'] is not None else state['next_sample']
        group_start = datetime.fromisoformat(config['started_at'].replace('Z', '+00:00'))
        state['waiting_row'] = {
            'source': config['source'], 'started_at': (group_start + timedelta(seconds=start / RATE)).isoformat(),
            'duration_seconds': (state['next_sample'] - start) / RATE,
        }
        open_index = state['open_index']
        if open_index is not None:
            state['waiting_row']['origin'] = read_json(parts / str(open_index) / 'metadata.json').get('origin')
    else:
        state.pop('waiting_row', None)
    _atomic_json(progress_path, state)
    sync_dir(group)
    # A compact receipt remains for retries. The canonical conversation WAV now
    # owns the published samples; ordinary library deletion must remove them.
    # Keep enough original PCM for onset, even after several tiny BLE reconnect parts.
    keep_from = (state['next_index'] if state['completed'] else
                 state['open_index'] if state['open_start'] is not None else
                 max(0, state['next_index'] - 1) if threshold else 0)
    if threshold and not state['completed'] and state['open_start'] is None:
        earliest_onset = max(state['last_boundary'], state['next_sample'] - RATE // 5)
        while keep_from > state['archived_before']:
            if read_json(parts / str(keep_from) / 'metadata.json')['delivery']['first_sample'] <= earliest_onset:
                break
            keep_from -= 1
    for i in range(state['archived_before'], keep_from):
        part = parts / str(i)
        meta_path = part / 'metadata.json'
        meta = read_json(meta_path)
        meta['group_part_archived'] = True
        meta.pop('speech_runs', None)
        _atomic_json(meta_path, meta)
        sync_dir(part)
        (part / 'audio.wav').unlink(missing_ok=True)
        sync_dir(part)
    if keep_from > state['archived_before']:
        state['archived_before'] = keep_from
        _atomic_json(progress_path, state)
        sync_dir(group)
    return state.get('last_silence_boundary')
