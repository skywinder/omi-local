import {formatTime, segmentAt, seekTo, playFrom} from '/player.mjs';

const $ = id => document.getElementById(id);
const audio = $('audio');
const state = {records: [], selected: null, detail: null, filter: false, request: 0, active: -1, loading: false, deleting: false, deleteId: null};
const statuses = {ready: 'Транскрипт готов', pending: 'В очереди', processing: 'Распознаётся', failed: 'Ошибка распознавания', unavailable: 'Без транскрипта'};
const day = value => new Date(value).toLocaleDateString('ru-RU', {day: 'numeric', month: 'long', year: 'numeric'});
const hour = value => new Date(value).toLocaleTimeString('ru-RU', {hour: '2-digit', minute: '2-digit'});
function node(tag, cls, text) { const el = document.createElement(tag); if (cls) el.className = cls; if (text !== undefined) el.textContent = text; return el; }
async function get(path) { const response = await fetch(path, {cache: 'no-store', signal: AbortSignal.timeout(10000)}); if (!response.ok) throw new Error('Unavailable'); return response.json(); }
function message(text = '') { $('player-message').textContent = text; $('player-message').hidden = !text; }

function renderList() {
  const query = $('search').value.trim().toLocaleLowerCase('ru-RU');
  const items = state.records.filter(r => (!state.filter || r.status === 'ready') && `${r.preview} ${day(r.started_at)} ${hour(r.started_at)} ${r.source}`.toLocaleLowerCase('ru-RU').includes(query));
  $('count').textContent = state.records.length;
  const fragment = document.createDocumentFragment();
  let previous = '';
  for (const r of items) {
    const date = day(r.started_at);
    if (date !== previous) { fragment.append(node('p', 'group-label', date)); previous = date; }
    const button = node('button', `recording${state.selected === r.id ? ' active' : ''}`);
    button.setAttribute('aria-pressed', String(state.selected === r.id));
    const top = node('span', 'recording-top', `Запись в ${hour(r.started_at)}`);
    top.append(node('span', 'recording-length', formatTime(r.duration)));
    button.append(top, node('p', 'recording-preview', r.preview || statuses[r.status]));
    const bottom = node('span', 'recording-bottom');
    bottom.append(node('span', 'source', r.source), node('span', '', statuses[r.status]));
    button.append(bottom);
    button.addEventListener('click', () => select(r.id));
    fragment.append(button);
  }
  if (!items.length) fragment.append(node('p', 'empty-list', state.records.length ? 'Ничего не найдено. Попробуйте другую дату или сбросьте фильтр.' : 'Записей пока нет. Завершите запись на CV1 — она появится здесь автоматически.'));
  $('recordings').replaceChildren(fragment);
}

function renderTranscript(record) {
  const fragment = document.createDocumentFragment();
  record.segments.forEach((segment, index) => {
    const button = node('button', 'segment');
    button.setAttribute('aria-label', `Слушать с ${formatTime(segment.start)}: ${segment.text}`);
    button.append(node('span', 'segment-time', formatTime(segment.start)));
    const content = node('span', '');
    if (segment.speaker) content.append(node('span', 'segment-speaker', `Говорящий ${Number(segment.speaker.split('_')[1]) + 1}`));
    content.append(node('span', 'segment-text', segment.text));
    button.append(content);
    button.addEventListener('click', async () => {
      message();
      try { await playFrom(audio, segment.start, record.duration); syncPlayer(); }
      catch { message('Не удалось включить звук. Нажмите кнопку воспроизведения.'); }
    });
    fragment.append(button);
  });
  if (!record.segments.length) {
    const copy = {pending: 'Запись ожидает распознавания. Аудио уже можно слушать.', processing: 'Распознаём речь на Mac. Текст появится автоматически.', failed: 'Распознавание не завершилось. Аудиозапись сохранена и доступна для прослушивания.', unavailable: 'Для этой записи пока нет транскрипта. Аудио можно слушать уже сейчас.'};
    fragment.append(node('p', 'empty-transcript', copy[record.status] || copy.unavailable));
  }
  $('transcript').replaceChildren(fragment);
  state.active = -1;
  syncPlayer();
}

