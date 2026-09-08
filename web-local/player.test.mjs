import test from 'node:test';
import assert from 'node:assert/strict';
import {formatTime, segmentAt, playFrom, seekTo} from './player.mjs';

test('clicking a phrase seeks before starting playback; seeks remain within the recording', async () => {
  const events = [];
  const audio = {set currentTime(t) { events.push(['seek', t]); }, async play() { events.push(['play']); }};
  await playFrom(audio, 12.3, 40);
  assert.deepEqual(events, [['seek', 12.3], ['play']]);
  seekTo(audio, -10, 40);
  seekTo(audio, 90, 40);
  assert.deepEqual(events.slice(-2), [['seek', 0], ['seek', 40]]);
});
test('highlight follows timestamp boundaries and silence', () => {
  const segments = [{start: 1, end: 2}, {start: 3, end: 4}];
  assert.deepEqual([0, 1, 1.9, 2, 3, 4].map(t => segmentAt(segments, t)), [-1, 0, 0, -1, 1, -1]);
  assert.equal(formatTime(3661), '1:01:01');
});
test('playback rejection reaches the UI error handler', async () => {
  await assert.rejects(playFrom({async play() { throw new Error('media unavailable'); }}, 0, 20), /media unavailable/);
});
