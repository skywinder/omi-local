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
    'providerMisconfigured',
    'providerUnavailable',
)

# The paired selector reports a registry result even when the phone cannot
# establish whether a service started or whether an interrupted request applied.
PROCESSING_MESSAGES = {
    'en': {
        'processingPublished': 'Active shows the profile published on the server. Live Transcript shows whether speech recognition is running.',
        'processingConflict': 'The server rejected the change because the settings changed or processing is busy. Refresh before applying another profile.',
        'processingIndeterminate': 'The server may have applied the change. Refresh to check the active profile.',
        'processingServerManaged': 'Manage this stage in the server’s web library.',
    },
    'ru': {
        'processingPublished': 'Активный профиль выбран на сервере. Работу распознавания речи можно проверить на экране «Живая расшифровка».',
        'processingConflict': 'Сервер отклонил запрос из-за изменения настроек или текущей обработки. Обновите страницу перед следующим переключением.',
        'processingIndeterminate': 'Сервер мог применить изменение. Обновите страницу, чтобы проверить активный профиль.',
        'processingServerManaged': 'Настройки этого этапа доступны в веб-библиотеке сервера.',
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
