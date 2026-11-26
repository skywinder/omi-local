export async function summaryRequest(id, body) {
  const response = await fetch(`/api/recordings/${encodeURIComponent(id)}/summary`, {
    method: body ? 'POST' : 'GET', signal: AbortSignal.timeout(12000),
    ...(body ? {headers: {'Content-Type': 'application/json', 'X-Omiloc-Request': 'summary'}, body: JSON.stringify(body)} : {}),
  });
  if (!response.ok) throw new Error('Summary request unavailable');
  return response.json();
}

export function summaryStatus(job) {
  if (job?.state === 'ready') return 'Summary ready.';
  if (job?.state === 'failed') {
    const errors = {recording_changed: 'The recording changed. Reload before generating again.',
      connection: 'The model could not be reached. Check the provider and retry.',
      timeout: 'The model timed out. Check the provider and retry.', http_429: 'The model is busy. Retry later.',
      credential_missing: 'The model key is unavailable. Check provider settings.'};
    return errors[job.error] || 'Summary generation failed. Check the recording and provider settings.';
  }
  if (job?.state !== 'queued') return '';
  const phases = {waiting: 'Summary queued.', reading: 'Reading the saved transcript.',
    sections: 'Summarizing transcript sections.', combining: 'Combining sections.', saving: 'Saving the summary.'};
  const progress = job.progress;
  const count = progress?.phase === 'sections' && Number.isInteger(progress.completed) && Number.isInteger(progress.total)
    ? ` ${progress.completed}/${progress.total}.` : '';
  return `${phases[progress?.phase] || 'Generating summary.'}${count} You can leave this recording.`;
}

function element(tag, text) {
  const value = document.createElement(tag);
  if (text !== undefined) value.textContent = text;
  return value;
}

export function mountRecordingSummary(root, {request = summaryRequest, onOptions = () => {},
  schedule = setTimeout, cancel = clearTimeout, uuid = () => crypto.randomUUID()} = {}) {
  let active, timer;
  const provenance = element('p'); provenance.className = 'summary-provenance';
  const form = element('form'); form.className = 'summary-controls';
  const provider = element('select'); provider.required = true;
  const template = element('select'); template.required = true;
  const prompt = element('textarea'); prompt.rows = 4; prompt.maxLength = 8000; prompt.required = true;
  const advanced = element('details'); advanced.append(element('summary', 'Edit instruction'));
  const promptLabel = element('label', 'Instruction for this generation'); promptLabel.append(prompt); advanced.append(promptLabel);
  const status = element('p'); status.setAttribute('role', 'status');
  const generate = element('button', 'Generate summary'); generate.type = 'submit';
  const reload = element('button', 'Reload summary options'); reload.type = 'button';
  for (const [name, control] of [['Model for next summary', provider], ['Template for next summary', template]]) {
    const label = element('label', name); label.append(control); form.append(label);
  }
  form.append(advanced, element('p', 'Generate replaces the summary using the selected model and instruction.'), generate, reload, status);
  root.replaceChildren(provenance, form);

  function enabled(run) {
    const busy = run.busy || run.options?.job?.state === 'queued';
    provider.disabled = template.disabled = prompt.disabled = Boolean(busy);
    generate.disabled = Boolean(busy || !run.options?.providers.length || !run.options?.templates.length);
    reload.disabled = Boolean(run.busy);
  }
  function fill(control, rows, value, label) {
    control.replaceChildren(...rows.map(row => {
      const option = element('option', label(row)); option.value = row.value; return option;
    }));
    control.value = rows.some(row => row.value === value) ? value : rows[0]?.value || '';
  }
  function show(run, options, preserve) {
    if (active !== run) return;
    run.options = options;
    const saved = options.published;
    provenance.textContent = 'Published summary · ' + [
      `Template: ${saved?.template_name || 'not recorded'}`, `Model: ${saved?.model || 'not recorded'}`,
    ].join(' · ');
    if (!preserve) {
      fill(provider, options.providers.map(row => ({...row, value: row.binding})), options.default_provider_binding,
        row => `${row.name} · ${row.model} · ${row.host}`);
      fill(template, options.templates.map(row => ({...row, value: row.id})), options.default_template_id, row => row.name);
      prompt.value = options.templates.find(row => row.id === template.value)?.prompt || '';
    }
    if (options.job?.state === 'failed') run.signature = null;
    status.textContent = summaryStatus(options.job) || (!options.providers.length ? 'Configure a summary provider in Settings.' : '');
    enabled(run);
    onOptions(run.id, options);
    cancel(timer);
    if (options.job?.state === 'queued') timer = schedule(() => load(run, true), 8000);
  }
  function failed(run) {
    if (active !== run) return;
    status.textContent = 'Connection interrupted. Reload to check the saved result or retry the same request.';
    enabled(run);
  }
  async function load(run, preserve = false) {
    const sequence = ++run.sequence;
    try {
      const options = await request(run.id);
      if (sequence === run.sequence) show(run, options, preserve);
    } catch { if (sequence === run.sequence) failed(run); }
  }
  template.addEventListener('change', () => {
    prompt.value = active?.options?.templates.find(row => row.id === template.value)?.prompt || '';
  });
  reload.addEventListener('click', () => { if (active) return load(active); });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    const run = active;
    const selected = run?.options?.templates.find(row => row.id === template.value);
    if (!selected || generate.disabled || !prompt.value.trim()) return;
    const parameters = {source_revision: run.options.source_revision, provider_binding: provider.value,
      template_id: selected.id, template_digest: selected.digest, prompt: prompt.value.trim()};
    const signature = JSON.stringify(parameters);
    if (run.signature !== signature) { run.signature = signature; run.requestId = uuid(); }
    run.busy = true; ++run.sequence; cancel(timer); enabled(run);
    try {
      const job = await request(run.id, {...parameters, request_id: run.requestId});
      run.busy = false;
      if (active !== run) return;
      show(run, {...run.options, job}, true);
      if (job.state === 'ready') await load(run, true);
    } catch { run.busy = false; failed(run); }
  });
  return {
    refresh(id) {
      if (active?.id === id && !active.busy) return load(active, true);
    },
    open(id) {
      cancel(timer);
      active = id ? {id, sequence: 0} : null;
      root.hidden = !id;
      provenance.textContent = '';
      provider.replaceChildren(); template.replaceChildren(); prompt.value = '';
      advanced.open = false; status.textContent = 'Loading summary options…';
      if (!active) return;
      enabled(active);
      return load(active);
    },
  };
}
