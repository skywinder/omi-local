import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:omi/services/capture/local_audio_journal.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'capture.dart';
import 'paired_library.dart';

class LocalNextCapturePanel extends StatefulWidget {
  const LocalNextCapturePanel({required this.library, super.key});
  final PairedLibrary library;

  @override
  State<LocalNextCapturePanel> createState() => _CapturePanelState();
}

class _CapturePanelState extends State<LocalNextCapturePanel> {
  // Release the previous owner's microphone and journal before recovering files.
  static Future<void> _previousRelease = Future.value();
  late final Future<void> _setup;
  LocalAudioJournal? _journal;
  NextPhoneCapture? _capture;
  bool _storageFailed = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _setup = _initialize(widget.library, _previousRelease);
  }

  Future<void> _initialize(PairedLibrary library, Future<void> previous) async {
    try {
      await previous;
      if (_closed || !library.audioDelivery) return;
      final documents = await getApplicationDocumentsDirectory();
      if (_closed) return;
      final journal = _journal = LocalAudioJournal(
        directory: Directory('${documents.path}/outbox/${library.audioOwnerId}'),
        upload: (body, id) {
          if (_closed) throw StateError('Pairing closed');
          return library.uploadPart(body, id);
        },
      );
      await journal.initialize();
      if (_closed) return;
      WidgetsBinding.instance.addObserver(journal);
      _capture = NextPhoneCapture(journal, library.audioOwnerId, IosPhoneMicrophone());
      journal.retry();
    } catch (_) {
      _storageFailed = true;
    }
    if (!_closed) setState(() {});
  }

  @override
  void dispose() {
    _closed = true;
    _previousRelease = _release();
    super.dispose();
  }

  Future<void> _release() async {
    await _setup;
    final journal = _journal;
    if (journal == null) return;
    WidgetsBinding.instance.removeObserver(journal);
    try {
      await _capture?.stop();
      await journal.drain();
    } finally {
      _capture?.dispose();
      journal.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.library.audioDelivery) return const SizedBox.shrink();
    final l = context.l10n;
    final capture = _capture;
    if (capture == null) {
      return _storageFailed ? Text(l.couldNotStartRecording) : const SizedBox.shrink();
    }
    final journal = capture.journal;
    return ListenableBuilder(
      listenable: Listenable.merge([capture, journal]),
      builder: (context, _) => Column(
        children: [
          OutlinedButton.icon(
            onPressed: capture.busy ? null : () => capture.active ? capture.stop() : capture.start(),
            icon: Icon(capture.active ? Icons.stop : Icons.mic),
            label: Text(capture.active ? l.stop : l.recordWithPhoneMic),
          ),
          if (capture.problem != null)
            Text(switch (capture.problem!) {
              CaptureProblem.permission => l.onboardingMicrophoneRequired,
              CaptureProblem.microphone => l.captureRecordingError(l.microphone),
              CaptureProblem.storage => l.captureRecordingError(l.capturePhoneStorageFull),
              CaptureProblem.empty => l.onboardingActNoAudioPhone,
            }),
          if (journal.pendingParts > 0) Text(l.nPending(journal.pendingParts)),
          if (journal.deliveryFailed) TextButton(onPressed: journal.retry, child: Text(l.captureBannerRetrySync)),
        ],
      ),
    );
  }
}
