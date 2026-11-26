import 'package:flutter/material.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'accents.dart';
import 'paired_library.dart';
import 'settings_labels.dart';

class NextServerIndicator extends StatelessWidget {
  const NextServerIndicator({super.key, required this.library, required this.name});
  final PairedLibrary library;
  final String name;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: library.connection,
    builder: (context, state, _) {
      final (label, icon, color) = switch (state) {
        NextServerConnection.checking => (
          pairedSettingsLabel(context, 'nextCheckingServer'),
          Icons.more_horiz,
          OmiColors.textTertiary,
        ),
        NextServerConnection.connected => (context.l10n.connected, Icons.check_circle, NextAccent.green.of(context)),
        NextServerConnection.unreachable => (
          pairedSettingsLabel(context, 'nextServerUnreachable'),
          Icons.cloud_off_outlined,
          NextAccent.amber.of(context),
        ),
        NextServerConnection.rejected => (
          pairedSettingsLabel(context, 'nextServerRejected'),
          Icons.key_off_outlined,
          NextAccent.red.of(context),
        ),
        NextServerConnection.invalid => (
          pairedSettingsLabel(context, 'nextServerInvalid'),
          Icons.error_outline,
          NextAccent.red.of(context),
        ),
      };
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              '$name · $label',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      );
    },
  );
}
