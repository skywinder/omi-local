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

export function processingFailure(record) {
  if (record.status !== 'failed') return '';
  const failed = Object.entries(stageNames).find(([stage]) => record.processing?.[stage]?.status === 'failed');
  if (!failed) return 'Этап сбоя не сохранён. Проверьте журнал обработчика и импорт в архив.';
  const [stage, label] = failed;
  const code = record.processing[stage].error_code;
  const reasons = {
    timeout: 'Сервис не ответил вовремя. Проверьте нагрузку и повторите обработку.',
    connection: 'Нет соединения с сервисом. Проверьте адрес и доступность провайдера.',
    output_limit: 'Ответ превысил лимит модели. Выберите более короткий шаблон итогов.',
    invalid_json: 'Модель вернула некорректный JSON. Проверьте поддержку JSON и шаблон ответа.',
  };
  const http = /^http_([1-5][0-9]{2})$/.exec(code || '');
  const reason = reasons[code] || (http ? `Сервис вернул HTTP ${http[1]}. ${['401','403'].includes(http[1]) ? 'Проверьте ключ доступа.' : 'Проверьте настройки и доступность провайдера.'}` : 'Подробная причина не сохранена.');
  const attempts = Number.isInteger(record.attempts) && record.attempts > 0 ? ` Попыток: ${record.attempts}.` : '';
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
  if (overview) summaryRoot.append(node('h3', '', 'Краткое содержание'), node('p', '', overview));
}
