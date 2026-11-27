import test from 'node:test';
import assert from 'node:assert/strict';
import {audioActivity, mountLiveMonitor} from './live.mjs';

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

function monitor(t, options) {
  class Element {
    children = [];
    dataset = {};
    content = '';
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this.children = children; }
    set textContent(value) { this.content = value; this.children = []; }
    get textContent() { return this.content + this.children.map(child => child.textContent).join(''); }
  }
  const root = new Element(), listeners = new Map(), timers = new Map(), requests = [];
  const document = {hidden: false, createElement: () => new Element(), createDocumentFragment: () => new Element()};
  for (const [key, value] of Object.entries({document, addEventListener: (event, listener) => listeners.set(event, listener)})) {
    const old = Object.getOwnPropertyDescriptor(globalThis, key);
    Object.defineProperty(globalThis, key, {value, configurable: true});
    t.after(() => { if (old) Object.defineProperty(globalThis, key, old); else delete globalThis[key]; });
  }
  let nextTimer = 0;
  t.mock.method(globalThis, 'setTimeout', callback => { timers.set(++nextTimer, callback); return nextTimer; });
  t.mock.method(globalThis, 'clearTimeout', id => timers.delete(id));
  t.mock.method(AbortSignal, 'timeout', () => new AbortController().signal);
  t.mock.method(globalThis, 'fetch', (url, options) => new Promise((resolve, reject) => {
    assert.equal(url, '/api/runtime');
    assert.equal(options.cache, 'no-store');
    requests.push({signal: options.signal, reject, reply: (text, diarization, sessions, stages) => resolve({ok: true, json: async () => ({
      backend: 'ready', capture: {state: 'received', frames_received: requests.length},
      sessions: sessions ?? [{source: 'omi', preview_id: 'synthetic-draft', text}],
      live_transcript: {state: 'streaming', updates: requests.length}, final_stt: {state: 'ready'}, events: [],
      observed_at: '2026-09-10T12:00:00Z', diarization, stages,
    })})});
  }));
  mountLiveMonitor(root, options);
  return {root, document, timers, requests,
    event: name => listeners.get(name)?.({persisted: true}),
    tick: () => {
      assert.equal(timers.size, 1, 'exactly one polling timer');
      const [[id, callback]] = timers;
      timers.delete(id);
      callback();
    },
  };
}

async function settle() {
  for (let step = 0; step < 6; step++) await Promise.resolve();
}

test('live monitor resumes after page restoration, skips hidden tabs, and recovers from fetch failure', async t => {
  const ui = monitor(t);
  ui.requests[0].reply('Первый черновик');
  await settle();
  assert.match(ui.root.textContent, /Первый черновик/);
  assert.match(ui.root.textContent, /Live text received/);
  ui.event('pagehide');
  assert.equal(ui.timers.size, 0);
  ui.event('pageshow');
  ui.event('pageshow');
  assert.equal(ui.requests.length, 2, 'restoration starts one request');
  ui.requests[1].reply('Свежий черновик');
  await settle();
  assert.match(ui.root.textContent, /Свежий черновик/);
  assert.doesNotMatch(ui.root.textContent, /Первый черновик/);
  ui.tick();
  ui.requests[2].reject(new Error('Synthetic connection failure'));
  await settle();
  assert.match(ui.root.textContent, /Server disconnected/);
  assert.doesNotMatch(ui.root.textContent, /Свежий черновик/);
  ui.document.hidden = true;
  ui.tick();
  assert.equal(ui.requests.length, 3);
  ui.document.hidden = false;
  ui.tick();
  ui.requests[3].reply('Связь восстановлена');
  await settle();
  assert.match(ui.root.textContent, /Связь восстановлена/);
  assert.equal(ui.timers.size, 1);
});

