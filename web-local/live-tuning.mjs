import {settingsRequest} from './settings.mjs';

export function tuningStatus(state) {
  if (!state.available) return state.message || 'Live controls are unavailable.';
  if (state.failed_sessions) return 'The server did not confirm the change. Check your connection and retry.';
  if (!state.active_sessions) return 'Saved for the next recording.';
  if (state.pending_sessions) return 'Some settings were saved for the next recording.';
  if (state.applied_sessions < state.active_sessions) return 'Applying to the current stream…';
  return 'Applied. New segments use these settings.';
}

function element(tag, text) {
  const node = document.createElement(tag);
  if (text) node.textContent = text;
  return node;
}

export function mountLiveTuning(details, request = settingsRequest) {
  const form = element('form');
  const fields = element('fieldset');
  const inputs = {}, sliders = {};
  const changed = new Set();
  let editGeneration = 0;
  let base, reading = false, saving = false, needsReload = false;

  for (const [key, label, min, max, step] of [
    ['asr_coalesce_min_s', 'Audio buffer (seconds)', 0, 10, 0.1],
    ['max_speakers', 'Maximum speakers', 1, 4, 1],
  ]) {
    const group = element('div'), title = element('label', label);
    const number = element('input'), range = element('input');
    number.type = 'number'; range.type = 'range'; number.required = true;
    number.id = 'live-' + key; title.htmlFor = number.id;
    range.setAttribute('aria-label', label);
    for (const input of [number, range]) {
      input.min = min; input.max = max; input.step = step;
      input.addEventListener('input', () => {
        (input === number ? range : number).value = input.value;
        changed.add(key);
      });
      input.addEventListener('change', () => { changed.add(key); apply(); });
    }
    inputs[key] = number; sliders[key] = range;
    group.append(title, range, number); fields.append(group);
  }
  const label = element('label', 'On-screen transcript'), mode = element('select');
  for (const [value, name] of [['stable', 'Confirmed phrases'], ['draft', 'Include drafts']]) {
    const option = element('option', name); option.value = value; mode.append(option);
  }
  mode.onchange = () => { changed.add('preview_mode'); apply(); };
  inputs.preview_mode = mode; label.append(mode); fields.append(label);
  const save = element('button', 'Apply'), reload = element('button', 'Reload values');
  save.type = 'submit'; reload.type = 'button';
  const status = element('p', 'Checking server support…');
  status.setAttribute('role', 'status');
  form.append(fields, save, reload, status); details.append(form);

  function show(data) {
    base = data;
    fields.disabled = save.disabled = !data.available;
    if (data.available) {
      for (const [key, input] of Object.entries(inputs)) input.value = data.settings[key];
      for (const [key, slider] of Object.entries(sliders)) slider.value = data.settings[key];
    }
    status.textContent = tuningStatus(data);
  }

  function problem(error) {
    base = null; needsReload = true;
    fields.disabled = save.disabled = true;
    status.textContent = (error.message || 'The server did not respond.') + ' Reload the values before retrying.';
  }

  async function refresh() {
    if (reading || saving || changed.size || needsReload || document.hidden || !details.open || details.closest('[hidden]')) return;
    const generation = editGeneration;
    reading = true;
    try {
      const data = await request('/live-tuning', undefined, 'GET');
      // A poll started before an edit cannot replace the revision the user edited.
      if (!changed.size && !saving && !needsReload && generation === editGeneration) show(data);
    } catch (error) {
      if (!changed.size && !saving && generation === editGeneration) {
        base = null;
        fields.disabled = save.disabled = true;
        status.textContent = error.message || 'The server did not respond. Retrying…';
      }
    } finally { reading = false; }
  }

  async function apply() {
    if (!base?.available || saving || !changed.size || !form.reportValidity()) return;
    editGeneration++;
    saving = true; fields.disabled = save.disabled = reload.disabled = true;
    status.textContent = 'Saving settings…';
    try {
      const settings = {asr_coalesce_min_s: Number(inputs.asr_coalesce_min_s.value),
        max_speakers: Number(inputs.max_speakers.value), preview_mode: mode.value};
      const data = await request('/live-tuning', {revision: base.revision, settings, changed_fields: [...changed]});
      changed.clear(); show(data);
    } catch (error) { problem(error); }
    finally { saving = false; reload.disabled = false; }
  }

  fields.disabled = save.disabled = true;
  reload.onclick = () => { if (!reading && !saving) { changed.clear(); needsReload = false; refresh(); } };
  form.onsubmit = event => { event.preventDefault(); apply(); };
  details.addEventListener('toggle', refresh);
  return refresh;
}