async function select(id) {
  const request = ++state.request;
  audio.pause();
  audio.removeAttribute('src');
  audio.load();
  state.selected = id;
  state.detail = null;
  $('recording-detail').hidden = true;
  $('welcome').hidden = false;
  $('player').hidden = true;
  message();
  renderList();
  try {
    const record = await get(`/api/recordings/${id}`);
    if (request !== state.request) return;
    state.detail = record;
    $('welcome').hidden = true;
    $('recording-detail').hidden = false;
    $('player').hidden = false;
    $('recording-date').textContent = day(record.started_at).toLocaleUpperCase('ru-RU');
    $('recording-title').textContent = `Запись в ${hour(record.started_at)}`;
    $('recording-meta').replaceChildren(node('span', 'meta-pill', record.source), node('span', '', formatTime(record.duration)), node('span', '', statuses[record.status]));
    $('player-title').textContent = `${record.source} · ${hour(record.started_at)}`;
    $('duration').textContent = formatTime(record.duration);
    $('seek').max = record.duration;
    $('seek').value = 0;
    audio.src = `/api/recordings/${id}/audio`;
    audio.playbackRate = Number($('speed').value);
    if (record.decode_warning) message('В записи возможны пропуски звука.');
    renderTranscript(record);
  } catch {
    if (request !== state.request) return;
    $('connection').textContent = 'Не удалось открыть запись. Обновите список и попробуйте ещё раз.';
    $('connection').hidden = false;
  }
}

function syncPlayer() {
  $('play').textContent = audio.paused ? '▶' : 'Ⅱ';
  $('play').setAttribute('aria-label', audio.paused ? 'Воспроизвести' : 'Приостановить');
  $('elapsed').textContent = formatTime(audio.currentTime);
  if (document.activeElement !== $('seek')) $('seek').value = audio.currentTime;
  const active = segmentAt(state.detail?.segments || [], audio.currentTime);
  if (active !== state.active) {
    const buttons = $('transcript').querySelectorAll('.segment');
    buttons.forEach((button, i) => { button.classList.toggle('current', i === active); if (i === active) button.setAttribute('aria-current', 'true'); else button.removeAttribute('aria-current'); });
    state.active = active;
  }
}

async function refresh() {
  if (state.loading || state.deleting || $('delete-dialog').open) return;
  state.loading = true;
  $('refresh').disabled = true;
  try {
    const {recordings} = await get('/api/recordings');
    const changed = JSON.stringify(recordings) !== JSON.stringify(state.records);
    state.records = recordings;
    $('connection').hidden = true;
    if (state.selected && !recordings.some(r => r.id === state.selected)) {
      audio.pause(); state.selected = null; state.detail = null; ++state.request;
      $('recording-detail').hidden = true; $('player').hidden = true; $('welcome').hidden = false;
    }
    if (changed) renderList();
    if (!state.selected && recordings.length) await select(recordings[0].id);
    else if (state.detail) {
      const id = state.selected;
      const record = await get(`/api/recordings/${id}`);
      if (state.selected === id && state.detail && (record.status !== state.detail.status || JSON.stringify(record.segments) !== JSON.stringify(state.detail.segments))) {
        state.detail = record;
        $('recording-meta').replaceChildren(node('span', 'meta-pill', record.source), node('span', '', formatTime(record.duration)), node('span', '', statuses[record.status]));
        renderTranscript(record);
      }
    }
    if (!recordings.length) renderList();
  } catch {
    $('connection').textContent = 'Нет связи с аудиотекой. Выполните omiloc в Terminal и обновите список.';
    $('connection').hidden = false;
    if (!state.records.length) $('recordings').replaceChildren(node('p', 'empty-list', 'Ожидаем подключения…'));
  } finally { state.loading = false; $('refresh').disabled = false; }
}

