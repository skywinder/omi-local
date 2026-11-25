import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/capture.dart';
import 'package:omi/local_next/capture_panel.dart';
import 'package:omi/local_next/cv1_capture.dart';
import 'package:omi/local_next/cv1_transport.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/live_preview.dart';
import 'package:omi/local_next/device_diagnostics_page.dart';
import 'package:omi/services/capture/local_audio_journal.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Wire extends Stream<Cv1TransportEvent> implements Cv1Transport, Cv1DiagnosticsTransport {
  void Function(Cv1TransportEvent)? _listener;
  final subscriptions = <bool>[];
  int generation = 1;
  int signalReads = 0;

  @override
  Future<void> sampleSignal() async => signalReads++;

  @override
  Future<void> sampleDiagnostics() async {}

  @override
  Future<void> writeSetting(int generation, String field, int value) async {}

  String? selected;
  bool rejectConnection = false;
  List<Cv1DeviceFound> nearby = const [Cv1DeviceFound('fixture', 'Studio CV1')];

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
    for (final device in nearby) {
      emit(device);
    }
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
  _Journal({super.clock})
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
  final audioSession = StreamController<bool>.broadcast(sync: true);

  @override
  Stream<bool> get interruptions => audioSession.stream;

  bool recording = false;
  @override
  Future<void> start(void Function(Uint8List) onSamples, void Function() onFailure) async => recording = true;
  @override
  Future<void> stop() async => recording = false;
}

