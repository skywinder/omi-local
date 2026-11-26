import test from 'node:test';
import assert from 'node:assert/strict';
import {formatTime, segmentAt, playFrom, seekTo, speakerBadge, findTurns} from './player.mjs';

test('finds one literal phrase per turn and preserves the displayed character offsets', () => {
  const turns = [{text: '🎙 [Тест]+ ещё [тест]+'}, {text: 'без совпадения'}, {text: '[теСт]+ в конце'}];
  const matches = findTurns(turns, '  [тест]+ ');
  assert.deepEqual(matches.map(m => [m.index, turns[m.index].text.slice(m.start, m.end)]), [[0, '[Тест]+'], [2, '[теСт]+']]);
  assert.deepEqual(findTurns(turns, '  '), []);
  assert.deepEqual(findTurns(turns, '.*'), []);
  assert.deepEqual(findTurns([{text:'обновлено'}], '[тест]+'), []);
});

test('speaker labels follow edits while numbered speakers keep their live colors', () => {
  assert.deepEqual(speakerBadge({speaker: 'SPEAKER_05'}), {label: 'Говорящий 6', tone: '1'});
  assert.deepEqual(speakerBadge({speaker: 'SPEAKER_05', speaker_name: 'Ира'}), {label: 'Ира', tone: '1'});
  assert.deepEqual(speakerBadge({speaker_name: 'Ира', is_user: true}), {label: 'Вы', tone: 'neutral'});
  assert.deepEqual(speakerBadge({speaker: 'unknown'}), {label: '', tone: 'neutral'});
});

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
