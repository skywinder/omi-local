"""Resident offline diarization over a loopback ASR stream; private PCM stays in anonymous scratch."""

import argparse
import asyncio
from bisect import bisect_left, bisect_right
from contextlib import asynccontextmanager, suppress
import json
import logging
import math
import os
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlsplit


def maximum_assignment(scores):
    """Maximum-weight one-to-one row/column assignment, with unmatched rows allowed."""
    rows = len(scores)
    if not rows or not scores[0]:
        return {}
    real_columns = len(scores[0])
    columns = real_columns + rows
    u, v = [0.0] * (rows + 1), [0.0] * (columns + 1)
    owner, previous = [0] * (columns + 1), [0] * (columns + 1)
    for row in range(1, rows + 1):
        owner[0] = row
        column = 0
        minimum, used = [math.inf] * (columns + 1), [False] * (columns + 1)
        while True:
            used[column] = True
            current, delta, next_column = owner[column], math.inf, 0
            for candidate in range(1, columns + 1):
                if used[candidate]:
                    continue
                weight = scores[current - 1][candidate - 1] if candidate <= real_columns else 0
                cost = -weight - u[current] - v[candidate]
                if cost < minimum[candidate]:
                    minimum[candidate], previous[candidate] = cost, column
                if minimum[candidate] < delta:
                    delta, next_column = minimum[candidate], candidate
            for candidate in range(columns + 1):
                if used[candidate]:
                    u[owner[candidate]] += delta
                    v[candidate] -= delta
                else:
                    minimum[candidate] -= delta
            column = next_column
            if owner[column] == 0:
                break
        while column:
            prior = previous[column]
            owner[column] = owner[prior]
            column = prior
    return {owner[column] - 1: column - 1 for column in range(1, real_columns + 1)
            if owner[column] and scores[owner[column] - 1][column - 1] > 0}


class SpeakerHistory:
    """Preserve session IDs when full-prefix clustering renumbers its anonymous labels."""

    def __init__(self):
        self.turns = []
        self.next_speaker = 1

    def update(self, turns):
        if any(not math.isfinite(start) or not math.isfinite(end) or start < 0 or end <= start
               or not isinstance(label, str) for start, end, label in turns):
            raise ValueError('invalid_speaker_turns')
        turns = sorted(turns)
        labels = list(dict.fromkeys(label for _, _, label in turns))
        old = sorted({label for _, _, label in self.turns})
        row_index, column_index = {v: i for i, v in enumerate(labels)}, {v: i for i, v in enumerate(old)}
        scores = [[0.0] * len(old) for _ in labels]
        left = 0
        for start, end, label in turns:
            while left < len(self.turns) and self.turns[left][1] <= start:
                left += 1
            for index in range(left, len(self.turns)):
                previous_start, previous_end, speaker = self.turns[index]
                if previous_start >= end:
                    break
                overlap = max(0, min(end, previous_end) - max(start, previous_start))
                scores[row_index[label]][column_index[speaker]] += overlap
        mapping = {labels[row]: old[column] for row, column in maximum_assignment(scores).items()}
        for label in labels:
            if label not in mapping:
                mapping[label] = self.next_speaker
                self.next_speaker += 1
        self.turns = [(start, end, mapping[label]) for start, end, label in turns]
        return self.turns


