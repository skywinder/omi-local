import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';

const source = readFileSync(new URL('./reload.mjs', import.meta.url), 'utf8');
const original = {styles: 'a'.repeat(64), page: 'b'.repeat(64)};
const cssEdit = {...original, styles: 'c'.repeat(64)};
const scriptEdit = {...cssEdit, page: 'd'.repeat(64)};

function browser() {
  const listeners = new Map(), timers = new Map(), requests = [], links = [];
  let nextTimer = 0, reloads = 0;
  class Link {
    href = '/style.css';
    removed = false;
    cloneNode() { return new Link(); }
    after(link) { links.push(link); }
    remove() { this.removed = true; }
  }
  links.push(new Link());
  const document = {hidden: false, deleting: false, querySelector(selector) {
    if (selector === 'meta[name="omiloc-assets"]') return {content: JSON.stringify(original)};
    if (selector === 'link[rel="stylesheet"]') return links.find(link => !link.removed);
    if (selector === '#delete-confirm:disabled') return this.deleting ? {} : null;
    throw new Error(`Unexpected selector: ${selector}`);
  }};
  runInNewContext(source, {
    document, location: {reload: () => reloads++}, AbortController,
    AbortSignal: {any: AbortSignal.any, timeout: () => new AbortController().signal},
    addEventListener: (event, callback) => listeners.set(event, callback),
    setTimeout: callback => { timers.set(++nextTimer, callback); return nextTimer; },
    clearTimeout: id => timers.delete(id),
    fetch: (url, options) => new Promise((resolve, reject) => {
      assert.equal(url, '/api/assets');
      assert.equal(options.cache, 'no-store');
      requests.push({reject, signal: options.signal,
        reply: (versions, ok = true) => resolve({ok, json: async () => versions})});
    }),
  });
  return {document, requests, links, timers, get reloads() { return reloads; },
    event: name => listeners.get(name)(),
    tick: () => {
      assert.equal(timers.size, 1, 'one polling chain');
      const [[id, callback]] = timers;
      timers.delete(id);
      callback();
    },
  };
}

async function settle() { for (let step = 0; step < 10; step++) await Promise.resolve(); }

test('CSS swaps only after load, unchanged revisions do nothing, code edits reload once', async () => {
  const ui = browser();
  ui.requests[0].reply(original);
  await settle();
  assert.equal(ui.links.length, 1);
  ui.tick();
  ui.requests[1].reply(cssEdit);
  await settle();
  assert.equal(ui.links[0].removed, false);
  assert.equal(ui.links[1].href, `/style.css?v=${cssEdit.styles}`);
  assert.equal(ui.reloads, 0);
  ui.links[1].onload();
  await settle();
  assert.equal(ui.links[0].removed, true);
  ui.tick();
  ui.requests[2].reply(cssEdit);
  await settle();
  assert.equal(ui.links.length, 2);
  ui.tick();
  ui.requests[3].reply(scriptEdit);
  await settle();
  assert.equal(ui.reloads, 1);
  assert.equal(ui.timers.size, 0);
});

test('temporary failures retain current CSS and retry without forgetting the last loaded version', async () => {
  const ui = browser();
  ui.requests[0].reject(new Error('Server restarting'));
  await settle();
  ui.tick();
  ui.requests[1].reply({page: 'invalid'});
  await settle();
  ui.tick();
  ui.requests[2].reply(cssEdit);
  await settle();
  ui.links[1].onerror();
  await settle();
  assert.equal(ui.links[0].removed, false);
  assert.equal(ui.links[1].removed, true);
  ui.tick();
  ui.requests[3].reply(cssEdit);
  await settle();
  ui.links[2].onload();
  await settle();
  assert.equal(ui.links[0].removed, true);
  assert.equal(ui.links[2].removed, false);
  assert.equal(ui.reloads, 0);
});

test('page restoration ignores stale requests, suspends hidden polling, and defers reload during deletion', async () => {
  const ui = browser();
  ui.event('pagehide');
  assert.equal(ui.requests[0].signal.aborted, true);
  ui.event('pageshow');
  ui.event('pageshow');
  assert.equal(ui.requests.length, 1);
  ui.requests[0].reply(scriptEdit);
  await settle();
  assert.equal(ui.reloads, 0);
  ui.document.hidden = true;
  ui.tick();
  assert.equal(ui.requests.length, 1);
  ui.document.hidden = false;
  ui.document.deleting = true;
  ui.tick();
  ui.requests[1].reply(scriptEdit);
  await settle();
  assert.equal(ui.reloads, 0);
  ui.document.deleting = false;
  ui.tick();
  ui.requests[2].reply(scriptEdit);
  await settle();
  assert.equal(ui.reloads, 1);
});