$('play').addEventListener('click', async () => { if (!state.detail) return; message(); if (!audio.paused) audio.pause(); else { try { await audio.play(); } catch { message('Аудио недоступно. Обновите запись и попробуйте ещё раз.'); } } });
$('back').addEventListener('click', () => { if (state.detail) seekTo(audio, audio.currentTime - 10, state.detail.duration); });
$('forward').addEventListener('click', () => { if (state.detail) seekTo(audio, audio.currentTime + 10, state.detail.duration); });
$('seek').addEventListener('input', () => { if (state.detail) { seekTo(audio, Number($('seek').value), state.detail.duration); syncPlayer(); } });
$('speed').addEventListener('change', () => { audio.playbackRate = Number($('speed').value); });
for (const event of ['timeupdate', 'play', 'pause', 'ended', 'loadedmetadata', 'seeked']) audio.addEventListener(event, syncPlayer);
audio.addEventListener('error', () => { if (state.detail && audio.getAttribute('src')) message('Не удалось загрузить аудио. Обновите запись и попробуйте ещё раз.'); });
$('refresh').addEventListener('click', refresh);
$('delete').addEventListener('click', () => {
  if (!state.detail) return;
  state.deleteId = state.selected;
  $('delete-error').hidden = true;
  $('delete-dialog').showModal();
});
$('delete-cancel').addEventListener('click', () => $('delete-dialog').close());
$('delete-dialog').addEventListener('cancel', event => { if (state.deleting) event.preventDefault(); });
$('delete-confirm').addEventListener('click', async () => {
  if (state.deleting || !state.deleteId) return;
  state.deleting = true;
  $('delete-confirm').disabled = true;
  $('delete-cancel').disabled = true;
  $('delete-confirm').textContent = 'Удаляем…';
  audio.pause();
  try {
    const response = await fetch(`/api/recordings/${state.deleteId}`, {method: 'DELETE', headers: {'X-Omiloc-Request': 'delete'}, signal: AbortSignal.timeout(70000)});
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'Не удалось удалить запись.');
    $('delete-dialog').close();
  } catch (error) {
    $('delete-error').textContent = error.name === 'TimeoutError' ? 'Ответ задерживается. Обновите список, чтобы проверить результат.' : error.message;
    $('delete-error').hidden = false;
  } finally {
    state.deleting = false;
    $('delete-confirm').disabled = false;
    $('delete-cancel').disabled = false;
    $('delete-confirm').textContent = 'Удалить';
    await refresh();
  }
});
$('search').addEventListener('input', renderList);
for (const [id, enabled] of [['filter-all', false], ['filter-ready', true]]) $(id).addEventListener('click', () => { state.filter = enabled; for (const name of ['filter-all', 'filter-ready']) { $(name).classList.toggle('selected', name === id); $(name).setAttribute('aria-pressed', String(name === id)); } renderList(); });
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
setInterval(() => { if (!document.hidden) refresh(); }, 5000);
refresh();

if (document.modelContext?.registerTool) {
  const lifetime = new AbortController();
  addEventListener('pagehide', () => lifetime.abort(), {once: true});
  const tools = [
    {name: 'list_recordings', description: 'List the local recordings available in this library.',
      inputSchema: {type: 'object', properties: {}, additionalProperties: false},
      annotations: {readOnlyHint: true, untrustedContentHint: true},
      execute: async () => (await get('/api/recordings')).recordings.map(({id, started_at, source, duration, status}) => ({id, started_at, source, duration, status}))},
    {name: 'open_recording', description: 'Open a recording and its transcript on the page, without playing or deleting it.',
      inputSchema: {type: 'object', properties: {id: {type: 'string'}}, required: ['id'], additionalProperties: false},
      annotations: {readOnlyHint: false, untrustedContentHint: true},
      execute: async input => {
        if (typeof input?.id !== 'string' || !/^[A-Za-z0-9_-]+$/.test(input.id) || $('delete-dialog').open) throw new Error('Recording cannot be opened.');
        await select(input.id);
        if (state.detail?.id !== input.id) throw new Error('Recording unavailable.');
        return {status: 'opened', segments: state.detail.segments.length};
      }},
  ];
  for (const tool of tools) {
    try { Promise.resolve(document.modelContext.registerTool(tool, {signal: lifetime.signal})).catch(() => {}); }
    catch { /* The visible controls work in browsers without this optional API. */ }
  }
}
