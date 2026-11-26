import {formatTime} from './player.mjs';

const states = {ready: 'Готов', configured: 'Провайдер выбран', busy: 'Ожидаем текст', streaming: 'Live-текст получен', disabled: 'Выключен',
  failed: 'Ошибка', unavailable: 'Недоступен', stopped: 'Остановлен', processing: 'Распознаёт запись'};

export function audioActivity(current, previous, now, lastProgress) {
  const capture = current.capture || {};
  if (current.backend !== 'ready') return {label: 'Нет связи с сервером', progress: now, tone: 'error'};
  if (capture.state === 'idle') return {label: 'Ожидаем запись', progress: now, tone: 'idle'};
  if (capture.state === 'decode_error') return {label: 'Есть ошибки декодирования', progress: now, tone: 'error'};
  if (capture.state === 'waiting_audio') return {label: 'Подключено · ждём звук', progress: now, tone: 'waiting'};
  if (capture.state !== 'received') return {label: 'Состояние звука неизвестно', progress: now, tone: 'error'};
  const changed = !previous || capture.frames_received !== previous.capture?.frames_received;
  const progress = changed ? now : lastProgress;
  return {label: now - progress >= 5000 ? 'Аудио не поступает более 5 с' : 'Аудио поступает',
    progress, tone: now - progress >= 5000 ? 'waiting' : 'active'};
}

export function liveSourceLabel(session) {
  const input = session.source === 'omi' ? 'Omi CV1' : session.source === 'phone' ? 'Встроенный микрофон' : 'Другой вход';
  const platform = {ios: 'iPhone', android: 'Android'}[session.origin?.phone_platform];
  const phone = session.origin?.phone_model || platform;
  return [phone, input].filter(Boolean).join(' · ');
}

function streamActivity(session, previous, now) {
  const frames = session.frames_received;
  const comparable = previous && Number.isFinite(frames) && frames >= previous.frames;
  const advanced = comparable && frames > previous.frames;
  const since = comparable && !advanced ? previous.since : now;
  const confirmed = advanced || (comparable && previous.confirmed);
  let tone = 'idle', label = 'Проверяем поток';
  if (session.decode_errors > (previous?.errors ?? 0)) {
    tone = 'error'; label = 'Ошибка декодирования';
  } else if (frames === 0 || (comparable && now - since >= 5000)) {
    tone = 'waiting'; label = frames === 0 ? 'Ждём первые кадры' : 'Кадры не поступают ≥ 5 с';
  } else if (confirmed) {
    tone = 'active'; label = 'Получаем звук';
  }
  return {frames, since, confirmed, errors: session.decode_errors, tone, label};
}

function speakerTurns(segments) {
  const turns = [];
  for (const segment of Array.isArray(segments) ? segments : []) {
    if (typeof segment?.text !== 'string' || !segment.text.trim()) continue;
    const draft = segment.is_draft === true;
    const speaker = !draft && /^SPEAKER_\d{1,4}$/.test(segment.speaker) ? Number(segment.speaker.slice(8)) : null;
    const previous = turns.at(-1);
    if (previous && previous.speaker === speaker && previous.draft === draft) previous.text.push(segment.text.trim());
    else turns.push({speaker, draft, start: segment.start, text: [segment.text.trim()]});
  }
  return turns;
}

function element(tag, cls, text) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
}

