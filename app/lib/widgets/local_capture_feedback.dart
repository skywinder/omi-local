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

/// Brief result supplied by the controller after a button action completes.
class LocalOmiButtonFeedback extends StatelessWidget {
  const LocalOmiButtonFeedback({super.key, required this.action});

  final LocalOmiButtonAction? action;

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    if (action == null) return const SizedBox.shrink();
    final text = switch (action) {
      LocalOmiButtonAction.started => context.l10n.recordingStartedSuccessfully,
      LocalOmiButtonAction.stopped => context.l10n.localCaptureIdle,
      LocalOmiButtonAction.paused => context.l10n.recordingPaused,
      LocalOmiButtonAction.resumed => context.l10n.recording,
      LocalOmiButtonAction.starred => context.l10n.starred,
      LocalOmiButtonAction.unstarred => '${context.l10n.starred} · ${context.l10n.off}',
      LocalOmiButtonAction.processing => context.l10n.processing,
      LocalOmiButtonAction.failed => context.l10n.somethingWentWrong,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        key: const Key('local_omi_button_feedback'),
        children: [
          Icon(action == LocalOmiButtonAction.failed ? Icons.error_outline : Icons.check_circle_outline,
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
