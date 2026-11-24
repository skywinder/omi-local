"""Materialize paired settings labels from Omi Local in the pinned Flutter app."""

import json


KEYS = (
    'liveTranslation',
    'liveTranslationTargetLanguage',
    'liveTranslationBidirectional',
    'liveTranslationPairHelp',
    'liveTranslationUnconfigured',
    'liveTranslationFailed',
    'diarization',
    'localProcessingFinished',
    'localProcessingApplyHelp',
    'localProcessingHelp',
    'localProcessingUnsupported',
    'localProcessingPending',
    'localProcessingProbe',
    'localProcessingKeyHelp',
    'providerMisconfigured',
    'providerUnavailable',
    'localMacServers',
    'transcriptionFailed',
)

# The paired selector reports a registry result even when the phone cannot
# establish whether a service started or whether an interrupted request applied.
PROCESSING_MESSAGES = {
    'en': {
        'processingPublished': 'Active shows the profile published on the server. Live Transcript shows whether speech recognition is running.',
        'processingConflict': 'Settings changed or the server is busy. Refresh before trying again.',
        'processingIndeterminate': 'The server may have applied the change. Refresh to verify the result.',
        'processingServerManaged': 'Manage this stage in the server’s web library.',
        'processingKeyChanged': 'This address belongs to a different server. Enter its key or choose to remove the saved key.',
        'processingMinSpeakers': 'Minimum speakers',
        'processingMaxSpeakers': 'Maximum speakers',
        'processingProbeReady': 'Connection test passed.',
        'processingNoModels': 'The server listed no models. Enter the model name manually.',
        'processingLanguageCode': 'Enter auto or a two- or three-letter language code.',
        'serverCaptureBusy': 'Stop the recording before switching or disconnecting.',
        'serverAudioRetained': 'This phone has recordings waiting for this server. Reconnect and finish delivery before changing its credentials or removing it.',
        'serverActiveEdit': 'Choose Connect to verify changes to the active server.',
        'serverKeyHelp': 'Leave the key blank to keep the saved key for this address.',
        'liveSpeakerLimit': 'Live speaker limit',
        'liveSpeakerHelp': 'The number is an upper limit for detected voices. A saved change applies when the server opens a new recognition stream.',
        'liveSpeakerSaved': 'Saved for the next recognition stream.',
        'liveSpeakerApplied': 'Speaker limit in this stream:',
        'liveSpeakerApplyFailed': 'The provider did not confirm the speaker limit for this stream.',
        'liveSpeakerUnsupported': 'Live speaker tuning is unavailable on this server.',
        'serverStatus': 'Server status',
        'serverStatusUnsupported': 'This server does not provide diagnostics.',
        'serverStatusUnavailable': 'Could not read server status.',
        'archiveSearchUnsupported': 'Archive search requires an updated Omi Local server.',
        'archiveSearchTooLong': 'Enter up to 240 characters.',
        'recordingChatConsent': 'Send your question, relevant transcript excerpts, and recent chat turns to this model?',
        'recordingChatChanged': 'The recording, history or provider changed. Refresh before sending again.',
        'recordingChatUnsupported': 'Recording chat requires an updated Omi Local server.',
        'recordingChatNoProvider': 'Choose and apply a summary model on your Local server to ask questions.',
        'recordingChatPartialContext': 'This answer used selected excerpts from the recording.',
        'recordingChatSourceUnavailable': 'The cited excerpt is no longer available in this recording.',
        'serverStatusAudio': 'Audio received by server',
        'serverNoAudioStream': 'No active audio stream',
        'serverLiveDiarization': 'Live diarization',
        'serverStageStale': 'Waiting for fresh processing status.',
    },
    'ru': {
        'processingPublished': 'Активный профиль выбран на сервере. Работу распознавания речи можно проверить на экране «Живая расшифровка».',
        'processingConflict': 'Настройки изменились или сервер занят. Обновите страницу перед повторной попыткой.',
        'processingIndeterminate': 'Сервер мог применить изменение. Обновите страницу и проверьте результат.',
        'processingServerManaged': 'Настройки этого этапа доступны в веб-библиотеке сервера.',
        'processingKeyChanged': 'Указан другой сервер. Введите его ключ или выберите удаление сохранённого ключа.',
        'processingMinSpeakers': 'Минимум говорящих',
        'processingMaxSpeakers': 'Максимум говорящих',
        'processingProbeReady': 'Связь с провайдером проверена.',
        'processingNoModels': 'Сервер не вернул список моделей. Введите название модели вручную.',
        'processingLanguageCode': 'Введите auto или код языка из двух или трёх строчных букв.',
        'serverCaptureBusy': 'Остановите запись перед сменой или отключением сервера.',
        'serverAudioRetained': 'На телефоне есть записи для этого сервера. Подключитесь к нему и дождитесь доставки, прежде чем менять ключ или адрес либо удалять сервер.',
        'serverActiveEdit': 'Нажмите «Подключиться», чтобы проверить новые настройки активного сервера.',
        'serverKeyHelp': 'Оставьте ключ пустым, чтобы сохранить прежний ключ для этого адреса.',
        'liveSpeakerLimit': 'Лимит говорящих в Live',
        'liveSpeakerHelp': 'Это верхний предел для распознаваемых голосов. Сохранённое значение применяется, когда сервер открывает новый поток распознавания.',
        'liveSpeakerSaved': 'Сохранено для следующего потока распознавания.',
        'liveSpeakerApplied': 'Лимит говорящих в текущем потоке:',
        'liveSpeakerApplyFailed': 'Провайдер не подтвердил лимит говорящих для текущего потока.',
        'liveSpeakerUnsupported': 'Настройка лимита говорящих недоступна на этом сервере.',
        'serverStatus': 'Статус сервера',
        'serverStatusUnsupported': 'Сервер не предоставляет диагностику.',
        'serverStatusUnavailable': 'Не удалось получить статус сервера.',
        'archiveSearchUnsupported': 'Для поиска по архиву обновите сервер Omi Local.',
        'archiveSearchTooLong': 'Введите до 240 символов.',
        'recordingChatConsent': 'Отправить этой модели вопрос, подходящие фрагменты расшифровки и недавние реплики чата?',
        'recordingChatChanged': 'Запись, история или модель изменились. Обновите чат перед повторной отправкой.',
        'recordingChatUnsupported': 'Для чата по записи обновите сервер Omi Local.',
        'recordingChatNoProvider': 'Выберите и примените модель для итогов на сервере Omi Local.',
        'recordingChatPartialContext': 'Ответ составлен по выбранным фрагментам записи.',
        'recordingChatSourceUnavailable': 'Эта цитата больше недоступна в записи.',
        'serverStatusAudio': 'Аудио на сервере',
        'serverNoAudioStream': 'Нет активного аудиопотока',
        'serverLiveDiarization': 'Диаризация в Live',
        'serverStageStale': 'Ожидаем актуальный статус обработки.',
    },
}


def prepare_live_labels(root, app):
    local = root / 'app/lib/l10n'
    english = json.loads((local / 'app_en.arb').read_text())
    translated = {'en': {key: english[key] for key in KEYS}}
    for source in sorted(local.glob('app_*.arb')):
        locale = source.stem.removeprefix('app_').replace('_', '-')
        if locale == 'en':
            continue
        data = json.loads(source.read_text())
        fields = {key: data[key] for key in KEYS if data.get(key) and data[key] != english[key]}
        if fields:
            translated[locale] = fields
    for locale, messages in PROCESSING_MESSAGES.items():
        translated.setdefault(locale, {}).update(messages)
    literal = json.dumps(translated, ensure_ascii=False, indent=2).replace('$', r'\$')
    (app / 'lib/local_next/live_labels.g.dart').write_text(
        '// Generated from the Local settings catalogue.\n'
        f'const pairedSettingsLabels = <String, Map<String, String>>{literal};\n'
    )
