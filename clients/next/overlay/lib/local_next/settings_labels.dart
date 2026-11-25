import 'package:flutter/widgets.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'live_labels.g.dart';
import 'processing.dart';

String pairedSettingsLabel(BuildContext context, String key) {
  final locale = Localizations.localeOf(context);
  return pairedSettingsLabels[locale.toLanguageTag()]?[key] ??
      pairedSettingsLabels[locale.languageCode]?[key] ??
      pairedSettingsLabels['en']![key]!;
}

String processingFailureLabel(BuildContext context, NextProcessingFailure failure) => switch (failure) {
  NextProcessingFailure.unsupported => pairedSettingsLabel(context, 'localProcessingUnsupported'),
  NextProcessingFailure.unauthorized => context.l10n.invalidKey,
  NextProcessingFailure.conflict => pairedSettingsLabel(context, 'processingConflict'),
  NextProcessingFailure.indeterminate => pairedSettingsLabel(context, 'processingIndeterminate'),
  NextProcessingFailure.invalid => pairedSettingsLabel(context, 'providerMisconfigured'),
  NextProcessingFailure.unavailable => pairedSettingsLabel(context, 'providerUnavailable'),
};

String processingStageLabel(BuildContext context, NextProcessingStage stage) {
  final l = context.l10n;
  return switch (stage) {
    NextProcessingStage.live => l.liveTranscript,
    NextProcessingStage.stt => '${l.transcription} · ${pairedSettingsLabel(context, 'localProcessingFinished')}',
    NextProcessingStage.diarization =>
      '${pairedSettingsLabel(context, 'diarization')} · ${pairedSettingsLabel(context, 'localProcessingFinished')}',
    NextProcessingStage.summary => l.summary,
    NextProcessingStage.translation => pairedSettingsLabel(context, 'liveTranslation'),
  };
}
