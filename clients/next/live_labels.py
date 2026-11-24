"""Materialize Omi Local's paired translation controls in the pinned Flutter app."""

import json


KEYS = (
    'liveTranslation',
    'liveTranslationTargetLanguage',
    'liveTranslationBidirectional',
    'liveTranslationPairHelp',
    'liveTranslationUnconfigured',
    'liveTranslationFailed',
)


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
    literal = json.dumps(translated, ensure_ascii=False, indent=2).replace('$', r'\$')
    (app / 'lib/local_next/live_labels.g.dart').write_text(
        '// Generated from the Local translation catalogue.\n'
        f'const pairedTranslationLabels = <String, Map<String, String>>{literal};\n'
    )
