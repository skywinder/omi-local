import {formatTime, segmentAt, seekTo, playFrom} from '/player.mjs';
import {mountLiveMonitor} from '/live.mjs';
import {mountSettings} from '/settings.mjs';
import {processingFailure, renderProcessing} from '/recording-processing.mjs';

const $ = id => document.getElementById(id);
const audio = $('audio');
const providerSettings = mountSettings($('provider-settings'));
const state = {records: [], selected: null, detail: null, view: 'live', filter: false, request: 0, active: -1, loading: false, deleting: false, deleteId: null};
const statuses = {ready: 'Транскрипт готов', pending: 'В очереди', processing: 'Обрабатывается', no_speech: 'Речь не обнаружена', failed: 'Ошибка обработки', unavailable: 'Без транскрипта'};
const day = value => new Date(value).toLocaleDateString('ru-RU', {day: 'numeric', month: 'long', year: 'numeric'});
const hour = value => new Date(value).toLocaleTimeString('ru-RU', {hour: '2-digit', minute: '2-digit'});
function node(tag, cls, text) { const el = document.createElement(tag); if (cls) el.className = cls; if (text !== undefined) el.textContent = text; return el; }
async function get(path) { const response = await fetch(path, {cache: 'no-store', signal: AbortSignal.timeout(10000)}); if (!response.ok) throw new Error('Unavailable'); return response.json(); }
function message(text = '') { $('player-message').textContent = text; $('player-message').hidden = !text; }

function showView(view = state.view) {
  state.view = view;
  const live = view === 'live';
  const recording = view === 'recording';
  $('live-monitor').hidden = !live;
  $('provider-settings').hidden = view !== 'settings';
  $('welcome').hidden = !recording || !!state.detail;
  $('recording-detail').hidden = !recording || !state.detail;
  $('player').hidden = !recording || !state.detail;
  for (const mode of ['live', 'recording', 'settings']) {
    $(`view-${mode}`).classList.toggle('selected', mode === view);
    $(`view-${mode}`).setAttribute('aria-pressed', String(mode === view));
  }
  if (!recording) audio.pause();
  if (view === 'settings') providerSettings.show();
}

function renderList() {
  const query = $('search').value.trim().toLocaleLowerCase('ru-RU');
  const items = state.records.filter(r => (!state.filter || r.status === 'ready') && `${r.summary?.title || ''} ${r.preview} ${day(r.started_at)} ${hour(r.started_at)} ${[r.phone, r.source].filter(Boolean).join(' · ')}`.toLocaleLowerCase('ru-RU').includes(query));
  $('count').textContent = state.records.length;
  const fragment = document.createDocumentFragment();
  let previous = '';
  for (const r of items) {
    const date = day(r.started_at);
    if (date !== previous) { fragment.append(node('p', 'group-label', date)); previous = date; }
    const button = node('button', `recording${state.selected === r.id ? ' active' : ''}`);
    button.setAttribute('aria-pressed', String(state.selected === r.id));
    const top = node('span', 'recording-top', r.summary?.title || `Запись в ${hour(r.started_at)}`);
    top.append(node('span', 'recording-length', formatTime(r.duration)));
    button.append(top, node('p', 'recording-preview', r.preview || statuses[r.status]));
    const bottom = node('span', 'recording-bottom');
    bottom.append(node('span', 'source', [r.phone, r.source].filter(Boolean).join(' · ')), node('span', '', processingFailure(r) || statuses[r.status]));
    button.append(bottom);
    button.addEventListener('click', () => select(r.id));
    fragment.append(button);
  }
  if (!items.length) fragment.append(node('p', 'empty-list', state.records.length ? 'Ничего не найдено. Попробуйте другую дату или сбросьте фильтр.' : 'Записей пока нет. Завершите запись на CV1 — она появится здесь автоматически.'));
  $('recordings').replaceChildren(fragment);
}

function renderTranscript(record) {
  renderRecap(record);
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
    const copy = {pending: 'Запись ожидает распознавания. Аудио уже можно слушать.', processing: 'Распознаём речь. Текст появится автоматически.', no_speech: 'Речь не обнаружена. Аудиозапись сохранена и доступна для прослушивания.', failed: 'Обработка не завершилась. Аудиозапись сохранена и доступна для прослушивания.', unavailable: 'Для этой записи пока нет транскрипта. Аудио можно слушать уже сейчас.'};
    fragment.append(node('p', 'empty-transcript', copy[record.status] || copy.unavailable));
  }
  $('transcript').replaceChildren(fragment);
  state.active = -1;
  syncPlayer();
}

