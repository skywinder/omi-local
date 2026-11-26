import {settingsRequest} from './settings.mjs';

export function tuningStatus(state) {
  if (!state.available) return state.message || 'Быстрые настройки недоступны.';
  if (state.failed_sessions) return 'Сервер не подтвердил применение ко всем потокам.';
  if (!state.active_sessions) return 'Сохранено для следующей записи.';
  if (state.pending_sessions) return 'Часть настроек вступит в силу со следующей записи.';
  if (state.applied_sessions < state.active_sessions) return 'Ожидаем подтверждение от активных потоков…';
  return 'Применено. Следующие реплики используют эти настройки.';
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
    ['asr_coalesce_min_s', 'Буфер звука, с', 0, 10, 0.1],
    ['max_speakers', 'Максимум говорящих', 1, 4, 1],
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
  const label = element('label', 'Текст на экране'), mode = element('select');
  for (const [value, name] of [['stable', 'Только подтверждённые фразы'], ['draft', 'Включая черновики']]) {
    const option = element('option', name); option.value = value; mode.append(option);
  }
  mode.onchange = () => { changed.add('preview_mode'); apply(); };
  inputs.preview_mode = mode; label.append(mode); fields.append(label);
  const save = element('button', 'Применить'), reload = element('button', 'Обновить значения');
  save.type = 'submit'; reload.type = 'button';
  const status = element('p', 'Проверяем поддержку сервера…');
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
    status.textContent = (error.message || 'Нет ответа от сервера.') + ' Обновите значения перед повтором.';
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
        status.textContent = error.message || 'Нет ответа от сервера. Повторяем проверку…';
      }
    } finally { reading = false; }
  }

  async function apply() {
    if (!base?.available || saving || !changed.size || !form.reportValidity()) return;
    editGeneration++;
    saving = true; fields.disabled = save.disabled = reload.disabled = true;
    status.textContent = 'Сохраняем настройки…';
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