def seconds(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        result = float(value)
    elif isinstance(value, str):
        try:
            result = 0.0
            for field in value.split(':'):
                result = result * 60 + float(field)
        except ValueError:
            return None
    else:
        return None
    return result if math.isfinite(result) and result >= 0 else None


def labeled_snapshot(message, turns, covered_seconds, status):
    """Split timed words at actual voice changes; never invent timing for untimed ASR."""
    turns = sorted(turns)
    starts, max_ends = [], []
    for start, end, _ in turns:
        starts.append(start)
        max_ends.append(max(end, max_ends[-1] if max_ends else end))

    def speaker(item):
        start, end = seconds(item.get('start')), seconds(item.get('end'))
        if start is None or end is None or end <= start or end > covered_seconds:
            return -1
        votes = {}
        for index in range(bisect_right(max_ends, start), bisect_left(starts, end)):
            left, right, label = turns[index]
            overlap = max(0, min(end, right) - max(start, left))
            if overlap:
                votes[label] = votes.get(label, 0) + overlap
        return max(votes, key=votes.get) if votes else -1

    lines = []
    for line in message.get('lines', []):
        if not isinstance(line, dict):
            continue
        if line.get('speaker') == -2:
            lines.append(dict(line))
            continue
        words = line.get('words')
        if not words:
            lines.append({**line, 'speaker': speaker(line)})
            continue
        if (not isinstance(words, list) or not all(isinstance(w, dict) for w in words)
                or not all(isinstance(w.get('word'), str) for w in words)
                or not all(seconds(w.get('start')) is not None and seconds(w.get('end')) is not None for w in words)
                or not all(seconds(w['end']) >= seconds(w['start']) for w in words)
                or any(seconds(left['start']) > seconds(right['start']) for left, right in zip(words, words[1:]))
                or not isinstance(line.get('text'), str)
                or ''.join(w['word'] for w in words).strip() != line.get('text', '').strip()):
            lines.append({**line, 'speaker': -1})
            continue
        groups = []
        for word in words:
            label = speaker(word)
            # Zero-length punctuation is ASR text, not a new acoustic voice observation.
            if (groups and seconds(word.get('start')) is not None
                    and seconds(word.get('start')) == seconds(word.get('end'))
                    and not any(character.isalnum() for character in word['word'])):
                label = groups[-1][-1]['speaker']
            labeled = {**word, 'speaker': label}
            if not groups or groups[-1][-1]['speaker'] != labeled['speaker']:
                groups.append([])
            groups[-1].append(labeled)
        for group in groups:
            text = line.get('text', '') if len(groups) == 1 else ''.join(w.get('word', '') for w in group).strip()
            lines.append({**line, 'text': text, 'start': group[0].get('start'),
                          'end': max(seconds(word['end']) for word in group),
                          'speaker': group[0]['speaker'], 'words': group})
    return {**message, 'lines': lines, 'diarization_status': status}


class PyannoteDiarizer:
    def __init__(self, model, device='mps', threads=4):
        self.model, self.device, self.threads = model, device, threads
        self.pipeline = None

    def load(self):
        import torch
        from pyannote.audio import Pipeline
        torch.set_num_threads(self.threads)
        self.pipeline = Pipeline.from_pretrained(self.model)
        self.pipeline.to(torch.device(self.device))

    def infer(self, scratch, sample_count):
        import numpy as np
        import torch
        pcm = os.pread(scratch.fileno(), sample_count * 2, 0)
        if len(pcm) != sample_count * 2:
            raise ValueError('incomplete_pcm_prefix')
        waveform = np.frombuffer(pcm, dtype='<i2').astype(np.float32) / 32768
        result = self.pipeline({'waveform': torch.from_numpy(waveform).unsqueeze(0), 'sample_rate': 16000})
        return [(max(0.0, float(turn.start)), min(sample_count / 16000, float(turn.end)), str(label))
                for turn, _, label in result.exclusive_speaker_diarization.itertracks(yield_label=True)
                if float(turn.end) > float(turn.start) and float(turn.start) < sample_count / 16000]


async def finish_thread(call):
    """Cancellation must not close PCM scratch while native inference is still reading it."""
    try:
        return await asyncio.shield(call)
    except asyncio.CancelledError:
        with suppress(Exception):
            await call
        raise


def create_app(diarizer, upstream_url, emit, *, interval_seconds=15, max_seconds=4 * 60 * 60,
               connect=None, scratch_factory=tempfile.TemporaryFile):
    from fastapi import FastAPI, WebSocket
    from starlette.websockets import WebSocketDisconnect
    if connect is None:
        from websockets import connect

    active = False
    ready = False

    @asynccontextmanager
    async def lifespan(app):
        nonlocal ready
        await finish_thread(asyncio.create_task(asyncio.to_thread(diarizer.load)))
        ready = True
        emit('model_ready')
        try:
            yield
        finally:
            ready = False

    app = FastAPI(lifespan=lifespan)

    @app.get('/health')
    async def health():
        return {'ready': ready, 'active': active, 'diarization': True, 'interval_s': interval_seconds}

    @app.websocket('/asr')
    async def asr(socket: WebSocket):
        nonlocal active
        await socket.accept()
        if active or not ready:
            await socket.close(code=1013, reason='live_diarization_busy')
            return
        active = True
        received = 0
        covered = 0
        stop = False
        disconnected = False
        degraded = False
        history = SpeakerHistory()
        latest = None
        changed = asyncio.Event()
        sending = asyncio.Lock()
        tasks = []
        scratch = None

        async def send(message):
            nonlocal disconnected
            if disconnected:
                return
            async with sending:
                try:
                    await socket.send_json(message)
                except (WebSocketDisconnect, RuntimeError, OSError):
                    disconnected = True

        async def snapshot():
            if latest is not None:
                await send(labeled_snapshot(latest, history.turns, covered / 16000,
                                             'degraded' if degraded else 'ready' if covered else 'pending'))

        async def degrade(code):
            nonlocal degraded
            if degraded:
                return
            degraded = True
            emit('diarization_degraded', code=code)
            await send({'type': 'diarization_status', 'diarization': False, 'status': 'degraded', 'code': code})
            await snapshot()

        async def infer():
            nonlocal covered
            while True:
                await changed.wait()
                changed.clear()
                count = received
                if degraded:
                    if stop:
                        return
                    continue
                if count <= covered or (not stop and count - covered < interval_seconds * 16000):
                    if stop:
                        return
                    continue
                try:
                    turns = await finish_thread(asyncio.create_task(asyncio.to_thread(diarizer.infer, scratch, count)))
                    history.update(turns)
                    covered = count
                    await snapshot()
                except Exception:
                    await degrade('inference_failed')
                if stop and received == count:
                    return
                if stop or received - covered >= interval_seconds * 16000:
                    changed.set()

        try:
            scratch = scratch_factory(mode='w+b')
            async with connect(upstream_url, open_timeout=10, max_size=16 * 1024 * 1024) as upstream:
                async def feed():
                    nonlocal received, stop, disconnected
                    try:
                        while True:
                            pcm = await socket.receive_bytes()
                            if len(pcm) % 2:
                                raise ValueError('unaligned_pcm16')
                            if not pcm:
                                break
                            if not degraded:
                                if received + len(pcm) // 2 > max_seconds * 16000:
                                    await degrade('duration_limit')
                                else:
                                    scratch.write(pcm)
                                    scratch.flush()
                                    received += len(pcm) // 2
                                    changed.set()
                            await upstream.send(pcm)
                    except WebSocketDisconnect:
                        disconnected = True
                    finally:
                        stop = True
                        changed.set()
                        await upstream.send(b'')

                async def results():
                    nonlocal latest
                    async for raw in upstream:
                        message = json.loads(raw)
                        if message.get('type') == 'config':
                            await send({**message, 'diarization': not degraded})
                        elif message.get('type') == 'ready_to_stop':
                            return
                        elif 'lines' in message:
                            latest = message
                            await snapshot()
                        else:
                            await send(message)

                feeder = asyncio.create_task(feed())
                reader = asyncio.create_task(results())
                inference = asyncio.create_task(infer())
                tasks = [feeder, reader, inference]
                done, _ = await asyncio.wait([feeder, reader], return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    task.result()
                if reader in done and not feeder.done():
                    raise RuntimeError('upstream_early_eof')
                await asyncio.wait_for(asyncio.shield(reader), 60)
                await inference
                await send({'type': 'ready_to_stop', 'diarization_status': 'degraded' if degraded else 'ready'})
        except (Exception, asyncio.CancelledError):
            await send({'type': 'error', 'code': 'live_diarization_stream_failed'})
        finally:
            for task in tasks:
                task.cancel()
            for task in tasks:
                with suppress(Exception, asyncio.CancelledError):
                    await task
            if scratch is not None:
                scratch.close()
            active = False
            emit('session_finished', audio_s=round(received / 16000, 3), diarization_status='degraded' if degraded else 'ready')
            with suppress(WebSocketDisconnect, RuntimeError):
                await socket.close()

    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', required=True)
    parser.add_argument('--port', type=int, default=18091)
    parser.add_argument('--model', default='pyannote/speaker-diarization-3.1')
    parser.add_argument('--device', choices=['cpu', 'mps'], default='mps')
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--interval-seconds', type=float, default=15)
    parser.add_argument('--runtime-revision', default='')
    args = parser.parse_args()
    origin = urlsplit(args.upstream)
    if (origin.scheme != 'ws' or origin.hostname != '127.0.0.1' or not origin.port or
            origin.username or origin.password or origin.query or origin.fragment or origin.path != '/asr'):
        parser.error('upstream must be an explicit 127.0.0.1 ws /asr endpoint')
    if (not 1 <= args.port <= 65535 or args.port == origin.port or not 1 <= args.threads <= 16 or
            not 5 <= args.interval_seconds <= 120 or args.model not in {
                'pyannote/speaker-diarization-3.1', 'pyannote/speaker-diarization-community-1'}):
        parser.error('unsupported runtime configuration')
    os.umask(0o077)
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_DATASETS_OFFLINE='1',
                      PYANNOTE_METRICS_ENABLED='0')
    os.environ.setdefault('MPLCONFIGDIR', str(Path(sys.executable).parent.parent.parent / 'mpl'))
    report = os.fdopen(os.dup(1), 'w', buffering=1)
    null = os.open(os.devnull, os.O_WRONLY)
    os.dup2(null, 1)
    os.dup2(null, 2)
    os.close(null)
    logging.disable(logging.CRITICAL)

    def emit(event, **fields):
        report.write(json.dumps({'event': event, **fields}) + '\n')

    def local_only(event, values):
        if event == 'socket.getaddrinfo':
            if values[:2] != ('127.0.0.1', origin.port):
                raise PermissionError('network_resolution_disabled')
        if event == 'socket.connect':
            address = values[1]
            if isinstance(address, str):
                return
            if not isinstance(address, tuple) or address[:2] != ('127.0.0.1', origin.port):
                raise PermissionError('external_network_disabled')

    try:
        sys.addaudithook(local_only)
        import uvicorn
        app = create_app(PyannoteDiarizer(args.model, args.device, args.threads), args.upstream, emit,
                         interval_seconds=args.interval_seconds)
        uvicorn.run(app, host='127.0.0.1', port=args.port, access_log=False, log_config=None)
        return 0
    except Exception as error:
        emit('startup_failed', error_type=type(error).__name__)
        return 1


if __name__ == '__main__':
    sys.exit(main())
