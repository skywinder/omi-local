export const stages = {
  live: {title: 'Live STT', description: 'Show text while recording.', off: 'Turn off live text',
    effect: 'New sessions will still capture audio and get a transcript after recording.'},
  stt: {title: 'Transcription', description: 'Turn finished recordings into timestamped text.'},
  diarization: {title: 'Speakers', description: 'Identify who spoke in finished recordings.', off: 'Skip speaker labels',
    effect: 'New transcripts will contain text and timestamps without identifying speakers.'},
  summary: {title: 'Summarization', description: 'Generate a title and summary from the transcript.'},
  translation: {title: 'Translation', description: 'Choose a model for translation. Language is set in the app.',
    off: 'Use summary model', effect: 'New translations will use the active summary model when it is available.'},
};
const kinds = {
  live: {'whisperlivekit': 'WhisperLiveKit · on the Omi server', 'parakeet-local': 'Parakeet · on this Mac', external: 'WebSocket server · WLK protocol'},
  stt: {whisperkit: 'WhisperKit · on the Omi server', whisperx: 'WhisperX · on the Omi server', 'parakeet-mlx': 'Parakeet MLX · on the Omi server', 'openai-compatible': 'API server · OpenAI compatible'},
  diarization: {pyannote: 'Pyannote · on the Omi server', mycelia: 'Mycelia API server'},
  summary: {'openai-compatible': 'OpenAI-compatible model'},
  translation: {'openai-compatible': 'OpenAI-compatible model'},
};
const resultLabels = {ready: 'Ready to connect', available: 'Server responded', unavailable: 'Unavailable', misconfigured: 'Check settings'};

export function providerDefaults(stage, kind = Object.keys(kinds[stage])[0]) {
  let settings = {};
  if (stage === 'stt') {
    settings = {diarization_model: 'none'};
    if (kind === 'whisperkit') Object.assign(settings, {model: 'openai_whisper-large-v3-v20240930_626MB', language: 'ru', device: 'cpuAndNeuralEngine'});
    if (kind === 'whisperx') Object.assign(settings, {model: 'large-v3-turbo', language: 'ru', device: 'cpu', compute_type: 'float32', batch_size: 1});
    if (kind === 'parakeet-mlx') Object.assign(settings, {model: 'mlx-community/parakeet-tdt-0.6b-v3', language: 'auto', device: 'gpu', compute_type: 'float32', chunk_duration: 60, overlap_duration: 5});
    if (kind === 'openai-compatible') Object.assign(settings, {provider_url: '', model: '', language: 'auto', device: 'server'});
  }
  if (stage === 'diarization') settings = kind === 'pyannote'
    ? {speaker_model: 'pyannote/speaker-diarization-community-1', speaker_device: 'cpu', speaker_threads: 4, speaker_count: 0}
    : {base_url: ''};
  if (stage === 'summary' || stage === 'translation') settings = {base_url: '', model: '', reasoning: 'default'};
  if (stage === 'live') settings = kind === 'parakeet-local' ? {} : kind === 'external' ? {url: ''}
    : {url: 'ws://127.0.0.1:10302/asr', python: '', model_dir: '', language: 'ru', chunk_seconds: 4};
  return {name: '', stage, kind, settings};
}

