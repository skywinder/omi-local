import 'package:flutter/material.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

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
      final (label, color) = switch (state) {
        NextServerConnection.checking => (pairedSettingsLabel(context, 'nextCheckingServer'), OmiColors.textTertiary),
        NextServerConnection.connected => (context.l10n.connected, OmiColors.success),
        NextServerConnection.unreachable => (pairedSettingsLabel(context, 'nextServerUnreachable'), OmiColors.warning),
        NextServerConnection.rejected => (pairedSettingsLabel(context, 'nextServerRejected'), OmiColors.warning),
        NextServerConnection.invalid => (pairedSettingsLabel(context, 'nextServerInvalid'), OmiColors.warning),
      };
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, color: color, size: 9),
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
