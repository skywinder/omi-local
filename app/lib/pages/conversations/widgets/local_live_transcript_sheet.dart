import 'package:flutter/material.dart';
import 'package:omi/pages/conversations/widgets/temporary_recording_controls.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/widgets/transcript.dart';

/// RAM-only local preview. Stop uses the same capture action as the home card.
class LocalLiveTranscriptSheet extends StatelessWidget {
  final CaptureProvider provider;

  const LocalLiveTranscriptSheet({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.85,
      child: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: provider,
          builder: (context, _) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(child: Text(context.l10n.liveTranscript, style: const TextStyle(fontSize: 18))),
                    IconButton(
                      key: const Key('local_live_transcript_close'),
                      tooltip: context.l10n.close,
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: provider.segments.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(context.l10n.waitingForTranscriptOrPhotos, textAlign: TextAlign.center),
                        ),
                      )
                    : TranscriptWidget(
                        key: ValueKey(provider.activeCaptureSessionId ?? 'local-live-preview'),
                        segments: provider.segments,
                        contentVersion: provider.segmentsPhotosVersion,
                        canDisplaySeconds: false,
                        followLatest: true,
                        bottomMargin: 16,
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TemporaryRecordingControls(provider: provider),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
