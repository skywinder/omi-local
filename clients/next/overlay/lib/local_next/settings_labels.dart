import 'package:flutter/widgets.dart';

import 'live_labels.g.dart';

String pairedSettingsLabel(BuildContext context, String key) {
  final locale = Localizations.localeOf(context);
  return pairedSettingsLabels[locale.toLanguageTag()]?[key] ??
      pairedSettingsLabels[locale.languageCode]?[key] ??
      pairedSettingsLabels['en']![key]!;
}