test('restoration during a pending fetch discards stale results without overlapping polling chains', async t => {
  const ui = monitor(t);
  ui.event('pagehide');
  assert.equal(ui.requests[0].signal.aborted, true);
  ui.event('pageshow');
  assert.equal(ui.requests.length, 1, 'wait for aborted request to settle');
  ui.requests[0].reply('Устаревший черновик');
  await settle();
  assert.doesNotMatch(ui.root.textContent, /Устаревший черновик/);
  ui.tick();
  assert.equal(ui.requests.length, 2);
  ui.event('pagehide');
  ui.requests[1].reject(new Error('Synthetic aborted request'));
  await settle();
  assert.equal(ui.timers.size, 0, 'hidden page does not restart its timer');
  assert.doesNotMatch(ui.root.textContent, /Server disconnected/);
  ui.event('pageshow');
  ui.requests[2].reply('Текущий черновик');
  await settle();
  assert.match(ui.root.textContent, /Текущий черновик/);
  assert.equal(ui.timers.size, 1);
});


test('diarization distinguishes service readiness, labels, degradation and lost status', async t => {
  const ui = monitor(t);
  for (const [state, label, count] of [
    ['ready', 'Service ready', 0], ['pending', 'waiting for labels', 0],
    ['labeled', 'Labels received', 3], ['degraded', 'Speaker labeling error', 0],
    ['disabled', 'Disabled', 0], ['unknown', 'Unknown', 0],
  ]) {
    if (ui.requests.length > 1 || state !== 'ready') ui.tick();
    ui.requests.at(-1).reply('Текст продолжает поступать', {state, labeled_segments: count});
    await settle();
    assert.ok(ui.root.textContent.includes(label));
    assert.match(ui.root.textContent, /Live text received/);
    if (state === 'labeled') assert.match(ui.root.textContent, /this transcript: 3/);
    else assert.doesNotMatch(ui.root.textContent, /this transcript: 3/);
  }
  ui.tick();
  ui.requests.at(-1).reject(new Error('Disconnected'));
  await settle();
  assert.doesNotMatch(ui.root.textContent, /Labels received|Service ready/);
});

test('live source distinguishes two internal microphones and an attached CV1', async () => {
  const {liveSourceLabel} = await import('./live.mjs');
  assert.equal(liveSourceLabel({source: 'phone', origin: {phone_platform: 'ios'}}), 'iPhone · Built-in microphone');
  assert.equal(liveSourceLabel({source: 'phone', origin: {phone_model: 'Pixel 5a'}}), 'Pixel 5a · Built-in microphone');
  assert.equal(liveSourceLabel({source: 'omi', origin: {phone_model: 'iPhone Air'}}), 'iPhone Air · Omi CV1');
  assert.equal(liveSourceLabel({source: 'phone'}), 'Built-in microphone');
});

test('recording failure identifies the failed stage even with a saved transcript', async () => {
  const {processingFailure} = await import('./recording-processing.mjs');
  const record = {status: 'failed', attempts: 3, processing: {stt: {status: 'ready'}, summary: {status: 'failed', error_code: 'invalid_json'}}};
  assert.match(processingFailure(record), /Summarization.*JSON.*3/);
  assert.match(processingFailure({...record, processing: {}}), /failed stage was not recorded/);
});


test('a draft moves into the existing speaker bubble when the turn grows', async t => {
  const ui = monitor(t);
  const first = {speaker: 'SPEAKER_00', start: 1, text: 'Начало.'};
  const session = {source: 'phone', preview_id: 'example', revision: 1,
    segments: [first, {is_draft: true, text: 'Продолжение'}]};
  ui.requests[0].reply('', {}, [session]);
  await settle();
  assert.match(ui.root.textContent, /Начало\.DraftПродолжение/);
  ui.tick();
  ui.requests[1].reply('', {}, [{...session, revision: 2, segments: [first], withdrawn: {text: 'Продолжение', end: 2}}]);
  await settle();
  assert.match(ui.root.textContent, /Начало\.Previous text · unconfirmedПродолжение/);
  ui.tick();
  ui.requests[2].reply('', {}, [{...session, revision: 3, segments: [{...first, text: 'Начало. Продолжение.'}]}]);
  await settle();
  assert.match(ui.root.textContent, /Speaker 1 · 0:01Начало\. Продолжение\./);
  assert.equal(ui.root.textContent.split('Продолжение').length, 2);
});

