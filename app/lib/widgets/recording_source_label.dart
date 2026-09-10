import 'package:flutter/material.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/utils/l10n_extensions.dart';

/// The local recording's input, independent of Bluetooth connection status.
class RecordingSourceLabel extends StatelessWidget {
  const RecordingSourceLabel({super.key, required this.source, this.padding = EdgeInsets.zero});

  final ConversationSource? source;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final String label;
    final IconData icon;
    switch (source) {
      case ConversationSource.phone:
        final phone = Theme.of(context).platform == TargetPlatform.iOS
            ? context.l10n.memoryProvenanceIphone
            : context.l10n.memoryThisPhone;
        label = '${context.l10n.microphone} · $phone';
        icon = Icons.mic_none_rounded;
      case ConversationSource.omi:
        label = context.l10n.omiAppName;
        icon = Icons.sensors_rounded;
      default:
        return const SizedBox.shrink();
    }
    return Padding(
      padding: padding,
      child: Row(
        key: const Key('recording_source_label'),
        children: [
          Icon(icon, size: 16, color: Colors.white70),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}
