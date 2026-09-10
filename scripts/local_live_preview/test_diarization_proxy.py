"""Behavioral stream tests with controllable inference and exact synthetic timed words."""

import asyncio
import json
import threading
import unittest

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from .diarization_proxy import SpeakerHistory, create_app, labeled_snapshot, maximum_assignment


WORDS = [{'word': 'Yes', 'start': 0.1, 'end': 0.6}, {'word': '.', 'start': 0.6, 'end': 0.6},
         {'word': ' No', 'start': 1.1, 'end': 1.6}]
MESSAGE = {'lines': [{'text': 'Yes. No', 'start': 0.1, 'end': 1.6, 'speaker': -1, 'words': WORDS}],
           'buffer_transcription': ' unfinished'}


class SpeakerMappingTests(unittest.TestCase):
    def test_optimal_assignment_beats_greedy_and_permits_unmatched(self):
        self.assertEqual(maximum_assignment([[9, 8], [8, 0], [0, 0]]), {0: 1, 1: 0})

    def test_cluster_renumbering_keeps_session_speakers_and_assigns_new_voice(self):
        history = SpeakerHistory()
        self.assertEqual(history.update([(0, 1, 'a'), (1, 2, 'b')]), [(0, 1, 1), (1, 2, 2)])
        self.assertEqual(history.update([(0, 1, 'b'), (1, 2, 'a'), (2, 3, 'c')]),
                         [(0, 1, 1), (1, 2, 2), (2, 3, 3)])

    def test_exact_word_split_and_punctuation_with_unconfirmed_tail(self):
        result = labeled_snapshot(MESSAGE, [(0, 0.9, 1), (1, 2, 2)], 1, 'pending')
        self.assertEqual([line['speaker'] for line in result['lines']], [1, -1])
        self.assertEqual([line['text'] for line in result['lines']], ['Yes.', 'No'])
        self.assertEqual(result['buffer_transcription'], ' unfinished')
        self.assertEqual(result['lines'][0]['words'][1]['speaker'], 1)
        complete = labeled_snapshot(MESSAGE, [(0, 0.9, 1), (1, 2, 2)], 2, 'ready')
        self.assertEqual([line['speaker'] for line in complete['lines']], [1, 2])
        self.assertEqual([w['word'] for line in complete['lines'] for w in line['words']], [w['word'] for w in WORDS])

    def test_missing_or_inconsistent_word_timing_preserves_original_text(self):
        line = {'text': 'synthetic exact text', 'speaker': -1, 'start': 0, 'end': 1,
                'words': [{'word': 'wrong', 'start': 0, 'end': 1}]}
        self.assertEqual(labeled_snapshot({'lines': [line]}, [(0, 1, 2)], 2, 'ready')['lines'], [line])
        line['words'] = [{'word': line['text'], 'start': 1, 'end': 0}]
        self.assertEqual(labeled_snapshot({'lines': [line]}, [(0, 1, 2)], 2, 'ready')['lines'], [line])

    def test_silence_and_overlapping_word_end_are_preserved(self):
        silence = {'text': '', 'speaker': -2, 'start': 0, 'end': 2}
        line = {'text': 'hello,', 'start': 0, 'end': 2,
                'words': [{'word': 'hello', 'start': 0, 'end': 2}, {'word': ',', 'start': 1, 'end': 1}]}
        result = labeled_snapshot({'lines': [silence, line]}, [(0, 2, 1)], 2, 'ready')['lines']
        self.assertEqual(result[0], silence)
        self.assertEqual(result[1]['end'], 2)


class FakeUpstream:
    def __init__(self):
        self.messages = asyncio.Queue()

    async def __aenter__(self):
        await self.messages.put(json.dumps({'type': 'config', 'mode': 'full', 'diarization': False,
                                            'stt_provider': 'synthetic-asr'}))
        return self

    async def __aexit__(self, *args):
        pass

    def __aiter__(self):
        return self

    async def __anext__(self):
        return await self.messages.get()

    async def send(self, pcm):
        await self.messages.put(json.dumps(MESSAGE if pcm else {'type': 'ready_to_stop'}))


class FakeDiarizer:
    def __init__(self, fail=False):
        self.release = threading.Event()
        self.started = threading.Event()
        self.loads, self.calls = 0, 0
        self.fail = fail
        self.scratch = None

    def load(self):
        self.loads += 1

    def infer(self, scratch, count):
        self.calls += 1
        self.scratch = scratch
        self.started.set()
        if not self.release.wait(5):
            raise RuntimeError('test_inference_release_missing')
        if scratch.closed:
            raise AssertionError('scratch_closed_during_inference')
        if self.fail:
            raise RuntimeError('synthetic inference failure')
        return [(0, 0.9, 'b'), (1, min(count / 16000, 2), 'a')]


