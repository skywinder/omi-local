import {mountLiveTuning} from './live-tuning.mjs';
import {formatTime, segmentAt, seekTo, playFrom, speakerBadge, findTurns} from '/player.mjs';
import {mountLiveMonitor} from '/live.mjs';
import {mountSettings, mountSummaryTemplates} from '/settings.mjs';
import {processingFailure, renderProcessing} from '/recording-processing.mjs';
import {categories, categoryLabel} from '/recording-categories.mjs';

const $ = id => document.getElementById(id);
const audio = $('audio');
let settingsSection = location.hash === '#summary-templates' ? 'templates' : 'providers';
const providerSettings = mountSettings($('provider-settings'), {
  openTemplates: () => showSettingsSection('templates', {focus: true}),
});
const summaryTemplates = mountSummaryTemplates($('summary-templates'), {
  onSave: (from, to) => providerSettings.catalogSaved(from, to),
});

function showSettingsSection(section, {focus = false} = {}) {
  settingsSection = section;
  const templates = section === 'templates';
  $('provider-settings').hidden = templates;
  $('summary-templates').hidden = !templates;
  for (const tab of ['providers', 'templates']) {
    $(`settings-${tab}-tab`).setAttribute('aria-pressed', String(section === tab));
  }
  if (focus) $('settings-templates-tab').focus();
  if (templates) summaryTemplates.show();
  else providerSettings.show();
}
const state = {records: [], selected: null, detail: null, view: settingsSection === 'templates' ? 'settings' : 'live', archived: false, favorites: false, ready: false, category: '', noteWrite: false,
  noteVersion: 0, request: 0, active: -1, loading: false, deleting: false, deleteId: null};
const defaultVisibility = {minimumSeconds: 0, hideWithoutAudio: false, hideNoSpeech: false};
const visibilityKey = 'omiloc.library.visibility';
function readVisibility() {
  try {
    const saved = JSON.parse(localStorage.getItem(visibilityKey));
    return {
      minimumSeconds: Number.isInteger(saved?.minimumSeconds) && saved.minimumSeconds >= 0 ? saved.minimumSeconds : 0,
      hideWithoutAudio: saved?.hideWithoutAudio === true,
      hideNoSpeech: saved?.hideNoSpeech === true,
    };
  } catch { return {...defaultVisibility}; }
}
let visibility = readVisibility();

const statuses = {ready: 'Transcript ready', pending: 'Queued', processing: 'Processing',
  no_speech: 'No speech detected', failed: 'Processing failed', unavailable: 'No transcript'};