const field = (key, label, extras = {}) => ({key, label, ...extras});
export function providerFields(profile) {
  const {stage, kind} = profile;
  if (stage === 'live' && kind === 'parakeet-local') return [];
  if (stage === 'live') return kind === 'external'
    ? [field('url', 'WebSocket URL', {required: true, placeholder: 'wss://server.example/asr'})]
    : [field('url', 'Local WebSocket URL', {required: true}), field('python', 'Server Python executable', {required: true}), field('model_dir', 'Model directory', {required: true}),
      field('language', 'Language', {options: {ru: 'Russian', en: 'English', auto: 'Automatic'}}), field('chunk_seconds', 'Segment length (seconds)', {type: 'number', min: 1, max: 10, step: 0.5})];
  if (stage === 'summary' || stage === 'translation') return [field('base_url', 'API base URL', {required: true, placeholder: 'http://127.0.0.1:11434/v1'}),
    field('model', 'Model', stage === 'summary' ? {models: true, hint: 'Leave blank to use the model loaded by the provider.'} : {required: true, models: true}),
    field('reasoning', 'Model reasoning', {options: {default: 'Server default', off: 'Off (Qwen3 on llama.cpp or vLLM)'}, hint: 'Disable if reasoning uses the full output budget and no summary appears.'})];
  if (stage === 'diarization') return kind === 'mycelia'
    ? [field('base_url', 'Server base URL', {required: true, placeholder: 'https://server.example'}),
      field('min_speakers', 'Minimum speakers', {type: 'number', min: 1, max: 32, optional: true, placeholder: 'Automatic'}),
      field('max_speakers', 'Maximum speakers', {type: 'number', min: 1, max: 32, optional: true, placeholder: 'Automatic'})]
    : [field('speaker_model', 'Model', {required: true, models: true}), field('speaker_device', 'Device', {options: {cpu: 'CPU', mps: 'Apple GPU (MPS)'}}),
      field('speaker_threads', 'CPU threads', {type: 'number', min: 1, max: 16}), field('speaker_count', 'Speaker count', {type: 'number', min: 0, max: 32, hint: 'Use 0 to detect automatically.'}),
      field('speaker_python', 'Python', {advanced: true, hint: 'Leave blank to use the omiloc environment.'})];
  const common = [field('model', 'Model', {required: true, models: true}), field('language', 'Language', {required: true, hint: 'Language code, such as ru or en. Supported models also accept auto.'})];
  if (kind === 'openai-compatible') return [field('provider_url', 'API base URL', {required: true, placeholder: 'https://server.example/v1'}), ...common];
  if (kind === 'whisperkit') return [field('model', 'Installed model', {readonly: true}), common[1], field('assets_path', 'WhisperKit directory', {advanced: true, hint: 'Leave blank to use the omiloc environment.'})];
  if (kind === 'parakeet-mlx') return [common[0], field('language', 'Language', {readonly: true, hint: 'Parakeet detects the language automatically.'}),
    field('chunk_duration', 'Segment length (seconds)', {type: 'number', min: 10, max: 60, advanced: true}), field('overlap_duration', 'Overlap (seconds)', {type: 'number', min: 1, max: 59, advanced: true}),
    field('python', 'Python', {advanced: true}), field('assets_path', 'Models directory', {advanced: true})];
  return [...common, field('compute_type', 'Compute settings', {options: {float32: 'Float32', int8: 'Int8', int8_float32: 'Int8 / Float32'}, advanced: true}),
    field('batch_size', 'Batch size', {type: 'number', min: 1, max: 8, advanced: true}), field('python', 'Python', {advanced: true}), field('assets_path', 'Models directory', {advanced: true})];
}

