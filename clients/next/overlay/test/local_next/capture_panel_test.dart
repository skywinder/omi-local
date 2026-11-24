import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/capture.dart';
import 'package:omi/local_next/capture_panel.dart';
import 'package:omi/local_next/cv1_transport.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

class _Wire extends Stream<Cv1TransportEvent> implements Cv1Transport {
  void Function(Cv1TransportEvent)? _listener;
  final subscriptions = <bool>[];
  int generation = 1;
  String? selected;
  bool rejectConnection = false;

  @override
  Stream<Cv1TransportEvent> get events => this;
  @override
  StreamSubscription<Cv1TransportEvent> listen(
    void Function(Cv1TransportEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _listener = onData;
    return _Subscription(() => _listener = null);
  }

  void emit(Cv1TransportEvent event) => _listener?.call(event);
  @override
  Future<void> scan() async {
    emit(Cv1TransportState(Cv1LinkPhase.scanning, generation));
    emit(const Cv1DeviceFound('fixture', 'Studio CV1'));
  }

  @override
  Future<void> connect(String id) async {
    if (rejectConnection) throw StateError('private Bluetooth failure');
    selected = id;
    ready();
  }

  void ready() => emit(Cv1TransportState(Cv1LinkPhase.ready, generation, codec: 20));
  void reconnect() {
    emit(Cv1TransportState(Cv1LinkPhase.reconnecting, ++generation));
    ready();
  }

  @override
  Future<void> setAudio(int generation, int subscription, bool enabled) async => subscriptions.add(enabled);
  @override
  Future<void> disconnect() async => emit(Cv1TransportState(Cv1LinkPhase.idle, ++generation));
  @override
  Future<void> close() async {
    if (_listener != null) throw StateError('Closed before removing the listener');
  }
}

class _Subscription extends Fake implements StreamSubscription<Cv1TransportEvent> {
  _Subscription(this.onCancel);
  final VoidCallback onCancel;
  @override
  Future<void> cancel() async => onCancel();
}

class _Journal extends LocalAudioJournal {
  _Journal()
    : super(directory: Directory('unused-panel-fixture'), upload: (bytes, owner) => throw StateError('no upload'));
  final seal = Completer<void>();
  @override
  LocalAudioRecording beginForServer({required String source, required String codec, required String serverId}) =>
      _Recording(seal.future);
}

class _Recording extends Fake implements LocalAudioRecording {
  _Recording(this.sealed);
  final Future<void> sealed;
  @override
  double get audioSeconds => 1;
  @override
  Future<void> stop() => sealed;
}

class _Microphone implements NextPhoneMicrophone {
  bool recording = false;
  @override
  Future<void> start(void Function(Uint8List) onSamples, void Function() onFailure) async => recording = true;
  @override
  Future<void> stop() async => recording = false;
}

void main() {
  testWidgets('a paired CV1 waits for the phone seal, respects mute and leaves phone recording on reconnect', (
    tester,
  ) async {
    final journal = _Journal();
    final mic = _Microphone();
    final wire = _Wire();
    final ownerChange = NextOwnerChangeGate();
    final inputs = NextCaptureInputs(NextPhoneCapture(journal, 'fixture', mic), wire, ownerChange: ownerChange);
    ownerChange.attachCapture(() => inputs.hasCaptureInProgress);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: LocalNextCaptureControls(inputs: inputs)),
      ),
    );
    try {
      final phoneButton = find.byKey(const ValueKey('next-phone-capture'));
      final cv1Button = find.byKey(const ValueKey('next-cv1-capture'));
      await tester.tap(phoneButton);
      await tester.pumpAndSettle();
      expect(mic.recording, isTrue);
      expect(ownerChange.tryHold(), isFalse);
      await tester.tap(find.byKey(const ValueKey('next-cv1-devices')));
      await tester.pumpAndSettle();
      wire.rejectConnection = true;
      await tester.tap(find.text('Studio CV1'));
      await tester.pumpAndSettle();
      expect(find.text('Studio CV1'), findsOneWidget);
      expect(find.text('Connection failed'), findsOneWidget);
      expect(find.textContaining('private Bluetooth failure'), findsNothing);
      expect(wire.selected, isNull);
      wire.rejectConnection = false;
      await tester.tap(find.text('Studio CV1'));
      await tester.pumpAndSettle();
      expect(wire.selected, 'fixture');
      expect(find.text('CV1 · Connected'), findsOneWidget);
      expect(mic.recording, isTrue);
      expect(wire.subscriptions, isEmpty);

      wire.emit(Cv1RawButton(wire.generation, 1));
      await tester.pump();
      expect(mic.recording, isFalse);
      expect(inputs.phone.active, isTrue, reason: 'the previous recording still owns its unsealed data');
      expect(ownerChange.tryHold(), isFalse);
      expect(wire.subscriptions, isEmpty);
      journal.seal.complete();
      await tester.pumpAndSettle();
      expect(inputs.phone.active, isFalse);
      expect(wire.subscriptions, [true]);
      expect(find.textContaining('Waiting for data'), findsOneWidget);

      await tester.tap(find.byTooltip('Mute'));
      await tester.pumpAndSettle();
      expect(wire.subscriptions, [true, false]);
      expect(ownerChange.tryHold(), isFalse, reason: 'mute keeps the current capture owner');
      wire.reconnect();
      await tester.pumpAndSettle();
      expect(find.text('CV1 · Connected · Muted'), findsOneWidget);
      expect(wire.subscriptions, [true, false]);
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pumpAndSettle();
      expect(wire.subscriptions.last, isTrue);
      await tester.tap(cv1Button);
      await tester.pumpAndSettle();
      expect(inputs.cv1.active, isFalse);
      expect(wire.subscriptions.last, isFalse);
      expect(find.text('CV1 · Connected'), findsOneWidget);

      expect(ownerChange.tryHold(), isTrue);
      await tester.pump();
      expect(tester.widget<OutlinedButton>(phoneButton).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(cv1Button).onPressed, isNull);
      await inputs.togglePhone();
      wire.emit(Cv1RawButton(wire.generation, 1));
      ownerChange.release();
      await tester.pumpAndSettle();
      expect(mic.recording, isFalse);
      expect(inputs.cv1.active, isFalse, reason: 'a button during the handover cannot start later');

      await tester.tap(cv1Button);
      await tester.pumpAndSettle();
      expect(wire.subscriptions.last, isTrue);
      await tester.tap(phoneButton);
      await tester.pumpAndSettle();
      final changes = wire.subscriptions.length;
      expect(wire.subscriptions.last, isFalse);
      wire.reconnect();
      await tester.pumpAndSettle();
      expect(mic.recording, isTrue);
      expect(inputs.cv1.active, isFalse);
      expect(wire.subscriptions.length, changes);
    } finally {
      if (!journal.seal.isCompleted) journal.seal.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      final closing = inputs.close().then((_) => closed = true);
      await tester.pump();
      expect(closed, isTrue);
      await closing;
      inputs.dispose();
      ownerChange.dispose();
      journal.dispose();
    }
  });
}
