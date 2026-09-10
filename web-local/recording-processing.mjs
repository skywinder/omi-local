const stageNames = {stt: 'Распознавание', diarization: 'Диаризация', summary: 'Суммаризация'};
const statusNames = {ready: 'Готово', completed: 'Готово', passed: 'Готово', processing: 'Обрабатывается', running: 'Обрабатывается', pending: 'В очереди', queued: 'В очереди', failed: 'Ошибка', disabled: 'Выключено', skipped: 'Пропущено', no_speech: 'Речь не обнаружена'};

export function processingRows(processing) {
  if (!processing || typeof processing !== 'object') return [];
  return Object.entries(stageNames).flatMap(([stage, label]) => {
    const value = processing[stage];
    if (!value) return [];
    const status = typeof value === 'string' ? value : value.status;
    const detail = [value.provider_name, value.model].filter(item => typeof item === 'string' && item.trim()).join(' · ');
    return [{stage, label, status, text: statusNames[status] || 'Состояние неизвестно', detail}];
  });
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
  processingRoot.replaceChildren(list);
  const overview = typeof record.summary?.overview === 'string' ? record.summary.overview.trim() : '';
  summaryRoot.hidden = !overview;
  summaryRoot.replaceChildren();
  if (overview) summaryRoot.append(node('h3', '', 'Краткое содержание'), node('p', '', overview));
}