void main() {
  testWidgets('device diagnostics show real samples, hide unsupported writes and clear a lost link', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final journal = LocalAudioJournal(
      directory: Directory('unused-device-diagnostics'),
      upload: (body, owner) async => <String, dynamic>{},
    );
    final capture = NextCv1Capture(journal, 'fixture-owner', canStart: () => true);
    final radio = _Wire();
    final connection = Cv1Connection(radio, capture);
    final busy = ValueNotifier(false);
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: NextDeviceDiagnosticsPage(link: connection, capture: busy, captureBusy: () => busy.value),
        ),
      );
      expect(find.textContaining('Connect an Omi CV1'), findsOneWidget);
      radio.emit(const Cv1TransportState(Cv1LinkPhase.ready, 1, codec: 20));
      radio.emit(
        const Cv1DiagnosticsEvent(
          1,
          Cv1Diagnostics(battery: 72, rssi: -66, firmware: 'fixture firmware', led: 30, ledWritable: true),
        ),
      );
      await tester.pump();
      expect(find.text('72%'), findsWidgets);
      expect(find.text('-66 dBm'), findsWidgets);
      expect(find.textContaining('Good ·'), findsOneWidget);
      expect(find.text('Battery history'), findsOneWidget);
      await tester.tap(find.text('Week'));
      await tester.pump();
      await tester.tap(find.text('Device Information'));
      await tester.pumpAndSettle();
      expect(find.text('fixture firmware'), findsOneWidget);
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'LED Brightness')).onTap, isNotNull);
      expect(find.text('Mic Gain'), findsNothing);
      busy.value = true;
      final reads = radio.signalReads;
      await tester.pump(const Duration(seconds: 3));
      expect(radio.signalReads, greaterThan(reads));
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'LED Brightness')).onTap, isNull);
      radio.emit(const Cv1TransportState(Cv1LinkPhase.reconnecting, 2, reason: Cv1LinkReason.dropped, code: 8));
      await tester.pump();
      expect(find.text('Bluetooth connection lost'), findsOneWidget);
      expect(find.textContaining('BLE 8'), findsOneWidget);
      expect(find.textContaining('-66 dBm'), findsWidgets);
      expect(find.text('fixture firmware'), findsNothing);
      expect(find.text('LED Brightness'), findsNothing);
      expect(find.textContaining('Connect an Omi CV1'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      final closing = connection.close();
      await tester.pump();
      await closing;
      connection.dispose();
      final stopped = capture.close();
      await tester.pump();
      await stopped;
      capture.dispose();
      journal.dispose();
      busy.dispose();
    }
  });

  testWidgets('CV1 elapsed time and mute stay available in Live, and silence saves for the next recording', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var now = DateTime.utc(2026);
    final journal = _Journal(clock: () => now);
    final mic = _Microphone();
    final wire = _Wire();
    final pair = PairedLibrary('100.64.0.1', 'A' * 43)..conversationGroups = true;
    final preview = NextLivePreview('fixture', (owner, source, codec) async => throw const SocketException('offline'));
    final inputs = NextCaptureInputs(NextPhoneCapture(journal, 'fixture', mic, preview: preview), wire);
    final changes = <int?>[];
    final boundary = ValueNotifier<int?>(null);
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: LocalNextCaptureControls(
              inputs: inputs,
              library: pair,
              groupSilence: boundary,
              onGroupSilence: (value) async {
                changes.add(value);
                boundary.value = value;
                return true;
              },
            ),
          ),
        ),
      );
      wire.ready();
      await inputs.startCv1();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('next-live-strip')));
      await tester.pumpAndSettle();
      expect(find.text('CV1 · 00:00'), findsOneWidget);
      now = now.add(const Duration(seconds: 7));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('CV1 · 00:07'), findsOneWidget);
      await tester.tap(find.byTooltip('Mute'));
      await tester.pumpAndSettle();
      expect(inputs.cv1.intent, Cv1CaptureIntent.muted);
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pumpAndSettle();
      expect(inputs.cv1.intent, Cv1CaptureIntent.recording);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Conversation boundaries'), findsOneWidget);
      expect(find.textContaining('Applies to the next recording.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('next-recording-boundaries')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Split after silence · 30s'));
      await tester.pumpAndSettle();
      expect(changes, [30]);
      expect(find.textContaining('Split after silence · 30s'), findsOneWidget);
      expect(inputs.cv1.intent, Cv1CaptureIntent.recording);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(inputs.cv1.active, isFalse);
    } finally {
      journal.seal.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      await inputs.close();
      inputs.dispose();
      pair.close();
      journal.dispose();
      boundary.dispose();
      await mic.audioSession.close();
    }
  });

  testWidgets('Bluetooth shares the capture row and identifies identically named pendants', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final journal = _Journal();
    final wire = _Wire()
      ..nearby = const [
        Cv1DeviceFound('AA:BB:CC:00:00:01', 'Omi'),
        Cv1DeviceFound('AA:BB:CC:00:00:02', 'Omi'),
        Cv1DeviceFound('12345678-1234-1234-1234-5A6B7C8D9E0F', 'Omi'),
      ];
    final inputs = NextCaptureInputs(NextPhoneCapture(journal, 'fixture', _Microphone()), wire);
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: LocalNextCaptureControls(inputs: inputs)),
        ),
      );
      final phone = find.byKey(const ValueKey('next-phone-capture'));
      final bluetooth = find.byKey(const ValueKey('next-cv1-devices'));
      final record = find.byKey(const ValueKey('next-cv1-capture'));
      expect(find.text('Connect Omi'), findsOneWidget);
      expect(tester.getRect(phone).top, tester.getRect(bluetooth).top);
      await tester.tap(bluetooth);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Device ID · 000001'), findsOneWidget);
      final second = find.widgetWithText(ListTile, 'Device ID · 000002');
      expect(second, findsOneWidget);
      final peripheralUuid = find.text('Device ID · 5A6B7C');
      await tester.scrollUntilVisible(peripheralUuid, 90, scrollable: find.byType(Scrollable));
      expect(peripheralUuid, findsOneWidget);
      await tester.ensureVisible(second);
      await tester.tap(second);
      await tester.pumpAndSettle();
      expect(wire.selected, 'AA:BB:CC:00:00:02');
      expect(tester.getRect(record).top, tester.getRect(bluetooth).top);
      expect(tester.getRect(record).bottom, tester.getRect(bluetooth).bottom);
      expect(tester.getRect(record).right, lessThan(tester.getRect(bluetooth).left));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      final closing = inputs.close();
      await tester.pump();
      await closing;
      inputs.dispose();
      journal.dispose();
    }
  });

  testWidgets('the device menu shows the ID restored from a persisted Bluetooth link', (tester) async {
    final journal = _Journal();
    final wire = _Wire();
    final inputs = NextCaptureInputs(NextPhoneCapture(journal, 'fixture', _Microphone()), wire);
    try {
      wire.emit(
        Cv1TransportEvent.fromMessage({
          'type': 'state',
          'phase': 'ready',
          'generation': 1,
          'codec': 20,
          'deviceId': '12345678-1234-1234-1234-5A6B7C8D9E0F',
        })!,
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: LocalNextCaptureControls(inputs: inputs)),
        ),
      );
      expect(wire.selected, isNull);
      await tester.tap(find.byKey(const ValueKey('next-cv1-devices')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Device ID · 5A6B7C'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      final closing = inputs.close();
      await tester.pump();
      await closing;
      inputs.dispose();
      journal.dispose();
    }
  });

  testWidgets('a paired CV1 waits for the phone seal, respects mute and leaves phone recording on reconnect', (
    tester,
  ) async {
    var now = DateTime.utc(2026);
    final journal = _Journal(clock: () => now);
    final mic = _Microphone();
    final wire = _Wire();
    final ownerChange = NextOwnerChangeGate();
    final inputs = NextCaptureInputs(
      NextPhoneCapture(journal, 'fixture', mic),
      wire,
      ownerChange: ownerChange,
      doubleTapAction: () => Cv1DoubleTapAction.stop,
    );
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
      expect(find.text('Phone microphone · 00:00'), findsOneWidget);
      now = now.add(const Duration(seconds: 9));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Phone microphone · 00:09'), findsOneWidget);
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
      wire.emit(Cv1DiagnosticsEvent(wire.generation, const Cv1Diagnostics(battery: 75)));
      await tester.pump();
      expect(find.text('CV1 · 75%'), findsOneWidget);
      expect(find.text('CV1 · Connected'), findsNothing);
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
      wire.emit(Cv1DiagnosticsEvent(wire.generation, const Cv1Diagnostics(battery: 0)));
      await tester.pump();
      expect(find.text('CV1 · 0% · Muted'), findsOneWidget);
      expect(wire.subscriptions, [true, false]);
      expect(ownerChange.tryHold(), isFalse, reason: 'mute keeps the current capture owner');
      wire.reconnect();
      await tester.pumpAndSettle();
      expect(find.text('CV1 · Connected · Muted'), findsOneWidget);
      expect(wire.subscriptions, [true, false]);
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pumpAndSettle();
      expect(wire.subscriptions.last, isTrue);
      wire.emit(Cv1RawButton(wire.generation, 2));
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
      await mic.audioSession.close();
      ownerChange.dispose();
      journal.dispose();
    }
  });
}
