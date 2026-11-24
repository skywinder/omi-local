import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:omi/services/capture/local_audio_journal.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'capture.dart';
import 'cv1_capture.dart';
import 'cv1_transport.dart';
import 'live_preview.dart';
import 'live_view.dart';
import 'paired_library.dart';
import 'processing.dart';
import 'processing_page.dart';

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
  NextCaptureInputs? _inputs;
  late final _processing = widget.library.processingClient(
    permitsActivation: () => !_closed && _inputs?.isRecording == false,
  );
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
      _inputs = NextCaptureInputs(
        NextPhoneCapture(
          journal,
          library.audioOwnerId,
          IosPhoneMicrophone(),
          preview: NextLivePreview(library.audioOwnerId, library.connectPreview),
        ),
        IosCv1Transport(),
      );
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
      await _inputs?.close();
      await journal.drain();
    } finally {
      _inputs?.dispose();
      journal.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.library.audioDelivery) return const SizedBox.shrink();
    final l = context.l10n;
    final inputs = _inputs;
    if (inputs == null) {
      return _storageFailed ? Text(l.couldNotStartRecording) : const SizedBox.shrink();
    }
    return LocalNextCaptureControls(
      inputs: inputs,
      serverLabel: widget.library.origin.authority,
      processing: _processing,
    );
  }
}

/// Both inputs share one journal. Only an explicit Start can take it from the other source.
class NextCaptureInputs extends ChangeNotifier {
  NextCaptureInputs(this.phone, Cv1Transport transport) {
    cv1 = NextCv1Capture(
      phone.journal,
      phone.owner,
      canStart: () => !_closed && !switching && !_phoneOwns && !phone.active && !phone.busy,
      onStartRequested: _claimCv1,
      preview: phone.preview,
    );
    connection = Cv1Connection(transport, cv1);
  }

  final NextPhoneCapture phone;
  late final NextCv1Capture cv1;
  late final Cv1Connection connection;
  bool _phoneOwns = false;
  bool _closed = false;
  Future<void>? _transition;
  bool get switching => _transition != null;
  bool get isRecording => phone.active || phone.busy || cv1.active;
  NextLivePreview? get preview => phone.preview;

  Future<void> _change(Future<void> Function() operation) {
    if (_closed || switching) return Future.value();
    final pending = _transition = Future<void>.microtask(operation).whenComplete(() {
      _transition = null;
      if (!_closed) notifyListeners();
    });
    notifyListeners();
    return pending;
  }

  Future<void> _claimCv1() => _change(() async {
    if (!cv1.linked || !cv1.codecSupported) return;
    final needsSeal = phone.active || phone.busy;
    if (needsSeal) await phone.stop();
    if (_closed || (needsSeal && phone.problem == CaptureProblem.storage)) return;
    _phoneOwns = false;
  });

  Future<void> startCv1() async {
    if (_closed || switching || !cv1.linked || !cv1.codecSupported) return;
    final generation = cv1.generation;
    await _claimCv1();
    if (!_closed && !_phoneOwns && cv1.generation == generation && cv1.codecSupported) cv1.start();
  }

  Future<void> togglePhone() => _change(() async {
    _phoneOwns = true;
    if (phone.active) {
      await phone.stop();
      return;
    }
    final needsSeal = cv1.active;
    await cv1.stop();
    if (_closed || (needsSeal && cv1.problem == Cv1CaptureProblem.storage)) return;
    await phone.start();
  });

  Future<void> stopRecording() async {
    await _transition;
    await _change(() async {
      if (phone.active || phone.busy) {
        await phone.stop();
      } else {
        await cv1.stop();
      }
    });
  }

  Future<void> close() async {
    _closed = true;
    try {
      await _transition;
    } finally {
      // Fence BLE delivery and both capture paths immediately, then wait for every seal.
      await Future.wait([connection.close(), cv1.close(), phone.stop()]);
    }
  }

  @override
  void dispose() {
    connection.dispose();
    cv1.dispose();
    phone.dispose();
    preview?.dispose();
    super.dispose();
  }
}

class LocalNextCaptureControls extends StatelessWidget {
  const LocalNextCaptureControls({required this.inputs, this.serverLabel = '', this.processing, super.key});
  final NextCaptureInputs inputs;
  final String serverLabel;
  final NextProcessingClient? processing;