export function mountLiveMonitor(root, {refreshControls = () => {}, controls = null, onSources = () => {}, onStages = () => {}} = {}) {
  const title = element('div', 'monitor-heading');
  const heading = element('div');
  heading.append(element('p', 'eyebrow', 'РАСПОЗНАВАНИЕ НА СЕРВЕРЕ'), element('h2', '', 'Сейчас'));
  const badge = element('span', 'monitor-badge', 'Подключаемся…');
  title.append(heading, badge);
  const note = element('p', 'monitor-note', 'Начните запись на CV1 или с микрофона телефона. Текст появится здесь автоматически.');
  const cards = element('div', 'monitor-cards');
  const fields = {};
  for (const [id, label] of [['audio', 'Источник звука'], ['live', 'Live STT'], ['diarization', 'Диаризация · во время записи'], ['final', 'После остановки']]) {
    const card = element('div', 'monitor-card');
    const value = element('strong', '', '—');
    const detail = element('span', '', 'Проверяем состояние…');
    card.append(element('span', 'monitor-card-label', label), value, detail);
    fields[id] = {value, detail};
    cards.append(card);
  }
  const services = element('ul', 'live-services');
  const stages = [['stt', 'Транскрипция'], ['diarization', 'Разметка голосов'], ['summary', 'Модель итогов']].map(([id, name]) => {
    const item = element('li');
    services.append(item);
    return {id, name, item};
  });
  const transcriptHeading = element('div', 'transcript-heading');
  transcriptHeading.append(element('h3', '', 'Live-транскрипт'), element('span', '', 'Черновик уточняется во время речи'));
  const text = element('div', 'live-draft');
  const journal = element('details', 'monitor-journal');
  const summary = element('summary', '', 'События');
  const journalNote = element('p', 'monitor-note', 'Время наблюдения в браузере. Журнал начинается с открытия монитора; содержимое речи в него не попадает.');
  const events = element('ol', 'monitor-events');
  journal.append(summary, journalNote, events);
  const freshness = element('p', 'monitor-freshness');
  root.append(title, note, cards, services, ...(controls ? [controls] : []), transcriptHeading, text, journal, freshness);
  let previous = null, lastProgress = Date.now(), lastDraft = '', lastEvents = '', timer;
  let streams = new Map(), indicators = [];
  let paused = false, request = null, generation = 0;

  function render(data) {
    refreshControls();
    const activity = audioActivity(data, previous, Date.now(), lastProgress);
    lastProgress = activity.progress;
    badge.textContent = activity.label;
    badge.dataset.tone = activity.tone;
    const sessions = data.backend === 'ready' ? (data.sessions || []) : [];
    note.hidden = sessions.length > 0 || data.backend !== 'ready';
    const live = data.live_transcript || {}, final = data.final_stt || {};
    fields.audio.value.textContent = sessions.length ? [...new Set(sessions.map(liveSourceLabel))].join(' + ') : 'Нет активной записи';
    fields.audio.detail.textContent = sessions.length ? `${formatTime(data.capture.audio_seconds || 0)} получено · ${data.capture.frames_received || 0} кадров` : activity.label;
    fields.live.value.textContent = live.provider || 'Live STT';
    fields.live.detail.textContent = `${states[live.state] || 'Неизвестно'} · отправлено обновлений: ${live.updates || 0}`;
    const diarization = data.diarization || {};
    const diarizationStates = {disabled: 'Выключена', ready: 'Сервис готов', busy: 'Сервис занят',
      pending: 'Включена · ожидаем метки', labeled: 'Метки получены', degraded: 'Ошибка диаризации',
      failed: 'Поток завершился с ошибкой', unavailable: 'Сервис недоступен', unknown: 'Неизвестно'};
    fields.diarization.value.textContent = diarizationStates[diarization.state] || 'Неизвестно';
    fields.diarization.detail.textContent = diarization.state === 'labeled'
      ? `Размечено фрагментов в текущем тексте: ${diarization.labeled_segments || 0}`
      : diarization.state === 'degraded' ? 'Метки сняты. Состояние текста и аудио показано отдельно.'
      : ['ready', 'busy', 'pending'].includes(diarization.state) ? 'Результат текущей записи ещё не подтверждён.'
      : diarization.state === 'disabled' ? 'Метки спикеров в потоке не создаются.'
      : 'Нет подтверждения работы диаризации.';
    fields.final.value.textContent = final.provider || 'Финальный STT';
    fields.final.detail.textContent = `${states[final.state] || 'Недоступен'}${final.jobs?.pending ? ` · в очереди: ${final.jobs.pending}` : ''}${final.jobs?.failed ? ` · ошибок: ${final.jobs.failed}` : ''}`;
    const report = data.backend === 'ready' ? data.stages : null;
    onStages(report);
    for (const {id, name, item} of stages) {
      const stage = report?.stale === false ? report[id] : null;
      const state = stage?.status ?? 'unknown';
      const label = {ready: 'доступна', disabled: 'отключена', unavailable: 'недоступна',
        misconfigured: 'ошибка настройки'}[state];
      item.dataset.state = state;
      item.textContent = name + ' · ' + (label || (report?.stale ? 'проверка устарела' : 'нет данных'));
      item.title = stage?.name || '';
    }
    const draft = JSON.stringify(sessions.map(({preview_id, source, origin, revision, text, text_truncated, segments, withdrawn}) =>
      [preview_id, source, origin, revision, text, text_truncated, segments, withdrawn]));
    if (draft !== lastDraft || data.backend !== previous?.backend) {
      lastDraft = draft;
      indicators = [];
      const fragment = document.createDocumentFragment();
      if (!sessions.length) fragment.append(element('p', 'live-empty', data.backend === 'ready'
        ? 'Сейчас записи нет. После остановки окончательный текст появится в списке слева.'
        : 'Нет связи с сервером. Live-текст недоступен; повторяем проверку.'));
      for (const session of sessions) {
        const block = element('div', 'live-session');
        const header = element('header', 'live-session-header');
        const source = element('h4', 'stream-source', liveSourceLabel(session));
        source.dataset.input = session.source;
        const indicator = element('span', 'stream-activity');
        indicators.push(indicator);
        header.append(source, indicator);
        block.append(header);
        const turns = speakerTurns(session.segments);
        if (turns.length || session.withdrawn?.text) {
          const list = element('ol', 'live-turns');
          for (const turn of turns) {
            const row = element('li', turn.draft ? 'draft' : '');
            if (turn.speaker !== null) row.dataset.speaker = String(turn.speaker % 4);
            const speaker = turn.draft ? 'Черновик' : turn.speaker === null ? 'Говорящий не определён' : `Говорящий ${turn.speaker + 1}`;
            row.append(element('span', 'turn-label', [speaker, Number.isFinite(turn.start) ? formatTime(turn.start) : ''].filter(Boolean).join(' · ')),
              element('p', 'live-text', turn.text.join(' ')));
            list.append(row);
          }
          if (session.withdrawn?.text) {
            const row = element('li', 'withdrawn');
            row.append(element('span', 'turn-label', 'Предыдущий текст · не подтверждено'),
              element('p', 'live-text', session.withdrawn.text));
            list.append(row);
          }
          block.append(list);
        } else {
          block.append(element('p', session.text ? 'live-text' : 'live-empty', session.text || 'Ожидаем распознанную речь…'));
        }
        if (session.text_truncated) block.append(element('p', 'monitor-note', 'Показаны последние реплики длинного эфира. Полная расшифровка появится в архиве после обработки.'));
        fragment.append(block);
      }
      text.replaceChildren(fragment);
    }
    const currentStreams = new Map();
    sessions.forEach((session, index) => {
      const state = streamActivity(session, streams.get(session.preview_id), Date.now());
      if (session.preview_id) currentStreams.set(session.preview_id, state);
      const duration = Number.isFinite(session.audio_seconds) ? formatTime(session.audio_seconds) : '';
      indicators[index].textContent = [duration, state.label].filter(Boolean).join(' · ');
      indicators[index].dataset.tone = state.tone;
    });
    if (activity.tone === 'active' && sessions.length > 1) {
      const affected = indicators.filter(node => ['error', 'waiting'].includes(node.dataset.tone)).length;
      if (affected) {
        badge.textContent = `Требуют внимания: ${affected} из ${sessions.length}`;
        badge.dataset.tone = 'waiting';
      }
    }
    onSources(sessions.map(liveSourceLabel), {label: badge.textContent, tone: badge.dataset.tone});
    streams = currentStreams;
    const serialized = JSON.stringify(data.events || []);
    if (serialized !== lastEvents) {
      lastEvents = serialized;
      events.replaceChildren(...(data.events || []).map(event => {
        const row = element('li');
        const stamp = new Date(event.observed_at).toLocaleTimeString('ru-RU');
        row.append(element('time', '', stamp), element('span', '', event.message));
        return row;
      }));
      summary.textContent = `События · ${(data.events || []).length}`;
    }
    freshness.textContent = data.observed_at ? `Проверено в ${new Date(data.observed_at).toLocaleTimeString('ru-RU')} · обновление каждую секунду` : 'Аудиотека не отвечает. Повторяем проверку…';
    previous = data;
  }

  async function poll() {
    if (paused || request) return;
    clearTimeout(timer);
    if (!document.hidden) {
      const controller = new AbortController(), started = generation;
      request = controller;
      try {
        const response = await fetch('/api/runtime', {cache: 'no-store',
          signal: AbortSignal.any([controller.signal, AbortSignal.timeout(6000)])});
        if (!response.ok) throw new Error('Runtime unavailable');
        const data = await response.json();
        if (!paused && started === generation) render(data);
      } catch {
        if (!paused && started === generation) {
          render({backend: 'unavailable', capture: {state: 'unknown'}, sessions: [],
            live_transcript: {state: 'unavailable'}, final_stt: {state: 'unavailable'}, events: previous?.events || []});
        }
      } finally {
        request = null;
      }
    }
    if (!paused) timer = setTimeout(poll, 1000);
  }
  addEventListener('pagehide', () => {
    paused = true;
    streams.clear();
    generation++;
    clearTimeout(timer);
    request?.abort();
  });
  addEventListener('pageshow', () => {
    if (!paused) return;
    paused = false;
    poll();
  });
  poll();
}