const dayFormat = new Intl.DateTimeFormat('en-GB', {day: 'numeric', month: 'long', year: 'numeric'});
const cardDate = new Intl.DateTimeFormat('en-GB', {day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit'});
const detailDate = new Intl.DateTimeFormat('en-GB', {weekday: 'short', day: 'numeric', month: 'long', year: 'numeric',
  hour: '2-digit', minute: '2-digit', timeZoneName: 'shortOffset'});
const timeFormat = new Intl.DateTimeFormat('en-GB', {hour: '2-digit', minute: '2-digit'});
const isoDay = new Intl.DateTimeFormat('sv-SE', {year: 'numeric', month: '2-digit', day: '2-digit'});
const russianDay = new Intl.DateTimeFormat('ru-RU', {day: 'numeric', month: 'long', year: 'numeric'});
const day = value => dayFormat.format(new Date(value));
const hour = value => timeFormat.format(new Date(value));
function node(tag, cls, text) { const el = document.createElement(tag); if (cls) el.className = cls; if (text !== undefined) el.textContent = text; return el; }
async function get(path) { const response = await fetch(path, {cache: 'no-store', signal: AbortSignal.timeout(10000)}); if (!response.ok) throw new Error('Unavailable'); return response.json(); }
function message(text = '') { $('player-message').textContent = text; $('player-message').hidden = !text; }

function recordingTime(element, value, formatter) {
  element.dateTime = value;
  element.textContent = formatter.format(new Date(value));
  return element;
}

function sourceLabel(record) {
  const source = record.source === 'Микрофон телефона' ? 'Phone microphone' : record.source;
  return [record.phone, source].filter(Boolean).join(' · ');
}

function renderRecordingInfo(record) {
  recordingTime($('recording-date'), record.started_at, detailDate);
  const facts = [sourceLabel(record), formatTime(record.duration), statuses[record.status]];
  $('recording-meta').replaceChildren(...facts.filter(Boolean).map(value => node('span', 'meta-pill', value)));
}

function showView(view = state.view) {
  state.view = view;
  const live = view === 'live';
  const recording = view === 'recording';
  $('live-monitor').hidden = !live;
  $('active-recordings').setAttribute('aria-pressed', String(live));
  $('settings-workspace').hidden = view !== 'settings';
  $('welcome').hidden = !recording || !!state.detail;
  $('recording-detail').hidden = !recording || !state.detail;
  $('player').hidden = !recording || !state.detail;
  for (const mode of ['live', 'recording', 'settings']) {
    $(`view-${mode}`).classList.toggle('selected', mode === view);
    $(`view-${mode}`).setAttribute('aria-pressed', String(mode === view));
  }
  if (!recording) audio.pause();
  if (view === 'settings') showSettingsSection(settingsSection);
}

function renderList() {
  const query = $('search').value.trim().toLocaleLowerCase('ru-RU');
  const items = state.records.filter(r => Boolean(r.note?.archived) === state.archived
    && (!state.favorites || r.note?.starred) && (!state.ready || r.status === 'ready')
    && (!Number.isFinite(r.duration) || r.duration < 0 || r.duration >= visibility.minimumSeconds)
    && (!visibility.hideWithoutAudio || (r.has_audio ?? r.status !== 'waiting_for_parts'))
    && (!visibility.hideNoSpeech || r.status !== 'no_speech')
    && (!state.category || r.note?.category === state.category)
    && [r.summary?.title, r.preview, day(r.started_at), hour(r.started_at), isoDay.format(new Date(r.started_at)),
      russianDay.format(new Date(r.started_at)), sourceLabel(r), r.source, categoryLabel(r.note?.category)]
      .join(' ').toLocaleLowerCase('ru-RU').includes(query));
  $('count').textContent = items.length;
  const fragment = document.createDocumentFragment();
  let previous = '';
  for (const r of items) {
    const date = day(r.started_at);
    if (date !== previous) { fragment.append(node('p', 'group-label', date)); previous = date; }
    const button = node('button', `recording${state.selected === r.id ? ' active' : ''}`);
    button.setAttribute('aria-pressed', String(state.selected === r.id));
    button.dataset.recordingId = r.id;
    const top = node('span', 'recording-top');
    top.append(recordingTime(node('time', 'recording-time'), r.started_at, cardDate),
      node('span', 'recording-length', formatTime(r.duration)));
    const title = node('span', 'recording-name');
    if (r.note?.emoji) title.append(node('span', 'recording-emoji', r.note.emoji));
    title.append(node('span', '', r.summary?.title || 'Untitled recording'));
    const bottom = node('span', 'recording-bottom');
    for (const label of [sourceLabel(r), categoryLabel(r.note?.category)].filter(Boolean)) {
      bottom.append(node('span', 'source', label));
    }
    const status = processingFailure(r) || statuses[r.status];
    if (status && r.status !== 'ready') bottom.append(node('span', 'recording-status', status));
    if (r.note?.starred) {
      const star = node('span', 'favorite-mark', '★');
      star.setAttribute('aria-label', 'Favorited');
      title.append(star);
    }
    button.append(top, title);
    if (r.preview) button.append(node('span', 'recording-preview', r.preview));
    if (bottom.childElementCount) button.append(bottom);
    button.addEventListener('click', async () => {
      await select(r.id);
      if (state.detail?.id === r.id && matchMedia('(max-width: 650px)').matches) {
        $('recording-detail').scrollIntoView({block: 'start'});
        $('recording-title').focus({preventScroll: true});
      }
    });
    fragment.append(button);
  }
  if (!items.length) fragment.append(node('p', 'empty-list', state.records.length ? 'No matching recordings.' : 'No recordings yet.'));
  $('recordings').replaceChildren(fragment);
}

function noteFeedback(text = '') {
  $('note-feedback').textContent = text;
  $('note-feedback').hidden = !text;
}

function renderNoteActions() {
  const note = state.detail?.note;
  $('note-actions').hidden = !note;
  $('note-star').textContent = note?.starred ? 'Favorited' : 'Add to favorites';
  $('note-star').setAttribute('aria-pressed', String(note?.starred === true));
  $('note-archive').textContent = note?.archived ? 'Restore from archive' : 'Archive';
  $('note-category').value = categories.has(note?.category) ? note.category : 'other';
  for (const id of ['note-star', 'note-archive', 'note-category']) {
    $(id).disabled = state.noteWrite || state.detail?.notes_unavailable === true;
  }
}

async function changeNote(field, value) {
  const note = state.detail?.note;
  if (!note || state.noteWrite || state.detail.notes_unavailable) return;
  const id = state.selected;
  const request = state.request;
  const change = field === 'category' ? {category: {expected: note.category, value}} : {[field]: !note[field]};
  state.noteWrite = true;
  ++state.noteVersion;
  noteFeedback('Saving…');
  renderNoteActions();
  try {
    const response = await fetch(`/api/recordings/${id}/notes`, {method: 'PATCH',
      headers: {'Content-Type': 'application/json', 'X-Omiloc-Request': 'notes'},
      body: JSON.stringify(change), signal: AbortSignal.timeout(10000)});
    const result = await response.json();
    if (!response.ok || !result.note) throw new Error(result.error || 'Change not confirmed.');
    state.records = state.records.map(row => row.id === id ? {...row, note: result.note} : row);
    if (request === state.request && state.detail) {
      state.detail.note = result.note;
      noteFeedback();
    }
    renderList();
  } catch (error) {
    if (request === state.request) noteFeedback(error.message || 'Change not confirmed.');
  } finally {
    state.noteWrite = false;
    renderNoteActions();
    await refresh();
  }
}

const turnQuery = $('turn-query');
let turnMatches = [], turnPosition = 0, turnButtons = [], highlightedPhrase;

function showTurnMatch(scroll) {
  if (highlightedPhrase) {
    const line = highlightedPhrase.parentElement;
    highlightedPhrase.replaceWith(highlightedPhrase.textContent);
    line.normalize();
    highlightedPhrase = null;
  }
  const match = turnMatches[turnPosition];
  $('turn-count').textContent = !turnQuery.value.trim() ? '' : match
    ? `Реплика ${turnPosition + 1} из ${turnMatches.length}` : 'Совпадений нет';
  for (const id of ['turn-prev', 'turn-next']) $(id).disabled = turnMatches.length < 2;
  if (!match) return;
  const button = turnButtons[match.index];
  const line = button.querySelector('.segment-text');
  const phrase = line.textContent;
  highlightedPhrase = node('mark', '', phrase.slice(match.start, match.end));
  line.replaceChildren(phrase.slice(0, match.start), highlightedPhrase, phrase.slice(match.end));
  if (scroll) button.scrollIntoView({block: 'center'});
}

function updateTurnSearch(segments, scroll, keepIndex = -1) {
  turnMatches = findTurns(segments, turnQuery.value);
  turnPosition = Math.max(0, turnMatches.findIndex(match => match.index >= keepIndex));
  showTurnMatch(scroll);
}

function stepTurn(direction) {
  if (!turnMatches.length) return;
  turnPosition = (turnPosition + direction + turnMatches.length) % turnMatches.length;
  showTurnMatch(true);
}

turnQuery.addEventListener('input', () => updateTurnSearch(state.detail?.segments || [], true));
turnQuery.addEventListener('keydown', event => {
  if (event.key === 'Enter' && !event.isComposing) {
    event.preventDefault();
    stepTurn(event.shiftKey ? -1 : 1);
  }
});
$('turn-prev').addEventListener('click', () => stepTurn(-1));
$('turn-next').addEventListener('click', () => stepTurn(1));

function renderTranscript(record) {
  renderRecap(record);
  const fragment = document.createDocumentFragment();
  const notice = record.transcript_source === 'original' ? 'Showing the original transcript while updates from Next are being verified.'
    : record.speaker_names_unavailable ? 'Speaker names are temporarily unavailable.' : '';
  if (notice) fragment.append(node('p', 'monitor-note', notice));
  record.segments.forEach(segment => {
    const button = node('button', 'segment');
    const speaker = speakerBadge(segment);
    button.setAttribute('aria-label', [speaker.label, `Play from ${formatTime(segment.start)}: ${segment.text}`].filter(Boolean).join('. '));
    button.append(node('span', 'segment-time', formatTime(segment.start)));
    const content = node('span', '');
    if (speaker.label) {
      const badge = node('span', 'segment-speaker', speaker.label);
      badge.dataset.speaker = speaker.tone;
      content.append(badge);
    }
    content.append(node('span', 'segment-text', segment.text));
    button.append(content);
    button.addEventListener('click', async () => {
      message();
      try { await playFrom(audio, segment.start, record.duration); syncPlayer(); }
      catch { message('Could not play audio. Press Play to retry.'); }
    });
    fragment.append(button);
  });
  if (!record.segments.length) {
    const copy = {pending: 'Waiting for transcription. Audio is available.', processing: 'Transcribing. Text will appear here.', no_speech: 'No speech detected. Audio is available.', failed: 'Processing failed. Audio is available.', unavailable: 'No transcript yet. Audio is available.'};
    fragment.append(node('p', 'empty-transcript', record.transcript_source === 'unavailable' ? 'Could not load the current transcript. Refresh to retry. Audio is available.' : copy[record.status] || copy.unavailable));
  }
  $('transcript').replaceChildren(fragment);
  highlightedPhrase = null;
  turnButtons = $('transcript').querySelectorAll('.segment');
  $('transcript-find').hidden = !turnButtons.length;
  updateTurnSearch(record.segments, false, turnMatches[turnPosition]?.index);
  state.active = -1;
  syncPlayer();
}

let canonicalRecap;
function renderRecap(record) {
  $('recording-title').textContent = record.summary?.title || 'Untitled recording';
  $('summary-edit').hidden = !record.summary_editable;
  const summary = !record.summary_current && canonicalRecap?.id === record.id ? {...record.summary, overview: canonicalRecap.overview} : record.summary;
  renderProcessing($('recording-processing'), $('recording-summary'), {...record, summary});
}

function syncRecap(id, options) {
  if (state.detail?.id !== id || typeof options.overview !== 'string') return;
  if (state.detail.summary_current) {
    if (state.detail.summary?.overview !== options.overview) refresh();
    return;
  }
  canonicalRecap = {id, overview: options.overview};
  renderRecap(state.detail);
}

async function select(id, open = true) {
  const request = ++state.request;
  turnQuery.value = '';
  turnMatches = [];
  audio.pause();
  audio.removeAttribute('src');
  audio.load();
  state.selected = id;
  canonicalRecap = null;
  state.detail = null;
  noteFeedback();
  showView(open ? 'recording' : state.view);
  message();
  renderList();
  try {
    const record = await get(`/api/recordings/${id}`);
    if (request !== state.request) return;
    state.detail = record;
    renderNoteActions();
    if (record.notes_unavailable) noteFeedback('Favorites and categories are temporarily unavailable.');
    showView();
    renderRecordingInfo(record);
    $('recording-title').textContent = 'Untitled recording';
    $('player-title').textContent = [sourceLabel(record), hour(record.started_at)].filter(Boolean).join(' · ');
    $('duration').textContent = formatTime(record.duration);
    $('seek').max = record.duration;
    $('seek').value = 0;
    audio.src = `/api/recordings/${id}/audio`;
    audio.playbackRate = Number($('speed').value);
    if (record.decode_warning) message('The recording may have audio gaps.');
    renderTranscript(record);
    if (record.summary_editable && !record.summary_current) {
      get(`/api/recordings/${id}/summary`).then(options => {
        if (request === state.request) syncRecap(id, options);
      }).catch(() => {});
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
  $('play').setAttribute('aria-label', audio.paused ? 'Play' : 'Pause');
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
  if (state.loading || state.deleting || state.noteWrite || $('delete-dialog').open) return;
  const noteVersion = state.noteVersion;
  state.loading = true;
  $('refresh').disabled = true;
  try {
    const {recordings, notes_unavailable: notesUnavailable} = await get('/api/recordings');
    if (noteVersion !== state.noteVersion) return;
    if (notesUnavailable) {
      const known = new Map(state.records.map(row => [row.id, row]));
      for (const row of recordings) {
        const previous = known.get(row.id);
        if (!row.note && previous?.note) {
          row.note = previous.note;
          row.summary = previous.summary;
        }
      }
    }
    const changed = JSON.stringify(recordings) !== JSON.stringify(state.records);
    state.records = recordings;
    $('connection').hidden = true;
    if (state.selected && !recordings.some(r => r.id === state.selected)) {
      audio.pause(); state.selected = null; state.detail = null; ++state.request;
      showView();
    }
    if (changed) renderList();
    if (!state.selected && recordings.length && state.view === 'recording') await select(recordings[0].id);
    else if (state.detail && state.view === 'recording') {
      const id = state.selected;
      const request = state.request;
      const record = await get(`/api/recordings/${id}`);
      if (request !== state.request || noteVersion !== state.noteVersion || !state.detail) return;
      if (record.notes_unavailable && !record.note) {
        record.note = state.detail.note;
        if (state.detail.summary_current) {
          record.summary = state.detail.summary;
          record.summary_current = true;
          if (state.detail.processing?.summary) {
            record.processing = {...record.processing, summary: state.detail.processing.summary};
          }
        }
      }
      state.detail.note = record.note;
      state.detail.notes_unavailable = record.notes_unavailable;
      renderNoteActions();
      if (record.started_at !== state.detail.started_at || sourceLabel(record) !== sourceLabel(state.detail)
          || record.transcript_source !== state.detail.transcript_source || record.speaker_names_unavailable !== state.detail.speaker_names_unavailable || record.summary_current !== state.detail.summary_current || record.status !== state.detail.status || JSON.stringify([record.segments, record.summary, record.processing]) !== JSON.stringify([state.detail.segments, state.detail.summary, state.detail.processing])) {
        state.detail = record;
        renderRecordingInfo(record);
        renderTranscript(record);
      }
    }
    if (!recordings.length) renderList();
  } catch {
    $('connection').textContent = 'Cannot reach the audio library. Reconnecting…';
    $('connection').hidden = false;
    if (!state.records.length) $('recordings').replaceChildren(node('p', 'empty-list', 'Waiting for connection…'));
  } finally { state.loading = false; $('refresh').disabled = false; }
}

$('play').addEventListener('click', async () => { if (!state.detail) return; message(); if (!audio.paused) audio.pause(); else { try { await audio.play(); } catch { message('Audio unavailable. Refresh the recording and try again.'); } } });
$('back').addEventListener('click', () => { if (state.detail) seekTo(audio, audio.currentTime - 10, state.detail.duration); });
$('forward').addEventListener('click', () => { if (state.detail) seekTo(audio, audio.currentTime + 10, state.detail.duration); });
$('seek').addEventListener('input', () => { if (state.detail) { seekTo(audio, Number($('seek').value), state.detail.duration); syncPlayer(); } });
$('speed').addEventListener('change', () => { audio.playbackRate = Number($('speed').value); });
for (const event of ['timeupdate', 'play', 'pause', 'ended', 'loadedmetadata', 'seeked']) audio.addEventListener(event, syncPlayer);
audio.addEventListener('error', () => { if (state.detail && audio.getAttribute('src')) message('Could not load audio. Refresh the recording and try again.'); });
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
for (const section of ['providers', 'templates']) {
  $(`settings-${section}-tab`).addEventListener('click', () => showSettingsSection(section));
}
$('back-to-recordings').addEventListener('click', () => {
  const selected = [...$('recordings').querySelectorAll('.recording')]
    .find(card => card.dataset.recordingId === state.selected);
  $('library-heading').scrollIntoView({block: 'start'});
  (selected || $('search')).focus({preventScroll: true});
});
for (const [name, key] of [['archive', 'archived'], ['favorites', 'favorites'], ['ready', 'ready']]) {
  const control = $(`filter-${name}`);
  control.addEventListener('click', () => {
    state[key] = !state[key];
    control.classList.toggle('selected', state[key]);
    control.setAttribute('aria-pressed', String(state[key]));
    renderList();
  });
}
const visibilityDialog = $('visibility-dialog');
const visibilityButton = $('filter-visibility');
function fillVisibilityForm(values) {
  $('filter-minimum-duration').value = values.minimumSeconds;
  $('filter-no-audio').checked = values.hideWithoutAudio;
  $('filter-no-speech').checked = values.hideNoSpeech;
}
function syncVisibilityButton() {
  const count = Number(visibility.minimumSeconds > 0) + Number(visibility.hideWithoutAudio) + Number(visibility.hideNoSpeech);
  visibilityButton.classList.toggle('selected', count > 0);
  visibilityButton.textContent = count ? `Filters (${count})` : 'Filters';
}
syncVisibilityButton();
visibilityButton.addEventListener('click', () => {
  fillVisibilityForm(visibility);
  visibilityDialog.showModal();
});
$('filter-reset').addEventListener('click', () => fillVisibilityForm(defaultVisibility));
$('filter-cancel').addEventListener('click', () => visibilityDialog.close());
$('visibility-form').addEventListener('submit', event => {
  event.preventDefault();
  visibility = {
    minimumSeconds: $('filter-minimum-duration').valueAsNumber,
    hideWithoutAudio: $('filter-no-audio').checked,
    hideNoSpeech: $('filter-no-speech').checked,
  };
  try { localStorage.setItem(visibilityKey, JSON.stringify(visibility)); } catch { /* Keep filters for this visit. */ }
  syncVisibilityButton();
  visibilityDialog.close();
  renderList();
});
for (const key of categories.keys()) {
  for (const id of ['filter-category', 'note-category']) {
    const option = node('option', '', categoryLabel(key));
    option.value = key;
    $(id).append(option);
  }
}
$('filter-category').addEventListener('change', event => { state.category = event.target.value; renderList(); });
$('note-star').addEventListener('click', () => changeNote('starred'));
$('note-archive').addEventListener('click', () => changeNote('archived'));
$('note-category').addEventListener('change', event => changeNote('category', event.target.value));
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
setInterval(() => { if (!document.hidden) refresh(); }, 5000);
for (const view of ['live', 'recording', 'settings']) $(`view-${view}`).addEventListener('click', () => {
  showView(view);
  if (view === 'recording') refresh();
});
const activeRecordings = $('active-recordings');
activeRecordings.addEventListener('click', () => {
  showView('live');
  $('view-live').focus();
});
const controls = $('live-tuning');
mountLiveMonitor($('live-monitor'), {
  controls, refreshControls: mountLiveTuning(controls), onStages: providerSettings.updateAvailability,
  onSources(labels, activity) {
    activeRecordings.hidden = !labels.length;
    activeRecordings.dataset.tone = activity.tone;
    $('active-inputs').textContent = [...labels, activity.label].join(' · ');
  },
});
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