export function draftPayload(profile, apiKey = '', clearKey = false) {
  const {id, name, stage, kind, settings} = profile;
  const payload = {profile: {...(id ? {id} : {}), name: name.trim(), stage, kind, settings: structuredClone(settings)}};
  if (stage === 'summary') payload.profile.settings.model_source = settings.model?.trim() ? 'profile' : 'provider';
  if (clearKey) payload.clear_key = true;
  else if (apiKey.trim()) payload.api_key = apiKey.trim();
  return payload;
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  return value;
}
export function profileMatches(saved, effective) {
  const comparable = profile => Object.fromEntries(Object.entries(profile.settings || {}).filter(([key]) => profile.stage !== 'stt' || key !== 'diarization_model'));
  return !!saved && !!effective && saved.id === effective.id && saved.kind === effective.kind &&
    saved.configuration_revision === effective.configuration_revision && saved.has_key === effective.has_key &&
    JSON.stringify(canonical(comparable(saved))) === JSON.stringify(canonical(comparable(effective)));
}
export async function settingsRequest(path, body, method = 'POST', fetcher = fetch) {
  const timeout = path === '/activate' ? 720000 : ['/probe', '/models'].includes(path) ? 130000 : 15000;
  const response = await fetcher(`/api/settings${path}`, {method, cache: 'no-store', signal: AbortSignal.timeout(timeout),
    ...(method === 'GET' ? {} : {headers: {'Content-Type': 'application/json', 'X-Omiloc-Request': 'settings'}, body: JSON.stringify(body)})});
  const data = await response.json();
  if (!response.ok) {
    const error = new Error(data.error || 'Request failed.');
    error.status = response.status;
    error.field = data.field;
    error.outcome = data.outcome;
    throw error;
  }
  return data;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function button(text, action, className = 'settings-button') {
  const node = el('button', className, text);
  node.type = 'button';
  node.addEventListener('click', action);
  return node;
}
function fingerprint(profile) { return JSON.stringify(canonical(draftPayload(profile))); }
function profileLabel(profile) { return profile ? `${profile.name || kinds[profile.stage]?.[profile.kind] || profile.kind}${profile.settings?.model || profile.settings?.speaker_model ? ` · ${profile.settings.model || profile.settings.speaker_model}` : ''}` : 'Off'; }

export function mountSettings(root, {request = settingsRequest, openTemplates} = {}) {
  const state = {data: null, draft: null, busy: false, models: [], checks: new Map(), loaded: false, generation: 0};
  const unavailableUntil = new Map();
  let availability, updateAvailabilityRows = [];
  let feedback, editor, draftKey, clearKey, fieldInputs = new Map(), disabledControls = new WeakMap();
  function message(text = '', tone = '') {
    if (!feedback) return;
    feedback.textContent = text;
    feedback.hidden = !text;
    feedback.dataset.tone = tone;
  }
  function busy(value) {
    state.busy = value;
    root.setAttribute('aria-busy', String(value));
    for (const control of root.querySelectorAll('button,input,select')) {
      if (value) { disabledControls.set(control, control.disabled); control.disabled = true; }
      else if (disabledControls.has(control)) { control.disabled = disabledControls.get(control); disabledControls.delete(control); }
    }
  }
  function fail(error) {
    const text = error.name === 'TimeoutError' ? 'The server has not responded. Refresh settings before retrying.'
      : error instanceof TypeError || error instanceof SyntaxError ? 'Cannot reach the audio library. Try again when the connection returns.'
      : error.status === 409 ? `${error.message} Refresh settings to try again. Your draft stays open.` : error.message;
    message(text, 'error');
    const input = fieldInputs.get(error.field?.replace(/^settings\./, ''));
    if (input) {
      input.setAttribute('aria-invalid', 'true');
      input.parentElement.querySelector('.settings-field-error')?.remove();
      const hint = el('span', 'settings-field-error', error.message);
      hint.id = `${input.id}-error`;
      input.setAttribute('aria-describedby', hint.id);
      input.parentElement.append(hint);
      input.focus();
    }
  }
  async function operation(action, success, progress = 'Working…') {
    if (state.busy) return;
    busy(true);
    message(progress);
    try { await action(); if (success) message(success, 'success'); }
    catch (error) { fail(error); }
    finally { busy(false); }
  }
  async function load() {
    await operation(async () => {
      state.data = await request('', undefined, 'GET');
      state.loaded = true;
      render();
    });
  }
  function choose(stage, profile = null) {
    state.draft = profile ? structuredClone(profile) : providerDefaults(stage);
    state.models = [];
    state.generation++;
    render();
    fieldInputs.get('name')?.focus();
  }
  function formField(spec) {
    const wrapper = el('label', 'settings-field');
    const id = `provider-${spec.key}`;
    wrapper.htmlFor = id;
    wrapper.append(el('span', 'settings-field-label', spec.label));
    const input = el(spec.options ? 'select' : 'input');
    input.id = id;
    input.name = spec.key;
    if (spec.options) for (const [value, text] of Object.entries(spec.options)) {
      const option = el('option', '', text); option.value = value; input.append(option);
    }
    else input.type = spec.type || 'text';
    input.value = spec.key === 'name' ? state.draft.name : state.draft.settings[spec.key] ?? '';
    input.required = !!spec.required;
    input.readOnly = !!spec.readonly;
    if (spec.placeholder) input.placeholder = spec.placeholder;
    if (spec.min !== undefined) input.min = spec.min;
    if (spec.max !== undefined) input.max = spec.max;
    if (spec.type === 'number') input.step = spec.step || 1;
    if (spec.models) input.setAttribute('list', 'provider-models');
    if (spec.hint) { const hint = el('span', 'settings-field-hint', spec.hint); hint.id = `${id}-hint`; input.setAttribute('aria-describedby', hint.id); wrapper.append(hint); }
    input.addEventListener('input', () => {
      if (spec.key === 'name') state.draft.name = input.value;
      else if (spec.optional && input.value === '') delete state.draft.settings[spec.key];
      else state.draft.settings[spec.key] = spec.type === 'number' ? (input.value === '' ? null : Number(input.value)) : input.value;
      input.removeAttribute('aria-invalid');
      wrapper.querySelector('.settings-field-error')?.remove();
      if (spec.hint) input.setAttribute('aria-describedby', `${id}-hint`);
      else input.removeAttribute('aria-describedby');
      message();
    });
    wrapper.append(input);
    fieldInputs.set(spec.key, input);
    return wrapper;
  }
  function currentPayload() { return draftPayload(state.draft, draftKey?.value || '', clearKey?.checked || false); }
  function editorView() {
    fieldInputs = new Map();
    draftKey = null; clearKey = null;
    if (!state.draft) return null;
    const stage = state.draft.stage;
    editor = el('form', 'provider-editor');
    editor.setAttribute('aria-label', 'Provider editor');
    editor.append(el('h3', '', state.draft.id ? 'Edit provider' : 'New provider'));
    const grid = el('div', 'settings-fields');
    grid.append(formField(field('name', 'Name', {required: true})));
    const type = el('label', 'settings-field');
    type.append(el('span', 'settings-field-label', 'Connection type'));
    const select = el('select'); select.name = 'kind'; select.setAttribute('aria-label', 'Connection type');
    for (const [value, text] of Object.entries(kinds[stage])) { const option = el('option', '', text); option.value = value; select.append(option); }
    select.value = state.draft.kind;
    select.disabled = !!state.draft.id;
    select.addEventListener('change', () => {
      state.draft = {...state.draft, ...providerDefaults(stage, select.value), name: state.draft.name};
      state.models = [];
      render();
    });
    type.append(select);
    if (state.draft.id) type.append(el('span', 'settings-field-hint', 'Add a profile to use a different connection type.'));
    grid.append(type);
    const fields = providerFields(state.draft);
    for (const spec of fields.filter(item => !item.advanced)) grid.append(formField(spec));
    editor.append(grid);
    if (fields.some(item => item.advanced)) {
      const advanced = el('details', 'settings-advanced');
      advanced.append(el('summary', '', 'Runtime settings'));
      const inner = el('div', 'settings-fields');
      fields.filter(item => item.advanced).forEach(spec => inner.append(formField(spec)));
      advanced.append(inner); editor.append(advanced);
    }
    const remote = state.draft.kind === 'openai-compatible' || state.draft.kind === 'mycelia' || state.draft.kind === 'external';
    if (remote) {
      const key = el('label', 'settings-field');
      key.append(el('span', 'settings-field-label', 'API key (optional)'));
      draftKey = el('input'); draftKey.type = 'password'; draftKey.autocomplete = 'new-password'; draftKey.name = 'api-key';
      draftKey.placeholder = state.draft.has_key ? 'Key saved. Enter a new value to replace it.' : 'No key';
      key.append(draftKey); editor.append(key);
      if (state.draft.has_key) {
        const clear = el('label', 'settings-checkbox'); clearKey = el('input'); clearKey.type = 'checkbox';
        clearKey.addEventListener('change', () => { if (clearKey.checked) draftKey.value = ''; });
        draftKey.addEventListener('input', () => { if (draftKey.value) clearKey.checked = false; });
        clear.append(clearKey, el('span', '', 'Remove saved key')); editor.append(clear);
      }
      editor.append(el('p', 'settings-note', 'Use a URL reachable from the Omi server. Localhost means the Omi host or container. Use HTTPS or WSS for domain names.'));
    }
    if (stage === 'live' && state.draft.kind === 'external') editor.append(el('p', 'settings-note', 'The server must support WLK /asr. Configure its model, language and live speaker identification on that server.'));
    if (stage === 'stt' && remote) editor.append(el('p', 'settings-note', 'Phrase playback requires segment or word timestamps from the server.'));
    if (state.draft.settings.diarization?.enabled) editor.append(el('p', 'settings-note', 'This profile keeps its live speaker settings. The Speakers category configures finished recordings.'));
    if (state.draft.embedded) editor.append(el('p', 'settings-note', 'This profile uses built-in speaker identification. Add a Pyannote or Mycelia profile to run it separately.'));
    const models = el('datalist'); models.id = 'provider-models';
    for (const model of state.models) { const option = el('option'); option.value = model; models.append(option); }
    editor.append(models);
    const actions = el('div', 'settings-actions');
    const save = el('button', 'settings-button primary', 'Save profile'); save.type = 'submit';
    actions.append(save, button('Test connection', () => check('/probe')));
    if (fields.some(item => item.models)) actions.append(button('Load models', () => check('/models')));
    actions.append(button('Close', () => { state.draft = null; render(); }));
    editor.append(actions, el('p', 'settings-note', 'After saving, choose Use provider to make this profile active.'));
    editor.addEventListener('submit', event => {
      event.preventDefault();
      if (!editor.reportValidity()) return;
      const payload = currentPayload();
      operation(async () => {
        state.data = await request('/save', {revision: state.data.revision, ...payload});
        state.checks.delete(fingerprint(payload.profile));
        state.draft = null; render();
      }, 'Profile saved. Choose Use provider to activate it.', 'Saving profile…');
    });
    return editor;
  }
  async function check(path) {
    const model = fieldInputs.get('model'), required = model?.required;
    if (path === '/models' && model) model.required = false;
    const valid = editor.reportValidity();
    if (model) model.required = required;
    if (!valid) return;
    const payload = currentPayload(), key = fingerprint(payload.profile);
    await operation(async () => {
      const result = await request(path, payload);
      if (!payload.api_key && !payload.clear_key) state.checks.set(key, result);
      if (Array.isArray(result.models)) {
        state.models = result.models.filter(model => typeof model === 'string');
        const list = editor.querySelector('datalist');
        list?.replaceChildren(...state.models.map(model => { const option = el('option'); option.value = model; return option; }));
      }
      const label = resultLabels[result.state] || 'Test complete';
      const suffix = path === '/models' ? ` Models found: ${state.models.length}. You can also enter a model name.` : ' This check uses no recordings.';
      message(`${label}. ${result.message || ''}${suffix}`, ['ready', 'available'].includes(result.state) ? 'success' : 'error');
    }, '', path === '/models' ? 'Loading models…' : 'Testing connection…');
  }
  function activate(stage, id) {
    const summary = stage === 'summary';
    return operation(async () => {
      try {
        state.data = await request('/activate', {revision: state.data.revision, stage, id});
        unavailableUntil.set(stage, availability?.checked_at || 0);
      } catch (error) {
        if (error.name !== 'TimeoutError' && error.outcome !== 'indeterminate') throw error;
        let refreshed = false;
        try { state.data = await request('', undefined, 'GET'); refreshed = true; render(); }
        catch { /* The activation outcome remains unknown until the server can be read. */ }
        throw new Error(`${error.name === 'TimeoutError' ? 'Request timed out.' : error.message} Change not confirmed. ${refreshed ? 'Reloaded current settings.' : 'Select Refresh after the connection returns.'} The request was not repeated.`);
      }
      render();
      if (summary) {
        const on = Boolean(state.data.effective.summary);
        message(on ? 'Automatic summaries enabled for new processing jobs.' : 'Automatic summaries are off for new processing jobs.', 'success');
        root.querySelector('.summary-setting-action')?.focus({preventScroll: true});
      }
    }, summary ? '' : id ? 'Provider applies to new jobs and sessions.' : 'Setting applies to new jobs and sessions.',
    summary ? (id ? 'Enabling automatic summaries…' : 'Turning off automatic summaries…')
      : 'Applying settings. Setting up a local model can take up to 12 minutes.');
  }
  function observedStatus(profile) {
    if (availability?.stale !== false || !Number.isFinite(availability.checked_at)
        || availability.checked_at <= (unavailableUntil.get(profile.stage) ?? -1)) return '';
    const report = availability[profile.stage];
    const matches = report?.name === profile.name || (profile.stage === 'summary' && report?.name === profile.settings.model);
    if (!report || report.kind !== profile.kind || !matches) return '';
    return report.status;
  }

  function summarySwitch(effective, profiles) {
    const enabled = Boolean(effective);
    const only = profiles.length === 1 ? profiles[0] : null;
    const panel = el('div', 'summary-setting');
    panel.dataset.enabled = String(enabled);
    const copy = el('div');
    copy.append(el('p', 'summary-setting-state', enabled ? 'Automatic summaries on' : 'Automatic summaries off'));
    copy.append(el('p', 'settings-description', enabled
      ? 'New processing jobs generate a summary after transcription.'
      : 'New processing jobs keep audio and a transcript. Automatic summary generation is paused. Existing summaries stay available.'));
    if (!enabled) {
      copy.append(el('p', 'settings-description', only ? `Resume with ${only.name}.`
        : profiles.length ? 'Select Enable on the provider you want to use.' : 'Add a summary provider to enable automatic summaries.'));
    }
    panel.append(copy);
    if (enabled || only) {
      const label = enabled ? 'Turn off automatic summaries' : 'Enable automatic summaries';
      panel.append(button(label, () => activate('summary', enabled ? null : only.id),
        'settings-button summary-setting-action' + (enabled ? '' : ' primary')));
    }
    return panel;
  }

  function renderCategory(stageId, stage, form) {
    const section = el('section', 'provider-category');
    const title = el('h3', '', stage.title);
    title.id = `provider-category-${stageId}`;
    section.setAttribute('aria-labelledby', title.id);
    const heading = el('header', 'provider-section-heading');
    const intro = el('div');
    intro.append(title, el('p', 'settings-description', stage.description));
    const toolbar = el('div', 'provider-toolbar');
    if (stageId === 'summary' && openTemplates) toolbar.append(button('Edit summary templates', openTemplates));
    toolbar.append(button('+ Add provider', () => choose(stageId), 'settings-button add-provider'));
    heading.append(intro, toolbar);
    section.append(heading);

    const selected = state.data.profiles.find(profile => profile.id === state.data.active[stageId]);
    const effective = state.data.effective[stageId];
    const profiles = state.data.profiles.filter(profile => profile.stage === stageId);
    const summary = stageId === 'summary';
    if (summary) section.append(summarySwitch(effective, profiles));
    const current = el('div', 'provider-category-current');
    if ((!summary || effective) && !profiles.some(profile => profileMatches(profile, effective))) {
      const nameLabel = effective ? 'Active provider · ' + profileLabel(effective) : 'Stage off';
      current.append(el('p', 'active-provider', nameLabel));
    }
    if (selected && !profileMatches(selected, effective)) {
      current.append(el('p', 'settings-pending', 'Saved edits are pending. Choose Use provider to apply them.'));
    }
    if (effective?.inherited_from === 'summary') current.append(el('p', 'settings-note', 'Uses the active summary model.'));
    if (current.children.length) section.append(current);

    const list = el('ul', 'provider-list');
    list.setAttribute('role', 'list');
    list.setAttribute('aria-label', stage.title + ' providers');
    for (const profile of profiles) {
      const active = profileMatches(profile, effective);
      const row = el('li', `provider-row${active ? ' active' : ''}`);
      const details = el('div', 'provider-identity');
      const name = el('div', 'provider-name');
      name.append(el('h5', '', profile.name));
      if (active || profile.id === selected?.id) name.append(el('span', 'provider-badge', active ? 'Active' : 'Selected'));
      const model = profile.settings.model || profile.settings.speaker_model;
      const kind = kinds[profile.stage]?.[profile.kind] || profile.kind;
      details.append(name, el('p', 'provider-kind', [kind, model].filter(Boolean).join(' · ')));
      const endpoint = profile.settings.base_url || profile.settings.provider_url || profile.settings.url;
      if (endpoint) details.append(el('p', 'provider-endpoint', endpoint));

      const key = fingerprint(profile);
      const health = el('div', 'provider-health');
      const label = el('span', 'connection-label');
      const hint = el('p', 'connection-help');
      function updateHealth() {
        const checked = state.checks.get(key);
        const observed = active ? observedStatus(profile) : '';
        const status = checked?.state || observed;
        label.textContent = checked ? resultLabels[status] || 'Test complete'
          : ({ready: 'Available', unavailable: 'Unavailable', misconfigured: 'Check settings'}[observed] || 'Connection not tested');
        health.dataset.tone = !status ? 'muted' : ['ready', 'available'].includes(status) ? 'ready' : 'attention';
        hint.textContent = health.dataset.tone === 'attention' ? checked?.message || '' : '';
        hint.hidden = !hint.textContent;
      }
      updateHealth();
      if (active) updateAvailabilityRows.push(updateHealth);
      health.append(label, hint);

      const actions = el('div', 'provider-actions');
      const test = button('Test connection', () => operation(async () => {
        const result = await request('/probe', draftPayload(profile));
        state.checks.set(key, result);
        updateHealth();
        message(resultLabels[result.state] || 'Test complete', ['ready', 'available'].includes(result.state) ? 'success' : 'error');
      }, '', 'Testing connection…'), 'settings-button provider-test');
      actions.append(test, button('Edit', () => choose(stageId, profile), 'settings-button provider-edit'));
      if (!active && (!summary || effective || profiles.length > 1)) {
        const use = button(summary && !effective ? 'Enable' : 'Use provider', () => activate(stageId, profile.id),
          'settings-button primary provider-use');
        if (summary && !effective) use.setAttribute('aria-label', `Enable automatic summaries with ${profile.name}`);
        actions.append(use);
      }
      const remove = button('Delete', () => operation(async () => {
        state.data = await request(`/profiles/${encodeURIComponent(profile.id)}`, {revision: state.data.revision}, 'DELETE');
        if (state.draft?.id === profile.id) state.draft = null;
        render();
      }, 'Profile deleted.'), 'settings-button provider-delete');
      remove.disabled = profile.id === selected?.id || profile.id === effective?.id;
      if (remove.disabled) remove.title = 'Choose another provider before deleting this profile.';
      actions.append(remove);
      row.append(details, health, actions);
      if (form && state.draft.id === profile.id) row.append(form);
      list.append(row);
    }
    if (profiles.length) section.append(list);
    else section.append(el('p', 'provider-empty', 'No providers for this category.'));
    if (form && state.draft.stage === stageId && !profiles.some(profile => profile.id === state.draft.id)) section.append(form);

    if (stage.off && (stageId === 'translation' ? selected : selected || effective)) {
      const change = el('div', 'stage-change');
      const effect = el('p', 'settings-note', stage.effect);
      effect.id = `stage-change-effect-${stageId}`;
      const off = button(stage.off, () => activate(stageId, null));
      off.setAttribute('aria-describedby', effect.id);
      change.append(off, effect);
      section.append(change);
    }
    return section;
  }

  function render() {
    const fragment = document.createDocumentFragment();
    feedback = el('p', 'settings-feedback');
    feedback.setAttribute('role', 'status');
    feedback.hidden = true;
    fragment.append(feedback);
    updateAvailabilityRows = [];
    if (state.data) {
      const intro = el('div', 'provider-list-heading');
      intro.append(el('p', 'settings-description', 'Test connection checks reachability from Omi without sending recordings.'),
        button('Refresh', load));
      fragment.append(intro);
      const form = editorView();
      for (const [id, stage] of Object.entries(stages)) fragment.append(renderCategory(id, stage, form));
    } else fragment.append(button('Reload providers', load));
    root.replaceChildren(fragment);
  }
  render();
  return {load, show: () => { if (!state.loaded && !state.busy) return load(); },
    updateAvailability(report) {
      if (JSON.stringify(availability) === JSON.stringify(report)) return;
      availability = report;
      updateAvailabilityRows.forEach(update => update());
    },
    catalogSaved(from, to) {
      if (state.data?.revision === from && !state.busy) state.data.revision = to;
      else state.loaded = false;
    },
  };
}

export function mountSummaryTemplates(root, {request = settingsRequest, onSave = () => {}} = {}) {
  let catalog, drafts, selected, defaultId, operation = '', feedback = '';
  const path = '/summary-settings';
  const dirty = () => catalog && JSON.stringify([catalog.default_template_id, catalog.templates]) !== JSON.stringify([defaultId, drafts]);

  function update(data) {
    catalog = data;
    drafts = data.templates.map(template => ({...template}));
    defaultId = data.default_template_id;
    if (!drafts.some(template => template.id === selected)) selected = null;
  }

  async function load() {
    if (operation) return;
    operation = 'Loading templates…';
    feedback = '';
    render();
    try { update(await request(path, undefined, 'GET')); }
    catch { feedback = 'Could not load summary templates. Try again.'; }
    finally { operation = ''; render(); }
  }

  async function save() {
    if (operation || !dirty() || drafts.some(template => !template.name.trim() || !template.prompt.trim())) return;
    operation = 'Saving templates…';
    feedback = '';
    render();
    const revision = catalog.revision;
    try {
      update(await request(path, {revision, templates: drafts, default_template_id: defaultId}));
      feedback = 'Templates saved.';
      onSave(revision, catalog.revision);
    } catch (error) {
      feedback = error.status === 409
        ? 'Settings changed on the server. Copy any edits you want to keep before reloading.'
        : 'Could not save summary templates. Your edits are still here.';
    } finally { operation = ''; render(); }
  }

  function render(focusId) {
    const status = el('p', 'template-feedback', operation || feedback);
    status.setAttribute('role', 'status');
    root.setAttribute('aria-busy', String(Boolean(operation)));
    if (!catalog) {
      root.replaceChildren(status);
      if (!operation) root.append(button('Retry', load));
      return;
    }
    const toolbar = el('div', 'template-toolbar');
    const defaultLabel = el('p', 'template-default');
    defaultLabel.setAttribute('aria-live', 'polite');
    const create = button('New template', () => {
      selected = crypto.randomUUID();
      drafts.push({id: selected, name: '', prompt: ''});
      feedback = '';
      render();
      root.querySelector('.template-editor input')?.focus();
    });
    create.disabled = drafts.length >= 24;
    toolbar.append(defaultLabel, create);

    const list = el('ul', 'template-list');
    list.setAttribute('role', 'list');
    list.setAttribute('aria-label', 'Saved summary templates');
    const row = drafts.find(template => template.id === selected);
    const saved = catalog.templates.find(template => template.id === catalog.default_template_id);
    const ordered = [drafts.find(template => template.id === saved.id), ...drafts.filter(template => template.id !== saved.id)];
    let selectedLabel, editorParent, toggleToFocus;
    for (const template of ordered) {
      const id = template.id;
      const item = el('li', 'template-row');
      const expanded = template.id === selected;
      const option = button('', () => {
        selected = expanded ? null : template.id;
        if (feedback === 'Templates saved.') feedback = '';
        render(template.id);
      }, 'template-option');
      option.setAttribute('aria-expanded', String(expanded));
      if (expanded) option.setAttribute('aria-controls', 'summary-template-editor');
      const label = el('span', 'template-name', template.name || 'Untitled');
      option.append(label);
      if (expanded) { selectedLabel = label; editorParent = item; }
      if (id === saved.id) option.append(el('small', 'template-badge', 'Default'));
      if (id === defaultId && id !== saved.id) option.append(el('small', 'template-badge pending', 'Pending default'));
      if (id === focusId) toggleToFocus = option;
      item.append(option);
      list.append(item);
    }

    const reload = button('', load);
    let use, apply;
    function updateControls() {
      const next = drafts.find(template => template.id === defaultId);
      const pending = next.id !== saved.id || next.name !== saved.name;
      defaultLabel.textContent = (pending ? 'Pending default · ' : 'Default for new recordings · ') + (next.name || 'Untitled');
      root.dataset.dirty = String(Boolean(dirty()));
      reload.textContent = dirty() ? 'Discard edits and reload' : 'Reload templates';
      if (use) use.disabled = Boolean(operation) || selected === defaultId || !row.name.trim() || !row.prompt.trim();
      apply.disabled = Boolean(operation) || !dirty() || drafts.some(template => !template.name.trim() || !template.prompt.trim());
    }
    apply = button('Save changes', save, 'settings-button primary');
    if (row) {
      const editor = el('div', 'template-editor');
      editor.id = 'summary-template-editor';
      const name = el('input');
      name.value = row.name;
      name.maxLength = 100;
      const prompt = el('textarea');
      prompt.rows = 8;
      prompt.maxLength = 8000;
      prompt.value = row.prompt;
      function edit() {
        if (feedback === 'Templates saved.') {
          feedback = '';
          status.textContent = '';
        }
        updateControls();
      }
      name.addEventListener('input', () => { row.name = name.value; selectedLabel.textContent = row.name || 'Untitled'; edit(); });
      prompt.addEventListener('input', () => { row.prompt = prompt.value; edit(); });
      for (const [label, input] of [['Template name', name], ['Summary prompt', prompt]]) {
        const field = el('label', 'settings-field');
        field.append(el('span', 'settings-field-label', label), input);
        editor.append(field);
      }
      use = button('Set as default', () => {
        const clean = !dirty();
        defaultId = selected;
        feedback = '';
        if (clean) return save();
        render();
      });
      const actions = el('div', 'settings-actions');
      actions.append(use, apply);
      editor.append(actions);
      editorParent.append(editor);
    }
    const footer = el('div', 'template-footer');
    if (!row && dirty()) footer.append(apply);
    footer.append(reload, status);
    root.replaceChildren(toolbar, list, footer);
    updateControls();
    toggleToFocus?.focus({preventScroll: true});
    if (operation) for (const control of root.querySelectorAll('button,input,textarea')) control.disabled = true;
  }
  return {show: () => { if (!dirty()) return load(); }};
}
