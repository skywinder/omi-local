import {formatTime} from './player.mjs';

const states = {ready: 'Ready', configured: 'Provider selected', busy: 'Waiting for text', streaming: 'Live text received', disabled: 'Disabled',
  failed: 'Error', unavailable: 'Unavailable', stopped: 'Stopped', processing: 'Transcribing recording'};

export function audioActivity(current, previous, now, lastProgress) {
  const capture = current.capture || {};
  if (current.backend !== 'ready') return {label: 'Server disconnected', progress: now, tone: 'error'};
  if (capture.state === 'idle') return {label: 'Waiting for recording', progress: now, tone: 'idle'};
  if (capture.state === 'decode_error') return {label: 'Audio decoding errors', progress: now, tone: 'error'};
  if (capture.state === 'waiting_audio') return {label: 'Connected · waiting for audio', progress: now, tone: 'waiting'};
  if (capture.state !== 'received') return {label: 'Unknown audio status', progress: now, tone: 'error'};
  const changed = !previous || capture.frames_received !== previous.capture?.frames_received;
  const progress = changed ? now : lastProgress;
  return {label: now - progress >= 5000 ? 'No audio for at least 5 seconds' : 'Receiving audio',
    progress, tone: now - progress >= 5000 ? 'waiting' : 'active'};
}

