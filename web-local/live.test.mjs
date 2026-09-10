import test from 'node:test';
import assert from 'node:assert/strict';
import {audioActivity} from './live.mjs';

const received = frames => ({backend: 'ready', capture: {state: 'received', frames_received: frames}});

test('audio badge requires increasing counters and reports a stalled stream', () => {
  const first = audioActivity(received(10), null, 1000, 0);
  assert.equal(first.tone, 'active');
  assert.equal(audioActivity(received(10), received(10), 6500, first.progress).tone, 'waiting');
  assert.equal(audioActivity(received(11), received(10), 7000, first.progress).tone, 'active');
});

test('disconnect, stop, and decoding errors do not masquerade as receiving audio', () => {
  assert.equal(audioActivity({backend: 'unavailable'}, received(10), 10, 0).tone, 'error');
  assert.equal(audioActivity({backend: 'ready', capture: {state: 'idle'}}, received(10), 10, 0).tone, 'idle');
  assert.equal(audioActivity({backend: 'ready', capture: {state: 'decode_error'}}, received(10), 10, 0).tone, 'error');
});
