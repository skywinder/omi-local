import test from 'node:test';
import assert from 'node:assert/strict';
import {mountRecordingSummary, summaryRequest, summaryStatus} from './recording-summary.mjs';

function dom(t) {
  class Element {
    children = []; attrs = {}; listeners = {}; dataset = {}; className = ''; value = ''; disabled = false; content = '';
    constructor(tag) { this.tag = tag; }
    append(...children) { for (const child of children) { child.parentElement = this; this.children.push(child); } }
    replaceChildren(...children) { this.children = []; this.append(...children); }
    set textContent(value) { this.content = value; this.children = []; }
    get textContent() { return this.content + this.children.map(child => child.textContent).join(''); }
    setAttribute(key, value) { this.attrs[key] = value; }
    removeAttribute(key) { delete this.attrs[key]; }
    addEventListener(event, fn) { this.listeners[event] = fn; }
    dispatch(event) { return this.listeners[event]?.({preventDefault() {}}); }
    focus() { this.focused = true; }
    reportValidity() { return true; }
    remove() { this.parentElement.children = this.parentElement.children.filter(child => child !== this); }
    querySelectorAll(selector) {
      return this.children.flatMap(child => [child, ...child.querySelectorAll('*')]).filter(child => selector === '*' || selector.split(',').some(item =>
        item.startsWith('.') ? child.className.split(' ').includes(item.slice(1)) : child.tag === item));
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  }
  const old = Object.getOwnPropertyDescriptor(globalThis, 'document');
  Object.defineProperty(globalThis, 'document', {configurable: true, value: {
    createElement: tag => new Element(tag), createDocumentFragment: () => new Element('fragment'),
  }});
  t.after(() => { if (old) Object.defineProperty(globalThis, 'document', old); else delete globalThis.document; });
  const root = new Element('section');
  return {root};
}

const options = () => ({source_revision: 'a'.repeat(64),
  providers: [{binding: 'b'.repeat(64), name: 'Local', model: 'next-model', host: 'localhost'}],
  templates: [{id: 'next', name: 'Next template', prompt: 'Find decisions.', digest: 'c'.repeat(64)},
    {id: 'brief', name: 'Brief', prompt: 'Be brief.', digest: 'd'.repeat(64)}],
  default_provider_binding: 'b'.repeat(64), default_template_id: 'next',
  published: {model: 'saved-model', template_name: 'Saved template'}, job: null,
});
const later = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return {promise, resolve}; };

test('inline choices submit a revision-bound request while provenance follows only publication', async t => {
  const {root} = dom(t); const requests = []; let poll; let response = options();
  const ui = mountRecordingSummary(root, {uuid: () => 'request-1', schedule: fn => { poll = fn; }, cancel: () => {},
    request: async (id, body) => { if (!body) return response; requests.push({id, body});
      return {state: 'queued', model: 'new-model', template_name: 'Brief'}; }});
  await ui.open('recording-a');
  assert.match(root.textContent, /Template: Saved template · Model: saved-model/);
  const [provider, template] = root.querySelectorAll('select');
  template.value = 'brief'; template.dispatch('change');
  assert.equal(root.querySelector('textarea').value, 'Be brief.');
  await root.querySelector('form').dispatch('submit');
  assert.equal(requests.length, 1);
  assert.deepEqual(requests[0].body, {source_revision: 'a'.repeat(64), provider_binding: provider.value,
    template_id: 'brief', template_digest: 'd'.repeat(64), prompt: 'Be brief.', request_id: 'request-1'});
  assert.match(root.textContent, /Template: Saved template · Model: saved-model/);
  assert.equal(root.querySelector('button').disabled, true);
  response = {...options(), published: {model: 'new-model', template_name: 'Brief'}, job: {state: 'ready'}};
  await poll();
  assert.match(root.textContent, /Template: Brief · Model: new-model/);
  assert.equal(template.value, 'brief');
  assert.equal(root.querySelector('button').disabled, false);
});

test('uncertain writes reuse their request ID; failed jobs keep the prior published provenance', async t => {
  const {root} = dom(t); const bodies = []; let serial = 0;
  const ui = mountRecordingSummary(root, {uuid: () => `request-${++serial}`,
    request: async (id, body) => { if (!body) return options(); bodies.push(body);
      if (bodies.length === 1) throw new Error('Response lost after admission');
      return {state: 'failed', error: 'recording_changed', model: 'failed-model'}; }});
  await ui.open('recording-a');
  await root.querySelector('form').dispatch('submit');
  await root.querySelector('form').dispatch('submit');
  assert.deepEqual(bodies[0], bodies[1]);
  assert.match(root.textContent, /Reload before generating again/);
  assert.match(root.textContent, /Model: saved-model/);
  assert.doesNotMatch(root.textContent, /failed-model/);
});

test('late reads and writes cannot populate a different recording', async t => {
  const {root} = dom(t); const first = later(); const write = later();
  const ui = mountRecordingSummary(root, {uuid: () => 'request',
    request: (id, body) => body ? write.promise : id === 'a' ? first.promise : Promise.resolve(options())});
  const pending = ui.open('a'); await ui.open('b');
  first.resolve({...options(), published: {model: 'wrong-recording'}}); await pending;
  assert.match(root.textContent, /Model: saved-model/);
  const submitting = root.querySelector('form').dispatch('submit');
  ui.open(null); write.resolve({state: 'ready'}); await submitting;
  assert.equal(root.hidden, true); assert.doesNotMatch(root.textContent, /wrong-recording/);
});

test('missing historical provenance is explicit and does not borrow current defaults', async t => {
  const {root} = dom(t);
  const ui = mountRecordingSummary(root, {request: async () => ({...options(), published: null})});
  await ui.open('a');
  assert.match(root.querySelector('p').textContent, /Template: not recorded · Model: not recorded/);
  assert.equal(summaryStatus({state: 'queued', progress: {phase: 'sections', completed: 2, total: 4}}),
    'Summarizing transcript sections. 2/4. You can leave this recording.');
});

test('summary writes use the existing guarded same-origin queue endpoint', async t => {
  const before = globalThis.fetch; let received;
  globalThis.fetch = async (...args) => { received = args; return {ok: true, json: async () => ({state: 'queued'})}; };
  t.after(() => { globalThis.fetch = before; });
  await summaryRequest('recording-a', {request_id: 'stable'});
  assert.equal(received[0], '/api/recordings/recording-a/summary');
  assert.equal(received[1].headers['X-Omiloc-Request'], 'summary');
  assert.deepEqual(JSON.parse(received[1].body), {request_id: 'stable'});
});