let canonicalRecap;
function renderRecap(record) {
  $('recording-title').textContent = record.summary?.title || `Запись в ${hour(record.started_at)}`;
  $('summary-edit').hidden = !record.summary_editable;
  const summary = canonicalRecap?.id === record.id ? {...record.summary, overview: canonicalRecap.overview} : record.summary;
  renderProcessing($('recording-processing'), $('recording-summary'), {...record, summary});
}

function syncRecap(id, options) {
  if (state.detail?.id !== id || typeof options.overview !== 'string') return;
  canonicalRecap = {id, overview: options.overview};
  renderRecap(state.detail);
}

async function select(id, open = true) {
  const request = ++state.request;
  audio.pause();
  audio.removeAttribute('src');
  audio.load();
  state.selected = id;
  state.detail = null;
  showView(open ? 'recording' : state.view);
  message();
  renderList();
  try {
    const record = await get(`/api/recordings/${id}`);
    if (request !== state.request) return;
    state.detail = record;
    showView();
    $('recording-date').textContent = day(record.started_at).toLocaleUpperCase('ru-RU');
    $('recording-title').textContent = `Запись в ${hour(record.started_at)}`;
    $('recording-meta').replaceChildren(node('span', 'meta-pill', [record.phone, record.source].filter(Boolean).join(' · ')), node('span', '', formatTime(record.duration)), node('span', '', statuses[record.status]));
    $('player-title').textContent = `${record.source} · ${hour(record.started_at)}`;
    $('duration').textContent = formatTime(record.duration);
    $('seek').max = record.duration;
    $('seek').value = 0;
    audio.src = `/api/recordings/${id}/audio`;
    audio.playbackRate = Number($('speed').value);
    if (record.decode_warning) message('В записи возможны пропуски звука.');
    renderTranscript(record);
    if (record.summary_editable) {
      get(`/api/recordings/${id}/summary`).then(options => syncRecap(id, options)).catch(() => {});
    }
  } catch {
    if (request !== state.request) return;
    $('connection').textContent = 'Не удалось открыть запись. Обновите список и попробуйте ещё раз.';
    $('connection').hidden = false;
  }
}

