import test from 'node:test';
import assert from 'node:assert/strict';
import {mountLiveTuning, tuningStatus} from './live-tuning.mjs';

function setup(t, request) {
  class Element {
    children = []; listeners = {}; attrs = {}; dataset = {}; value = ''; content = '';
    constructor(tag) { this.tag = tag; }
    append(...children) { this.children.push(...children); }
    setAttribute(key, value) { this.attrs[key] = value; }
    addEventListener(event, fn) { this.listeners[event] = fn; }
    fire(event) { this.listeners[event]?.({preventDefault() {}}); }
    reportValidity() { return true; }
    set textContent(value) { this.content = value; }
    get textContent() { return this.content + this.children.map(c => c.textContent).join(''); }
    all() { return this.children.flatMap(c => [c, ...c.all()]); }
  }
  const root = new Element('section');
  root.open = true;
  root.closest = () => null;
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'document');
  Object.defineProperty(globalThis, 'document', {configurable: true,
    value: {hidden: false, createElement: tag => new Element(tag)}});
  t.after(() => {
    if (previous) Object.defineProperty(globalThis, 'document', previous);
    else delete globalThis.document;
  });
  const refresh = mountLiveTuning(root, request);
  return {root, refresh, fields: root.all().find(n => n.tag === 'fieldset'),
    field: name => root.all().find(n => n.id === 'live-' + name),
    slider: label => root.all().find(n => n.attrs['aria-label'] === label)};
}
async function settle() { for (let i = 0; i < 15; i++) await Promise.resolve(); }
const initial = () => ({available: true, revision: 1, active_sessions: 1, applied_sessions: 1, failed_sessions: 0,
  settings: {asr_coalesce_min_s: 2, max_speakers: 2, preview_mode: 'stable'}});

test('slider and number share values; release writes once and waits for server acknowledgement', async t => {
  let state = initial(); const calls = [];
  const ui = setup(t, async (path, body) => {
    assert.equal(path, '/live-tuning');
    if (body) { calls.push(body); state = {...state, revision: 2, settings: body.settings, applied_sessions: 0}; }
    return structuredClone(state);
  });
  await ui.refresh();
  const slider = ui.slider('Audio buffer (seconds)');
  slider.value = '3.5'; slider.fire('input');
  assert.equal(ui.field('asr_coalesce_min_s').value, '3.5');
  assert.equal(calls.length, 0);
  slider.fire('change'); await settle();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].settings.asr_coalesce_min_s, 3.5);
  assert.deepEqual(calls[0].changed_fields, ['asr_coalesce_min_s']);
  assert.match(ui.root.textContent, /Applying to the current stream/);
  state.applied_sessions = 1;
  await ui.refresh();
  assert.match(ui.root.textContent, /Applied. New segments/);
  const speakers = ui.field('max_speakers'); speakers.value = '3'; speakers.fire('input');
  assert.equal(ui.slider('Maximum speakers').value, '3');
  speakers.fire('change'); await settle();
  assert.equal(calls[1].settings.max_speakers, 3);
  assert.deepEqual(calls[1].changed_fields, ['max_speakers']);
});

test('conflict and unavailable server never masquerade as applied controls', async t => {
  const ui = setup(t, async (_path, body) => {
    if (body) throw new Error('Settings changed. Reload the values.');
    return initial();
  });
  await ui.refresh();
  const input = ui.field('asr_coalesce_min_s'); input.value = '4'; input.fire('change');
  await settle();
  assert.match(ui.root.textContent, /Settings changed/);
  assert.equal(ui.fields.disabled, true);
  assert.doesNotMatch(ui.root.textContent, /Applied./);
  assert.match(tuningStatus({...initial(), failed_sessions: 1}), /did not confirm/);
  assert.match(tuningStatus({...initial(), active_sessions: 0}), /next recording/);
  assert.match(tuningStatus({...initial(), pending_sessions: 1}), /next recording/);
  assert.match(tuningStatus({available: false}), /unavailable/);
});

test('a stale background refresh cannot overwrite a confirmed slider change', async t => {
  let reads = 0, finishRefresh; const writes = [];
  const ui = setup(t, async (_path, body) => {
    if (body) { writes.push(body); return {...initial(), revision: 2, settings: body.settings}; }
    if (++reads === 2) return new Promise(resolve => { finishRefresh = resolve; });
    return initial();
  });
  await ui.refresh();
  const refreshing = ui.refresh();
  const slider = ui.slider('Audio buffer (seconds)');
  slider.value = '4'; slider.fire('input'); slider.fire('change');
  await settle();
  assert.equal(writes.length, 1);
  assert.equal(writes[0].revision, 1);
  assert.equal(writes[0].settings.asr_coalesce_min_s, 4);
  finishRefresh(initial()); await refreshing;
  assert.equal(Number(slider.value), 4);
  assert.match(ui.root.textContent, /Applied./);
});
