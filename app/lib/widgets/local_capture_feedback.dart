import 'package:flutter/material.dart';

import 'package:omi/services/capture/local_capture_phase.dart';
import 'package:omi/utils/l10n_extensions.dart';

String localCaptureStatusText(BuildContext context, LocalCapturePhase phase) => switch (phase) {
      LocalCapturePhase.idle => context.l10n.localCaptureIdle,
      LocalCapturePhase.starting => context.l10n.preparingAudioCapture,
      LocalCapturePhase.waitingAudio => context.l10n.waitingForData,
      LocalCapturePhase.recording => context.l10n.recording,
      LocalCapturePhase.paused => context.l10n.paused,
      LocalCapturePhase.stopping => context.l10n.saving,
      LocalCapturePhase.failed => context.l10n.somethingWentWrong,
    };

/// Only displays events actually received from the device; never infers a press.
class LocalOmiButtonFeedback extends StatelessWidget {
  const LocalOmiButtonFeedback({super.key, required this.event});

  final OmiButtonEvent? event;

  @override
  Widget build(BuildContext context) {
    final event = this.event;
    if (event == null) return const SizedBox.shrink();
    final text = switch (event) {
      OmiButtonEvent.pressed => context.l10n.omiButtonPressed,
      OmiButtonEvent.released => context.l10n.omiButtonReleased,
      OmiButtonEvent.singleTap => context.l10n.omiButtonSingleTap,
      OmiButtonEvent.doubleTap => context.l10n.doubleTap,
      OmiButtonEvent.longPress => context.l10n.omiButtonLongPress,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        key: const Key('local_omi_button_feedback'),
        children: [
          Icon(event == OmiButtonEvent.pressed ? Icons.touch_app : Icons.check_circle_outline,
              size: 18, color: Colors.white70),
          const SizedBox(width: 8),
          Expanded(
              child: Text('${context.l10n.omiAppName} · $text',
                  style: const TextStyle(fontSize: 13, color: Colors.white70))),
        ],
      ),
    );
  }
}