let summaryDialog;
function drawSummaryOptions(id, options, {preserve = false} = {}) {
  if (!$('summary-dialog').open || summaryDialog?.id !== id) return;
  summaryDialog.options = options;
  syncRecap(id, options);
  const job = options.job;
  const state = job?.state;
  if (state === 'failed') summaryDialog.signature = null;
  const phases = {waiting: 'Итоги в очереди.', reading: 'Проверяется сохранённая расшифровка.',
    sections: 'Обрабатываются части расшифровки.', combining: 'Части объединяются в общий итог.',
    saving: 'Итог сохраняется в архиве.'};
  const failures = {recording_changed: 'Запись изменилась. Обновите данные и повторите.',
    connection: 'Модель не ответила. Проверьте провайдера и повторите.',
    timeout: 'Модель не успела ответить. Проверьте провайдера и повторите.',
    http_429: 'Модель занята. Повторите чуть позже.',
    credential_missing: 'Ключ модели недоступен. Проверьте настройки провайдера.'};
  const progress = job?.progress;
  const count = progress?.phase === 'sections' && Number.isInteger(progress.completed) && Number.isInteger(progress.total)
    ? ` ${progress.completed}/${progress.total}.` : '';
  $('summary-status').textContent = state === 'queued' ? `${phases[progress?.phase] || 'Сервер готовит итоги.'}${count} Можно закрыть окно.`
    : state === 'ready' ? 'Итоги готовы.'
    : state === 'failed' ? failures[job.error] || 'Не удалось обновить итоги. Проверьте запись и настройки модели.' : '';
  if (!preserve) {
    $('summary-provider').replaceChildren(...options.providers.map(row => new Option(`${row.name} · ${row.model} · ${row.host}`, row.binding)));
    $('summary-template').replaceChildren(...options.templates.map(row => new Option(row.name, row.id)));
    if (options.default_provider_binding) $('summary-provider').value = options.default_provider_binding;
    $('summary-template').value = options.default_template_id;
    chooseSummaryTemplate();
  }
  $('summary-submit').disabled = state === 'queued' || !options.providers.length;
  if (state === 'queued') {
    const run = summaryDialog;
    setTimeout(() => {
      if (summaryDialog !== run || !$('summary-dialog').open) return;
      get(`/api/recordings/${id}/summary`).then(next => drawSummaryOptions(id, next, {preserve: true})).catch(summaryLoadFailed);
    }, 8000);
  }
}
function chooseSummaryTemplate() {
  const template = summaryDialog?.options?.templates.find(row => row.id === $('summary-template').value);
  $('summary-prompt').value = template?.prompt || '';
}
function summaryLoadFailed() {
  $('summary-status').textContent = 'Связь с сервером прервалась. Откройте итоги снова, чтобы проверить статус.';
}
$('summary-edit').addEventListener('click', () => {
  const id = state.detail?.id;
  if (!id) return;
  summaryDialog = {id};
  $('summary-status').textContent = 'Загрузка…';
  $('summary-submit').disabled = true;
  $('summary-dialog').showModal();
  get(`/api/recordings/${id}/summary`).then(options => drawSummaryOptions(id, options)).catch(summaryLoadFailed);
});
$('summary-close').addEventListener('click', () => $('summary-dialog').close());
$('summary-template').addEventListener('change', chooseSummaryTemplate);
$('summary-form').addEventListener('submit', async event => {
  event.preventDefault();
  const run = summaryDialog;
  const options = run?.options;
  const template = options?.templates.find(row => row.id === $('summary-template').value);
  if (!options || !template) return;
  const path = `/api/recordings/${run.id}/summary`;
  const parameters = {source_revision: options.source_revision, provider_binding: $('summary-provider').value,
    template_id: template.id, template_digest: template.digest, prompt: $('summary-prompt').value.trim()};
  const encoded = JSON.stringify(parameters);
  if (run.signature !== encoded) { run.signature = encoded; run.requestId = crypto.randomUUID(); }
  $('summary-submit').disabled = true;
  try {
    const response = await fetch(path, {method: 'POST', headers: {'Content-Type': 'application/json', 'X-Omiloc-Request': 'summary'},
      signal: AbortSignal.timeout(12000), body: JSON.stringify({...parameters, request_id: run.requestId})});
    if (!response.ok) throw new Error('Unavailable');
    if (summaryDialog === run) drawSummaryOptions(run.id, {...options, job: await response.json()}, {preserve: true});
  } catch {
    if (summaryDialog === run) { summaryLoadFailed(); $('summary-submit').disabled = false; }
  }
});

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
      showView();
    }
    if (changed) renderList();
    if (!state.selected && recordings.length) await select(recordings[0].id, false);
    else if (state.detail) {
      const id = state.selected;
      const record = await get(`/api/recordings/${id}`);
      if (state.selected === id && state.detail && (record.status !== state.detail.status || JSON.stringify([record.segments, record.summary, record.processing]) !== JSON.stringify([state.detail.segments, state.detail.summary, state.detail.processing]))) {
        state.detail = record;
        $('recording-meta').replaceChildren(node('span', 'meta-pill', [record.phone, record.source].filter(Boolean).join(' · ')), node('span', '', formatTime(record.duration)), node('span', '', statuses[record.status]));
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
for (const button of document.querySelectorAll('[data-folder]')) button.addEventListener('click', async () => {
  const buttons = document.querySelectorAll('[data-folder]');
  buttons.forEach(item => { item.disabled = true; });
  $('folder-message').hidden = true;
  try {
    const response = await fetch(`/api/folders/${button.dataset.folder}/open`, {
      method: 'POST', headers: {'X-Omiloc-Request': 'open-folder'}, signal: AbortSignal.timeout(10000),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'Не удалось открыть папку.');
    $('folder-message').textContent = 'Папка открыта в Finder.';
  } catch (error) {
    $('folder-message').textContent = error instanceof TypeError || error instanceof SyntaxError
      ? 'Нет ответа от аудиотеки. Обновите страницу и попробуйте ещё раз.'
      : error.name === 'TimeoutError' ? 'Ответ задерживается. Проверьте Finder.' : error.message;
  } finally {
    $('folder-message').hidden = false;
    buttons.forEach(item => { item.disabled = false; });
  }
});
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
for (const view of ['live', 'recording', 'settings']) $(`view-${view}`).addEventListener('click', () => showView(view));
mountLiveMonitor($('live-monitor'));
showView();
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
