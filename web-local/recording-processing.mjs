const stageNames = {stt: 'Transcription', diarization: 'Speaker identification', summary: 'Summarization'};
const statusNames = {ready: 'Ready', completed: 'Ready', passed: 'Ready', processing: 'Processing', running: 'Processing', pending: 'Queued', queued: 'Queued', failed: 'Failed', disabled: 'Off', skipped: 'Skipped', no_speech: 'No speech detected'};

export function processingRows(processing) {
  if (!processing || typeof processing !== 'object') return [];
  return Object.entries(stageNames).flatMap(([stage, label]) => {
    const value = processing[stage];
    if (!value) return [];
    const status = typeof value === 'string' ? value : value.status;
    const detail = [value.provider_name, value.model].filter(item => typeof item === 'string' && item.trim()).join(' · ');
    return [{stage, label, status, text: statusNames[status] || 'Unknown status', detail}];
  });
}

export function processingFailure(record) {
  if (record.status !== 'failed') return '';
  const failed = Object.entries(stageNames).find(([stage]) => record.processing?.[stage]?.status === 'failed');
  if (!failed) return 'The failed stage was not recorded. Check the processing and archive import logs.';
  const [stage, label] = failed;
  const code = record.processing[stage].error_code;
  const reasons = {
    timeout: 'The service timed out. Check the load and retry.',
    connection: 'Could not connect. Check provider availability and address.',
    output_limit: 'The response exceeded the model limit. Choose a shorter summary template.',
    invalid_json: 'The model returned invalid JSON. Check JSON support and the response template.',
  };
  const http = /^http_([1-5][0-9]{2})$/.exec(code || '');
  const reason = reasons[code] || (http ? `Service returned HTTP ${http[1]}. ${['401','403'].includes(http[1]) ? 'Check the access key.' : 'Check provider settings and availability.'}` : 'No details were recorded.');
  const attempts = Number.isInteger(record.attempts) && record.attempts > 0 ? ` Attempts: ${record.attempts}.` : '';
  return `${label}. ${reason}${attempts}`;
}

function node(tag, cls, text) {
  const element = document.createElement(tag);
  if (cls) element.className = cls;
  if (text !== undefined) element.textContent = text;
  return element;
}
export function renderProcessing(processingRoot, summaryRoot, record) {
  const rows = processingRows(record.processing);
  processingRoot.hidden = rows.length === 0;
  const list = node('div', 'processing-stages');
  for (const row of rows) {
    const item = node('div', 'processing-stage'); item.dataset.status = row.status;
    item.append(node('span', '', row.label), node('strong', '', row.text));
    if (row.detail) item.append(node('small', '', row.detail));
    list.append(item);
  }
  const failure = processingFailure(record);
  if (failure) {
    processingRoot.hidden = false;
    list.append(node('p', 'processing-error', failure));
  }
  processingRoot.replaceChildren(list);
  const overview = typeof record.summary?.overview === 'string' ? record.summary.overview.trim() : '';
  summaryRoot.hidden = !overview;
  summaryRoot.replaceChildren();
  if (overview) summaryRoot.append(node('h3', '', 'Summary'), node('p', '', overview));
}
