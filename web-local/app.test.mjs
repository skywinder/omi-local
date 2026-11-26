import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
import {processingFailure} from './recording-processing.mjs';
import {categories, categoryLabel} from './recording-categories.mjs';
import {findTurns, formatTime, segmentAt} from './player.mjs';

// Execute the production controller with DOM/network seams; rendering has its own tests.
const source = readFileSync(new URL('./app.js', import.meta.url), 'utf8').replace(/^import .*;\n/gm, '');
const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
function browser() {
  class Element {
    children = []; listeners = {}; attrs = {}; dataset = {}; value = ''; content = ''; hidden = false;
    currentTime = 0; paused = true; classList = {toggle() {}};
    get childElementCount() { return this.children.length; }
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this.children = children; }
    set textContent(value) { this.content = value; this.children = []; }
    get textContent() { return this.content + this.children.map(child => child.textContent).join(''); }
    setAttribute(key, value) { this.attrs[key] = value; }
    getAttribute(key) { return this.attrs[key]; }
    removeAttribute(key) { delete this.attrs[key]; if (key === 'src') delete this.src; }
    addEventListener(event, listener) { this.listeners[event] = listener; }
    click() { return this.listeners.click?.(); }
    querySelectorAll() { return []; }
    querySelector() { return null; }
    focus() {}
    closest() { return this; }
    showModal() { this.open = true; }
    close() { this.open = false; this.listeners.close?.(); }
    pause() { this.paused = true; }
    load() {}
  }
  const nodes = Object.fromEntries([...html.matchAll(/\bid="([^"]+)"/g)].map(([, id]) => [id, new Element()]));
  const requests = [];
  runInNewContext(source, {
    document: {getElementById(id) { assert.ok(nodes[id], `HTML contains ${id}`); return nodes[id]; },
      createElement: () => new Element(), createDocumentFragment: () => new Element(),
      createTextNode: textContent => ({textContent}),
      querySelectorAll: () => [], addEventListener() {}},
    formatTime, segmentAt, findTurns, categories, categoryLabel, processingFailure,
    mountRecordingSummary: () => ({open() {}, refresh() {}}), mountSettings: () => ({}),
    mountSummaryTemplates() {}, mountLiveTuning() {}, mountLiveMonitor() {}, renderProcessing() {},
    matchMedia: () => ({matches: false}), location: {hash: ''}, setInterval() {}, AbortSignal,
    fetch: (url, options) => new Promise(resolve => requests.push({url, options, reply: (body, ok = true) => resolve({ok, json: async () => body})})),
  });
  return {nodes, requests};
}
const record = {id: 'synthetic', started_at: '2026-10-29T10:00:00Z', source: 'CV1', duration: 20,
  preview: 'Сохранённая фраза', status: 'ready', segments: []};
async function settle() { for (let i = 0; i < 15; i++) await Promise.resolve(); }
function archiveButton(ui) { return ui.nodes.recordings.children[0].children.find(e => e.listeners.click); }

test('waiting card opens its status without requesting detail or audio and respects visibility', async () => {
  const ui = browser();
  ui.requests[0].reply({recordings: [{...record, status: 'waiting_for_parts', has_audio: false}]});
  await settle();
  assert.match(archiveButton(ui).textContent, /Waiting for upload/);
  await archiveButton(ui).click();
  assert.equal(ui.requests.length, 1);
  assert.equal(ui.nodes.welcome.hidden, false);
  assert.equal(ui.nodes['welcome-title'].textContent, 'Waiting for upload');
  assert.equal(ui.nodes.player.hidden, true);
  assert.equal(ui.nodes['retry-recording'].hidden, true);
  ui.nodes['filter-no-audio'].checked = true;
  ui.nodes['visibility-form'].listeners.submit({preventDefault() {}});
  assert.equal(ui.nodes.count.textContent, '0');
});

test('retry opens the selected recording after a transient detail error', async () => {
  const ui = browser();
  ui.requests[0].reply({recordings: [record]}); await settle();
  const first = archiveButton(ui).click();
  ui.requests[1].reply({}, false); await first;
  assert.equal(ui.nodes.player.hidden, true);
  assert.equal(ui.nodes['retry-recording'].hidden, false);
  ui.nodes['retry-recording'].click();
  assert.equal(ui.requests[2].url, ui.requests[1].url);
  ui.requests[2].reply(record); await settle();
  assert.equal(ui.nodes['recording-detail'].hidden, false);
  assert.equal(ui.nodes.player.hidden, false);
  assert.equal(ui.nodes.audio.src, '/api/recordings/synthetic/audio');
});