export function liveSourceLabel(session) {
  const input = session.source === 'omi' ? 'Omi CV1' : session.source === 'phone' ? 'Built-in microphone' : 'Other input';
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
  let tone = 'idle', label = 'Checking stream';
  if (session.decode_errors > (previous?.errors ?? 0)) {
    tone = 'error'; label = 'Decoding error';
  } else if (frames === 0 || (comparable && now - since >= 5000)) {
    tone = 'waiting'; label = frames === 0 ? 'Waiting for the first frames' : 'No frames for at least 5 seconds';
  } else if (confirmed) {
    tone = 'active'; label = 'Receiving audio';
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
  heading.append(element('p', 'eyebrow', 'SERVER TRANSCRIPTION'), element('h2', '', 'Now'));
  const badge = element('span', 'monitor-badge', 'Connecting…');
  title.append(heading, badge);
  const note = element('p', 'monitor-note', 'Start recording with a CV1 or the phone microphone to see live text.');
  const cards = element('div', 'monitor-cards');
  const fields = {};
  for (const [id, label] of [['audio', 'Audio source'], ['live', 'Live STT'], ['diarization', 'Live speaker labels'], ['final', 'After recording stops']]) {
    const card = element('div', 'monitor-card');
    const value = element('strong', '', '—');
    const detail = element('span', '', 'Checking status…');
    card.append(element('span', 'monitor-card-label', label), value, detail);
    fields[id] = {value, detail};
    cards.append(card);
  }
  const services = element('ul', 'live-services');
  const stages = [['stt', 'Transcription'], ['diarization', 'Speaker labeling'], ['summary', 'Summary model']].map(([id, name]) => {
    const item = element('li');
    services.append(item);
    return {id, name, item};
  });
  const transcriptHeading = element('div', 'transcript-heading');
  transcriptHeading.append(element('h3', '', 'Live transcript'), element('span', '', 'Draft updates as you speak'));
  const text = element('div', 'live-draft');
  const journal = element('details', 'monitor-journal');
  const summary = element('summary', '', 'Events');
  const journalNote = element('p', 'monitor-note', 'Times are local to this browser. Events start when you open the monitor. Speech content is excluded.');
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
    fields.live.value.textContent = live.provider || 'Live STT';
    fields.live.detail.textContent = `${states[live.state] || 'Unknown'} · updates sent: ${live.updates || 0}`;
    const diarization = data.diarization || {};
    const diarizationStates = {disabled: 'Disabled', ready: 'Service ready', busy: 'Service busy',
      pending: 'Enabled · waiting for labels', labeled: 'Labels received', degraded: 'Speaker labeling error',
      failed: 'Stream failed', unavailable: 'Service unavailable', unknown: 'Unknown'};
    fields.diarization.value.textContent = diarizationStates[diarization.state] || 'Unknown';
    fields.diarization.detail.textContent = diarization.state === 'labeled'
      ? `Labeled segments in this transcript: ${diarization.labeled_segments || 0}`
      : diarization.state === 'degraded' ? 'Labels cleared. Check text and audio status separately.'
      : ['ready', 'busy', 'pending'].includes(diarization.state) ? 'Waiting for a result from this recording.'
      : diarization.state === 'disabled' ? 'Live speaker labels are disabled.'
      : 'Speaker labeling has not been confirmed.';
    fields.final.value.textContent = final.provider || 'Final STT';
    fields.final.detail.textContent = `${states[final.state] || 'Unavailable'}${final.jobs?.pending ? ` · queued: ${final.jobs.pending}` : ''}${final.jobs?.failed ? ` · failed: ${final.jobs.failed}` : ''}`;
    const report = data.backend === 'ready' ? data.stages : null;
    onStages(report);
    for (const {id, name, item} of stages) {
      const stage = report?.stale === false ? report[id] : null;
      const state = stage?.status ?? 'unknown';
      const label = {ready: 'available', disabled: 'disabled', unavailable: 'unavailable',
        misconfigured: 'configuration error'}[state];
      item.dataset.state = state;
      item.textContent = name + ' · ' + (label || (report?.stale ? 'check expired' : 'no data'));
      item.title = stage?.name || '';
    }
    const draft = JSON.stringify(sessions.map(({preview_id, source, origin, revision, text, text_truncated, segments, withdrawn}) =>
      [preview_id, source, origin, revision, text, text_truncated, segments, withdrawn]));
    if (draft !== lastDraft || data.backend !== previous?.backend) {
      lastDraft = draft;
      indicators = [];
      const fragment = document.createDocumentFragment();
      if (!sessions.length) fragment.append(element('p', 'live-empty', data.backend === 'ready'
        ? 'No active recording. The final transcript will appear in the library after processing.'
        : 'Server disconnected. Live text unavailable. Retrying.'));
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
            const speaker = turn.draft ? 'Draft' : turn.speaker === null ? 'Unknown speaker' : `Speaker ${turn.speaker + 1}`;
            row.append(element('span', 'turn-label', [speaker, Number.isFinite(turn.start) ? formatTime(turn.start) : ''].filter(Boolean).join(' · ')),
              element('p', 'live-text', turn.text.join(' ')));
            list.append(row);
          }
          if (session.withdrawn?.text) {
            const row = element('li', 'withdrawn');
            row.append(element('span', 'turn-label', 'Previous text · unconfirmed'),
              element('p', 'live-text', session.withdrawn.text));
            list.append(row);
          }
          block.append(list);
        } else {
          block.append(element('p', session.text ? 'live-text' : 'live-empty', session.text || 'Waiting for speech…'));
        }
        if (session.text_truncated) block.append(element('p', 'monitor-note', 'Showing recent turns. The full transcript will appear in the archive after processing.'));
        fragment.append(block);
      }
      text.replaceChildren(fragment);
    }
    const receiving = [];
    const currentStreams = new Map();
    sessions.forEach((session, index) => {
      const state = streamActivity(session, streams.get(session.preview_id), Date.now());
      if (session.preview_id) currentStreams.set(session.preview_id, state);
      if (state.tone === 'active') receiving.push(session);
      const duration = Number.isFinite(session.audio_seconds) ? formatTime(session.audio_seconds) : '';
      indicators[index].textContent = [duration, state.label].filter(Boolean).join(' · ');
      indicators[index].dataset.tone = state.tone;
    });
    if (activity.tone === 'active' && sessions.length > 1) {
      const affected = indicators.filter(node => ['error', 'waiting'].includes(node.dataset.tone)).length;
      if (affected) {
        badge.textContent = `Need attention: ${affected} of ${sessions.length}`;
        badge.dataset.tone = 'waiting';
      }
    }
    const sources = [...new Set((receiving.length ? receiving : sessions).map(liveSourceLabel))];
    fields.audio.value.textContent = sources.join(' + ') || 'No active recording';
    let sourceStatus = {label: badge.textContent, tone: badge.dataset.tone};
    if (receiving.length) {
      sourceStatus = {label: 'Receiving audio', tone: 'active'};
      const frames = receiving.reduce((total, session) => total + session.frames_received, 0);
      const details = [sourceStatus.label];
      if (receiving.every(session => Number.isFinite(session.audio_seconds))) {
        details.push(formatTime(receiving.reduce((total, session) => total + session.audio_seconds, 0)));
      }
      details.push(`${frames} frames`);
      fields.audio.detail.textContent = details.join(' · ');
    } else {
      if (sessions.length && activity.tone !== 'error') sourceStatus = {label: 'Connected inputs', tone: 'waiting'};
      fields.audio.detail.textContent = sourceStatus.label;
    }
    onSources(sources, sourceStatus);
    streams = currentStreams;
    const serialized = JSON.stringify(data.events || []);
    if (serialized !== lastEvents) {
      lastEvents = serialized;
      events.replaceChildren(...(data.events || []).map(event => {
        const row = element('li');
        const stamp = new Date(event.observed_at).toLocaleTimeString('en-GB');
        row.append(element('time', '', stamp), element('span', '', event.message));
        return row;
      }));
      summary.textContent = `Events · ${(data.events || []).length}`;
    }
    freshness.textContent = data.observed_at ? `Checked at ${new Date(data.observed_at).toLocaleTimeString('en-GB')} · updates every second` : 'The library is offline. Retrying…';
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