class ProxyStreamTests(unittest.TestCase):
    def client(self, model, events):
        return TestClient(create_app(model, 'ws://127.0.0.1:18090/asr',
                                    lambda event, **fields: events.append((event, fields)),
                                    interval_seconds=1, connect=lambda *a, **kw: FakeUpstream()))

    def test_asr_is_immediate_while_inference_runs_then_revised_before_eof(self):
        model, events = FakeDiarizer(), []
        try:
            with self.client(model, events) as client:
                with client.websocket_connect('/asr') as ws:
                    config = ws.receive_json()
                    self.assertIs(config['diarization'], True)
                    self.assertEqual(config['stt_provider'], 'synthetic-asr')
                    ws.send_bytes(b'\0\0' * 32000)
                    pending = ws.receive_json()
                    self.assertEqual(pending['lines'][0]['text'], 'Yes. No')
                    self.assertEqual(pending['lines'][0]['speaker'], -1)
                    self.assertEqual(pending['diarization_status'], 'pending')
                    self.assertTrue(model.started.wait(5))
                    model.release.set()
                    split = ws.receive_json()
                    self.assertEqual([line['speaker'] for line in split['lines']], [1, 2])
                    self.assertEqual(split['buffer_transcription'], ' unfinished')
                    ws.send_bytes(b'')
                    self.assertEqual(ws.receive_json()['type'], 'ready_to_stop')
                self.assertFalse(client.get('/health').json()['active'])
                with client.websocket_connect('/asr') as fresh:
                    fresh.receive_json()
                    fresh.send_bytes(b'')
                    self.assertEqual(fresh.receive_json()['type'], 'ready_to_stop')
            self.assertEqual(model.loads, 1)
            self.assertEqual(model.calls, 1)
        finally:
            model.release.set()

    def test_failure_is_explicit_and_preserves_asr_then_allows_next_session(self):
        model, events = FakeDiarizer(fail=True), []
        try:
            with self.client(model, events) as client:
                with client.websocket_connect('/asr') as ws:
                    ws.receive_json()
                    ws.send_bytes(b'\0\0' * 32000)
                    self.assertEqual(ws.receive_json()['lines'][0]['text'], 'Yes. No')
                    model.release.set()
                    status = ws.receive_json()
                    self.assertEqual(status['type'], 'diarization_status')
                    self.assertEqual(status['status'], 'degraded')
                    self.assertEqual(ws.receive_json()['lines'][0]['text'], 'Yes. No')
                    ws.send_bytes(b'')
                    self.assertEqual(ws.receive_json()['diarization_status'], 'degraded')
                self.assertFalse(client.get('/health').json()['active'])
            self.assertIn(('diarization_degraded', {'code': 'inference_failed'}), events)
        finally:
            model.release.set()

    def test_second_session_is_rejected_while_first_is_open(self):
        model = FakeDiarizer()
        with self.client(model, []) as client:
            with client.websocket_connect('/asr') as first:
                first.receive_json()
                with client.websocket_connect('/asr') as second:
                    with self.assertRaises(WebSocketDisconnect) as error:
                        second.receive_json()
                    self.assertEqual(error.exception.code, 1013)
                first.send_bytes(b'')
                self.assertEqual(first.receive_json()['type'], 'ready_to_stop')

    def test_scratch_failure_releases_single_session_gate(self):
        def unavailable(**kwargs):
            raise OSError('synthetic scratch unavailable')
        model = FakeDiarizer()
        app = create_app(model, 'ws://127.0.0.1:18090/asr', lambda *a, **kw: None,
                         connect=lambda *a, **kw: FakeUpstream(), scratch_factory=unavailable)
        with TestClient(app) as client:
            for _ in range(2):
                with client.websocket_connect('/asr') as ws:
                    self.assertEqual(ws.receive_json()['type'], 'error')
                self.assertFalse(client.get('/health').json()['active'])

    def test_failed_stream_drains_native_inference_before_closing_pcm_or_releasing_gate(self):
        model = FakeDiarizer()
        try:
            with self.client(model, []) as client:
                with client.websocket_connect('/asr') as ws:
                    ws.receive_json()
                    ws.send_bytes(b'\0\0' * 32000)
                    ws.receive_json()
                    self.assertTrue(model.started.wait(5))
                    ws.send_bytes(b'\0')
                    self.assertEqual(ws.receive_json()['type'], 'error')
                    self.assertTrue(client.get('/health').json()['active'])
                    self.assertFalse(model.scratch.closed)
                    model.release.set()
                self.assertFalse(client.get('/health').json()['active'])
                self.assertTrue(model.scratch.closed)
        finally:
            model.release.set()


if __name__ == '__main__':
    unittest.main()