test('parallel inputs keep independent activity and update speaker turns without duplicating drafts', async t => {
  const ui = monitor(t);
  let now = 1000;
  t.mock.method(Date, 'now', () => now);
  const phone = {source: 'phone', preview_id: 'phone', origin: {phone_platform: 'ios'},
    frames_received: 5, segments: [{speaker: 'SPEAKER_00', start: 1, text: 'Один'},
      {speaker: 'SPEAKER_00', start: 2, text: 'два'}, {is_draft: true, text: 'три'}]};
  const cv1 = {source: 'omi', preview_id: 'cv1', frames_received: 4, text: 'Другой поток'};
  const poll = async (first, second) => {
    ui.requests.at(-1).reply('', {}, [first, second]);
    await settle();
  };
  await poll(phone, cv1);
  assert.match(ui.root.textContent, /Speaker 1 · 0:01Один дваDraftтри/);
  assert.match(ui.root.textContent, /Checking streamДругой поток/);
  now += 6000; ui.tick();
  await poll({...phone, frames_received: 6, segments: [{speaker: 'SPEAKER_01', start: 3, text: 'Три'}]}, cv1);
  assert.match(ui.root.textContent, /Receiving audioSpeaker 2 · 0:03Три/);
  assert.match(ui.root.textContent, /No frames for at least 5 secondsДругой поток/);
  assert.match(ui.root.textContent, /Need attention: 1 of 2/);
  assert.doesNotMatch(ui.root.textContent, /Один два|Draftтри/);
});


test('sidebar and service badges share monitor observations and discard expired evidence', async t => {
  const observations = [];
  const ui = monitor(t, {onSources: (labels, activity) => observations.push({labels, activity})});
  const stages = {stale: false, summary: {status: 'ready', name: 'Demo'}};
  ui.requests[0].reply('Синтетическая речь', {}, [{source: 'omi'}], stages);
  await settle();
  assert.deepEqual(observations[0].labels, ['Omi CV1']);
  assert.match(ui.root.textContent, /Summary model · available/);
  ui.tick(); ui.requests[1].reply('', {}, [], {...stages, stale: true});
  await settle();
  assert.match(ui.root.textContent, /Summary model · check expired/);
  assert.deepEqual(observations[1].labels, []);
  ui.tick(); ui.requests[2].reject(Error('offline'));
  await settle();
  assert.match(ui.root.textContent, /Summary model · no data/);
  assert.deepEqual(observations[2].labels, []);
});

test('an idle iPhone remains in its own stream while the headline identifies audio from Pixel', async t => {
  let now = 1000;
  t.mock.method(Date, 'now', () => now);
  const observations = [];
  const ui = monitor(t, {onSources: (labels, activity) => observations.push({labels, activity})});
  const iphone = {source: 'omi', preview_id: 'fixture-a', frames_received: 0, origin: {phone_model: 'iPhone Air'}};
  const pixel = {source: 'phone', preview_id: 'fixture-b', frames_received: 2, origin: {phone_model: 'Pixel 5a'}};
  ui.requests[0].reply('', {}, [iphone, pixel]);
  await settle();
  assert.equal(observations.at(-1).activity.label, 'Connected inputs');
  ui.tick();
  now += 1000;
  ui.requests[1].reply('', {}, [iphone, {...pixel, frames_received: 5}]);
  await settle();
  assert.deepEqual(observations.at(-1), {labels: ['Pixel 5a · Built-in microphone'],
    activity: {label: 'Receiving audio', tone: 'active'}});
  assert.match(ui.root.textContent, /iPhone Air · Omi CV1.*Waiting for the first frames/);
});
