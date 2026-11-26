import 'package:flutter/material.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'paired_library.dart';
import 'settings_labels.dart';

Future<bool> runCategoryBackfill(BuildContext context, PairedLibrary library, List<String> ids) async {
  final messenger = ScaffoldMessenger.of(context);
  String label(String key) => pairedSettingsLabel(context, key);
  bool submitted = false;
  try {
    final provider = await library.categoryBackfillProvider();
    if (!context.mounted) return false;
    if (provider == null) throw CategoryBackfillFailure.unavailable;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('${label('categoryBackfillAction')} · ${ids.length}'),
        content: Text('${label('categoryBackfillConsent')}\n\n${provider.model}\n${provider.host}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.cancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(label('categoryBackfillAction'))),
        ],
      ),
    );
    if (!context.mounted || accepted != true) return false;
    submitted = true;
    final result = await library.classifyRecordingCategories(ids, provider.binding);
    if (!context.mounted) return true;
    final report = [
      for (final state in CategoryBackfillState.values)
        if (result.where((entry) => entry == state).length case final int count when count > 0)
          '${label('categoryBackfill_${state.name}')} $count',
    ];
    messenger.showSnackBar(SnackBar(content: Text(report.join(' · '))));
  } catch (error) {
    if (context.mounted) {
      final message = switch (error) {
        CategoryBackfillFailure.providerChanged => label('categoryBackfillProviderChanged'),
        CategoryBackfillFailure.invalidResult => label('categoryBackfillInvalidResult'),
        LibraryFailure.key => context.l10n.invalidKey,
        _ => label('categoryBackfillUnavailable'),
      };
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }
  return submitted;
}