  Future<void> _devices(BuildContext context) async {
    final connection = inputs.connection;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListenableBuilder(
          listenable: connection,
          builder: (context, _) {
            final l = context.l10n;
            final selected = connection.phase == Cv1LinkPhase.ready || connection.phase == Cv1LinkPhase.reconnecting;
            return ListView(
              shrinkWrap: true,
              children: [
                if (selected)
                  ListTile(
                    leading: const Icon(Icons.bluetooth_connected),
                    title: const Text('Omi CV1'),
                    trailing: TextButton(
                      onPressed: () async {
                        if (inputs._closed) return;
                        await inputs.cv1.stop();
                        if (inputs._closed) return;
                        await connection.disconnect();
                        if (context.mounted && !connection.operationFailed) Navigator.pop(context);
                      },
                      child: Text(l.forgetDevice),
                    ),
                  )
                else ...[
                  ListTile(
                    leading: const Icon(Icons.bluetooth_searching),
                    title: Text(l.connectDevice),
                    subtitle: connection.phase == Cv1LinkPhase.scanning ? Text(l.searchingForDevices) : null,
                    trailing: TextButton(onPressed: inputs._closed ? null : connection.scan, child: Text(l.scanAgain)),
                  ),
                  for (final device in connection.devices)
                    ListTile(
                      title: Text(device.name.trim().isEmpty ? 'Omi CV1' : device.name),
                      leading: const Icon(Icons.bluetooth),
                      onTap: () async {
                        if (inputs._closed) return;
                        await connection.connect(device.id);
                        if (context.mounted && !connection.operationFailed) Navigator.pop(context);
                      },
                    ),
                ],
                if (connection.operationFailed || connection.phase == Cv1LinkPhase.failed)
                  Padding(padding: const EdgeInsets.all(16), child: Text(l.connectionFailed)),
                if (connection.phase == Cv1LinkPhase.unavailable)
                  Padding(padding: const EdgeInsets.all(16), child: Text(l.bluetoothNeeded)),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final capture = inputs.phone;
    final cv1 = inputs.cv1;
    final link = inputs.connection;
    final captureState = Listenable.merge([inputs, capture, cv1]);
    final journal = capture.journal;
    final l = context.l10n;
    return ListenableBuilder(
      listenable: Listenable.merge([captureState, journal, link]),
      builder: (context, _) => Column(
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('next-phone-capture'),
                onPressed: inputs.switching || capture.busy ? null : inputs.togglePhone,
                icon: Icon(capture.active ? Icons.stop : Icons.mic),
                label: Text(capture.active ? '${l.stop} · ${l.phone}' : l.recordWithPhoneMic),
              ),
              if (cv1.linked || cv1.active)
                OutlinedButton.icon(
                  key: const ValueKey('next-cv1-capture'),
                  onPressed: inputs.switching || (!cv1.active && !cv1.codecSupported)
                      ? null
                      : cv1.active
                      ? cv1.stop
                      : inputs.startCv1,
                  icon: Icon(cv1.active ? Icons.stop : Icons.fiber_manual_record),
                  label: Text(cv1.active ? '${l.stop} · CV1' : '${l.recordWith} CV1'),
                ),
              if (cv1.active)
                IconButton(
                  tooltip: cv1.intent == Cv1CaptureIntent.muted ? l.unmute : l.mute,
                  icon: Icon(cv1.intent == Cv1CaptureIntent.muted ? Icons.mic_off : Icons.mic),
                  onPressed: inputs.switching ? null : cv1.toggleMute,
                ),
              if (inputs.preview case final preview?)
                LocalNextLiveButton(
                  preview: preview,
                  capture: captureState,
                  isRecording: () => inputs.isRecording,
                  isMuted: () => cv1.intent == Cv1CaptureIntent.muted,
                  onStop: inputs.stopRecording,
                  serverLabel: serverLabel,
                ),
              if (processing case final client?)
                IconButton(
                  tooltip: l.processing,
                  icon: const Icon(Icons.tune),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => LocalNextProcessingPage(
                        client: client,
                        serverLabel: serverLabel,
                        capture: captureState,
                        isRecording: () => inputs.isRecording,
                      ),
                    ),
                  ),
                ),
              TextButton.icon(
                key: const ValueKey('next-cv1-devices'),
                icon: Icon(cv1.linked ? Icons.bluetooth_connected : Icons.bluetooth),
                label: Text(cv1.linked || cv1.active ? l.device : l.connectDevice),
                onPressed: () {
                  if (link.phase == Cv1LinkPhase.idle || link.phase == Cv1LinkPhase.failed) {
                    unawaited(link.scan());
                  }
                  unawaited(_devices(context));
                },
              ),
            ],
          ),
          if (link.phase != Cv1LinkPhase.idle || cv1.active)
            Text(
              [
                'CV1',
                switch (link.phase) {
                  Cv1LinkPhase.idle => l.disconnected,
                  Cv1LinkPhase.unavailable => l.bluetoothNeeded,
                  Cv1LinkPhase.scanning => l.searchingForDevices,
                  Cv1LinkPhase.connecting => l.deviceConnecting,
                  Cv1LinkPhase.ready => l.connected,
                  Cv1LinkPhase.reconnecting => l.reconnecting,
                  Cv1LinkPhase.failed => l.connectionFailed,
                },
                if (cv1.intent == Cv1CaptureIntent.muted)
                  l.muted
                else if (cv1.active && cv1.linked)
                  cv1.hasPersistedAudio ? l.recording : l.waitingForData,
              ].join(' · '),
            ),
          if (cv1.problem != null)
            Text(switch (cv1.problem!) {
              Cv1CaptureProblem.unsupportedCodec => l.captureRecordingError(l.audioFormatLabel),
              Cv1CaptureProblem.storage => l.captureRecordingError(l.capturePhoneStorageFull),
              Cv1CaptureProblem.sourceSwitch => l.couldNotStartRecording,
            })
          else if (link.audioFailed)
            Text(l.captureRecordingError(l.bluetooth)),
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
