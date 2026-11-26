import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/capture.dart';
import 'package:omi/local_next/capture_panel.dart';
import 'package:omi/local_next/cv1_capture.dart';
import 'package:omi/local_next/cv1_gain_calibration.dart';
import 'package:omi/local_next/cv1_gain_calibration_card.dart';
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
  final writes = <(String, int)>[];

  @override
  Future<void> sampleSignal() async => signalReads++;

  @override
  Future<void> sampleDiagnostics() async {}

  @override
  Future<void> writeSetting(int generation, String field, int value) async => writes.add((field, value));

  String? selected;
  bool rejectConnection = false;
  bool delayedConnection = false;
  int attempts = 0;
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
    attempts++;
    if (delayedConnection) {
      emit(Cv1TransportState(Cv1LinkPhase.connecting, generation));
    } else {
      ready();
    }
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

Widget _controlsScaffold(NextCaptureInputs inputs) => Scaffold(
  appBar: AppBar(
    title: Cv1HeaderTitle(title: 'Conversations', link: inputs.connection),
    actions: [
      Builder(
        builder: (context) =>
            IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => showNextDevices(context, inputs)),
      ),
    ],
  ),
  body: LocalNextCaptureControls(inputs: inputs),
);

class _Journal extends LocalAudioJournal {
  _Journal({super.clock})
    : super(directory: Directory('unused-panel-fixture'), upload: (bytes, owner) => throw StateError('no upload'));
  Set<LocalDeliveryIssue> issues = {};
  @override
  Set<LocalDeliveryIssue> get deliveryIssues => issues;
  void showIssue(LocalDeliveryIssue? value) {
    issues = {if (value != null) value};
    notifyListeners();
  }

  final seal = Completer<void>();
  int recordings = 0;
  @override
  LocalAudioRecording beginForServer({required String source, required String codec, required String serverId}) {
    recordings++;
    return _Recording(seal.future);
  }
}

class _Recording extends Fake implements LocalAudioRecording {
  _Recording(this.sealed);
  final Future<void> sealed;
  @override
  double get audioSeconds => 1;
  @override
  Future<void> add(List<int> payload, {void Function()? afterPersisted}) async => afterPersisted?.call();
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

class _GainDecoder implements Cv1GainDecoder {
  int sample = 120;
  bool closed = false;

  @override
  Int16List decode(Uint8List packet) => Int16List.fromList(List.filled(320, sample));

  @override
  void close() => closed = true;
}

void main() {
  testWidgets('CV1 calibration measures speech locally and releases audio on failure and finish', (tester) async {
    final journal = _Journal();
    final wire = _Wire();
    final inputs = NextCaptureInputs(NextPhoneCapture(journal, 'fixture', _Microphone()), wire);
    final link = inputs.connection;
    final decoders = <_GainDecoder>[];
    final requestedGains = <int>[];
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: Cv1GainCalibrationCard(
                link: link,
                gain: 6,
                busy: () => inputs.hasCaptureInProgress,
                changeGain: requestedGains.add,
                openDecoder: () async {
                  final decoder = _GainDecoder();
                  decoders.add(decoder);
                  return decoder;
                },
              ),
            ),
          ),
        ),
      );
      wire.ready();
      final start = find.text('Test CV1 microphone');
      await tester.tap(start);
      await tester.pump();
      expect(link.calibrating, isTrue);
      expect(wire.subscriptions, [true]);
      await tester.pump(const Duration(seconds: 8));
      expect(find.textContaining('No audio reached'), findsOneWidget);
      expect(wire.subscriptions, [true, false]);
      expect(decoders.first.closed, isTrue);

      await tester.tap(start);
      await tester.pump();
      wire.emit(const Cv1RawButton(1, 1));
      await inputs.startCv1();
      await inputs.togglePhone();
      expect(inputs.isRecording, isFalse);
      void packet(int counter, int subscription) =>
          wire.emit(Cv1RawAudio(1, subscription, Uint8List.fromList([counter & 255, counter >> 8, 0, 0xf8])));
      packet(0, 1);
      packet(1, 1);
      await tester.pump();
      expect(find.textContaining('Waiting for audio'), findsOneWidget);
      decoders.last.sample = 32767;
      packet(0, 2);
      packet(1, 2);
      await tester.pump(const Duration(seconds: 1));
      decoders.last.sample = 120;
      for (var counter = 2; counter <= 101; counter++) {
        packet(counter, 2);
      }
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('make a short sound near the CV1 during the countdown'), findsOneWidget);
      // Waiting and preparing the speaker must not enter either measurement.
      decoders.last.sample = 32767;
      packet(102, 2);
      await tester.pump(const Duration(seconds: 9));
      expect(link.calibrating, isTrue);
      await tester.tap(find.text('Start speech countdown'));
      await tester.pump();
      expect(find.text('Start speaking in · 3'), findsOneWidget);
      expect(find.text('Increase gain · 7/8'), findsNothing);
      packet(103, 2);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Speak or play the phrase now'), findsOneWidget);
      decoders.last.sample = 1000;
      for (var counter = 104; counter <= 353; counter++) {
        packet(counter, 2);
      }
      await tester.pump(const Duration(seconds: 5));
      expect(find.textContaining('The phrase was quiet'), findsOneWidget);
      expect(find.textContaining('Audio received · 5.0 / 5 s'), findsOneWidget);
      expect(find.textContaining('Speech above room level'), findsOneWidget);
      expect(find.textContaining('−∞'), findsNothing);
      expect(requestedGains, isEmpty);
      final suggestion = find.text('Apply suggested gain · 7/8 (+30dB)');
      await tester.ensureVisible(suggestion);
      await tester.tap(suggestion);
      expect(requestedGains, [7]);
      expect(link.calibrating, isFalse);
      expect(journal.recordings, 0);
      expect(decoders.every((decoder) => decoder.closed), isTrue);

      final playback = find.text('Test quiet playback');
      await tester.tap(playback);
      await tester.pump();
      expect(find.text('Stay quiet until playback · 12'), findsOneWidget);
      packet(0, 3);
      packet(1, 3);
      await tester.pump(const Duration(seconds: 12));
      expect(find.text('Play the phrase now at the same volume and distance'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      packet(2, 3);
      packet(3, 3);
      await tester.pump(const Duration(seconds: 4));
      expect(find.textContaining('First CV1 audio after the playback cue · ~1.0 s'), findsOneWidget);
      expect(find.textContaining('still streaming just before playback'), findsNothing);
      expect(link.calibrating, isFalse);

      final warm = find.text('Repeat after waking CV1');
      Future<void> startWarm() async {
        await tester.ensureVisible(warm);
        await tester.tap(warm);
        await tester.pump();
        expect(find.textContaining('The countdown starts when audio arrives'), findsOneWidget);
      }

      await startWarm();
      await tester.pump(const Duration(seconds: 4));
      expect(find.textContaining('The countdown starts when audio arrives'), findsOneWidget);
      expect(find.text('Play the phrase now at the same volume and distance'), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      expect(find.textContaining('CV1 sent no audio after the wake attempt'), findsOneWidget);
      expect(find.text('Playback after silence · 6 / 8'), findsOneWidget);
      expect(link.calibrating, isFalse);

      await startWarm();
      packet(0, 5);
      packet(1, 5);
      await tester.pump();
      expect(find.text('CV1 audio received. Get ready to play · 2'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      for (var counter = 0; counter < 250; counter++) {
        packet(counter + 2, 5);
      }
      await tester.pump(const Duration(seconds: 5));
      expect(find.textContaining('CV1 audio was absent just before'), findsOneWidget);
      expect(find.textContaining('More audio arrived'), findsNothing);

      await startWarm();
      await tester.pump(const Duration(seconds: 3));
      packet(0, 6);
      packet(1, 6);
      await tester.pump(const Duration(milliseconds: 1250));
      expect(find.text('CV1 audio received. Get ready to play · 1'), findsOneWidget);
      packet(2, 6);
      await tester.pump(const Duration(milliseconds: 750));
      expect(find.text('Play the phrase now at the same volume and distance'), findsOneWidget);
      for (var counter = 3; counter < 253; counter++) {
        packet(counter, 6);
      }
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Playback after silence · 6 / 8'), findsOneWidget);
      expect(find.text('Playback after waking CV1 · 6 / 8'), findsOneWidget);
      expect(find.textContaining('More audio arrived after waking CV1 at the same gain'), findsOneWidget);
      expect(find.textContaining('Playback signal'), findsNWidgets(2));

      await tester.ensureVisible(playback);
      await tester.tap(playback);
      await tester.pump();
      await tester.pump(const Duration(seconds: 11));
      packet(0, 7);
      packet(1, 7);
      await tester.pump(const Duration(seconds: 6));
      expect(find.textContaining('still streaming just before playback'), findsOneWidget);
      expect(find.textContaining('No CV1 audio arrived during playback'), findsOneWidget);
      expect(find.textContaining('First CV1 audio'), findsNothing);
      expect(find.textContaining('More audio arrived'), findsNothing);
      expect(journal.recordings, 0);

      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pump();
      wire.reconnect();
      await tester.pump();
      expect(find.textContaining('CV1 disconnected during'), findsOneWidget);
      expect(link.calibrating, isFalse);
      expect(decoders.last.closed, isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await inputs.close();
      inputs.dispose();
      journal.dispose();
    }
  });

  testWidgets('CV1 calibration compares measured speech with room gain and can restore the earlier level', (
    tester,
  ) async {
    final journal = _Journal();
    final wire = _Wire();
    final inputs = NextCaptureInputs(NextPhoneCapture(journal, 'fixture', _Microphone()), wire);
    late _GainDecoder decoder;
    var gain = 6;
    var subscription = 0;
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) => Cv1GainCalibrationCard(
                  link: inputs.connection,
                  gain: gain,
                  busy: () => inputs.hasCaptureInProgress,
                  changeGain: (value) => setState(() => gain = value),
                  openDecoder: () async => decoder = _GainDecoder(),
                ),
              ),
            ),
          ),
        ),
      );
      wire.ready();

      Future<void> tap(String text) async {
        final control = find.text(text);
        await tester.ensureVisible(control);
        await tester.tap(control);
        await tester.pump();
      }

      Future<void> measure(String start, {required int room, required int speech}) async {
        await tap(start);
        subscription++;
        var counter = 0;
        void send(int count, int level) {
          decoder.sample = level;
          for (var i = 0; i < count; i++, counter++) {
            wire.emit(Cv1RawAudio(1, subscription, Uint8List.fromList([counter & 255, counter >> 8, 0, 0xf8])));
          }
        }

        send(2, room);
        await tester.pump(const Duration(seconds: 1));
        send(100, room);
        await tester.pump(const Duration(seconds: 2));
        await tap('Start speech countdown');
        await tester.pump(const Duration(seconds: 3));
        send(250, speech);
        await tester.pump(const Duration(seconds: 5));
      }

      await measure('Test CV1 microphone', room: 120, speech: 1000);
      await tap('Apply suggested gain · 7/8 (+30dB)');
      await measure('Repeat microphone test · 7/8', room: 240, speech: 2000);
      expect(find.text('Compare microphone tests · 6/8 → 7/8'), findsOneWidget);
      expect(
        find.textContaining('Speech level · +6.0 dB\nRoom level · +6.0 dB\nSpeech above room level · 0.0 dB'),
        findsOneWidget,
      );
      expect(find.textContaining('Try keeping the lower setting'), findsOneWidget);
      await tap('Return to previous gain · 6/8');
      expect(gain, 6);
      await tap('Repeat microphone test · 6/8');
      await tester.pump(const Duration(seconds: 8));
      expect(find.textContaining('Compare microphone tests'), findsNothing);
      expect(journal.recordings, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await inputs.close();
      inputs.dispose();
      journal.dispose();
    }
  });

  testWidgets('the live CV1 battery opens microphone diagnostics and clears between connections', (tester) async {
    final journal = _Journal();
    final wire = _Wire();
    final inputs = NextCaptureInputs(NextPhoneCapture(journal, 'fixture', _Microphone()), wire);
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            appBar: AppBar(
              title: Builder(
                builder: (context) => Cv1HeaderTitle(
                  title: 'Archive',
                  link: inputs.connection,
                  openDevices: () => unawaited(showNextDevices(context, inputs)),
                ),
              ),
            ),
          ),
        ),
      );
      wire.ready();
      await tester.pump();
      expect(find.byIcon(Icons.battery_unknown), findsOneWidget);
      wire.emit(Cv1DiagnosticsEvent(wire.generation, const Cv1Diagnostics(battery: 97, gain: 6, gainWritable: true)));
      await tester.pump();
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('97%')), findsOneWidget);
      await tester.tap(find.text('97%'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Microphone and gain'));
      await tester.pumpAndSettle();
      expect(find.text('Test CV1 microphone'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      wire.emit(Cv1TransportState(Cv1LinkPhase.idle, ++wire.generation));
      await tester.pump();
      expect(find.text('97%'), findsNothing);
      wire.ready();
      await tester.pump();
      expect(find.byIcon(Icons.battery_unknown), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await inputs.close();
      inputs.dispose();
      journal.dispose();
    }
  });

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
    var now = DateTime.utc(2026, 11, 26);
    final connection = Cv1Connection(radio, capture, history: Cv1History(now: () => now));
    final busy = ValueNotifier(false);
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: NextDeviceDiagnosticsPage(
            link: connection,
            capture: Listenable.merge([capture, busy]),
            captureBusy: () => busy.value,
          ),
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
      radio.emit(
        const Cv1DiagnosticsEvent(
          1,
          Cv1Diagnostics(
            gain: 6,
            gainWritable: true,
            led: 30,
            ledWritable: true,
            rssi: -66,
            firmware: 'fixture firmware',
          ),
        ),
      );
      await tester.pump();
      expect(find.text('+20dB'), findsOneWidget);
      await tester.tap(find.text('Mic Gain'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Decrease gain'));
      await tester.pump();
      expect(find.text('5 / 8'), findsOneWidget);
      expect(find.text('+10dB'), findsOneWidget);
      await tester.tap(find.text('High · Factory gain · 6/8'));
      await tester.pump();
      expect(find.text('6 / 8'), findsWidgets);
      await tester.tap(find.byTooltip('Decrease gain'));
      await tester.pump();
      expect(radio.writes, isEmpty);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(radio.writes, [('gain', 5)]);
      busy.value = true;
      final reads = radio.signalReads;
      await tester.pump(const Duration(seconds: 3));
      expect(radio.signalReads, greaterThan(reads));
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'LED Brightness')).onTap, isNull);
      expect(find.text('Transfer speed'), findsNothing);
      capture.start();
      await tester.pump();
      expect(find.text('Transfer speed'), findsOneWidget);
      now = now.add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      for (var i = 0; i < 30; i++) {
        // A notification with no start fragment still counts towards BLE traffic.
        final bytes = Uint8List(100)..[2] = 1;
        radio.emit(Cv1RawAudio(1, 1, bytes));
        radio.emit(Cv1RawAudio(0, 1, bytes));
        radio.emit(Cv1RawAudio(1, 2, bytes));
      }
      now = now.add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('8.0 kbps'), findsOneWidget);
      now = now.add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('0.0 kbps'), findsOneWidget);

      radio.emit(const Cv1TransportState(Cv1LinkPhase.reconnecting, 2, reason: Cv1LinkReason.dropped, code: 8));
      await tester.pump();
      expect(find.text('Bluetooth connection lost'), findsOneWidget);
      expect(find.textContaining('BLE 8'), findsOneWidget);
      expect(find.textContaining('-66 dBm'), findsWidgets);
      expect(find.text('fixture firmware'), findsNothing);
      expect(find.text('LED Brightness'), findsNothing);
      expect(find.text('Transfer speed'), findsNothing);
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
      expect(find.text('Finish conversation after silence'), findsOneWidget);
      expect(find.textContaining('Applies to the next recording.'), findsOneWidget);
      await tester.tap(find.text('Finish conversation after silence'));
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

  testWidgets('pairing waits for native readiness, retries a timeout once and shows the BLE code', (tester) async {
    final journal = _Journal();
    final wire = _Wire()..delayedConnection = true;
    final inputs = NextCaptureInputs(NextPhoneCapture(journal, 'fixture', _Microphone()), wire);
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: _controlsScaffold(inputs),
        ),
      );
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Studio CV1'));
      await tester.pumpAndSettle();
      expect(find.text('Studio CV1'), findsOneWidget);
      void timeout() =>
          wire.emit(Cv1TransportState(Cv1LinkPhase.failed, ++wire.generation, reason: Cv1LinkReason.timeout, code: 8));
      timeout();
      await tester.pump(const Duration(seconds: 2));
      expect(wire.attempts, 2);
      timeout();
      await tester.pump(const Duration(seconds: 3));
      expect(wire.attempts, 2);
      expect(find.textContaining('BLE 8. Keep the CV1 close'), findsOneWidget);
      await tester.tap(find.text('Studio CV1'));
      await tester.pump();
      wire.ready();
      await tester.pumpAndSettle();
      expect(find.text('Studio CV1'), findsNothing);
      expect(find.byIcon(Icons.battery_unknown), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await inputs.close();
      inputs.dispose();
      journal.dispose();
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
          home: _controlsScaffold(inputs),
        ),
      );
      final phone = find.byKey(const ValueKey('next-phone-capture'));
      final bluetooth = find.byIcon(Icons.settings_outlined);
      final record = find.byKey(const ValueKey('next-cv1-capture'));
      expect(find.byKey(const ValueKey('next-cv1-devices')), findsNothing);
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
      expect(tester.getRect(record).top, tester.getRect(phone).top);
      expect(tester.getRect(record).bottom, tester.getRect(phone).bottom);
      expect(tester.getRect(phone).right, lessThan(tester.getRect(record).left));
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
          home: _controlsScaffold(inputs),
        ),
      );
      expect(wire.selected, isNull);
      await tester.tap(find.byIcon(Icons.settings_outlined));
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

  testWidgets('a CV1 audio gap updates the capture indicator and new packets clear it without restarting', (
    tester,
  ) async {
    var now = DateTime.utc(2026);
    final journal = _Journal(clock: () => now);
    final wire = _Wire();
    final inputs = NextCaptureInputs(NextPhoneCapture(journal, 'fixture', _Microphone()), wire);
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: _controlsScaffold(inputs),
        ),
      );
      wire.ready();
      await inputs.startCv1();
      await tester.pump();
      expect(find.textContaining('Waiting for CV1 audio'), findsOneWidget);
      void packet(int counter) =>
          inputs.cv1.handle(Cv1Audio(wire.generation, Uint8List.fromList([counter, 0, 0, 0xf8, 0xff, 0xfe])));
      packet(0);
      packet(1);
      await tester.pump();
      expect(find.textContaining('Waiting for CV1 audio'), findsNothing);
      expect(find.byKey(const ValueKey('next-recording-time')), findsOneWidget);
      now = now.add(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 6));
      expect(find.textContaining('CV1 stopped sending audio'), findsOneWidget);

      expect(inputs.cv1.active, isTrue);
      packet(2);
      await tester.pump();
      expect(find.textContaining('CV1 stopped sending audio'), findsNothing);
      expect(find.byKey(const ValueKey('next-recording-time')), findsOneWidget);
      expect(wire.subscriptions, [true]);
    } finally {
      journal.seal.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      await inputs.close();
      inputs.dispose();
      journal.dispose();
    }
  });

  testWidgets('a paired CV1 waits for the phone seal, respects mute and leaves phone recording on reconnect', (
    tester,
  ) async {
    var now = DateTime.utc(2026);
    final journal = _Journal(clock: () => now)..pendingParts = 1;
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
        home: _controlsScaffold(inputs),
      ),
    );
    try {
      final phoneButton = find.byKey(const ValueKey('next-phone-capture'));
      final cv1Button = find.byKey(const ValueKey('next-cv1-capture'));
      await tester.tap(phoneButton);
      await tester.pumpAndSettle();
      expect(mic.recording, isTrue);
      final time = find.text('Phone microphone · 00:00');
      expect(time, findsOneWidget);
      final pending = find.byKey(const ValueKey('next-audio-on-phone'));
      expect(tester.getCenter(time).dy, closeTo(tester.getCenter(pending).dy, 1));
      await tester.tap(pending);
      await tester.pumpAndSettle();
      expect(find.textContaining('until the paired server confirms'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      journal.showIssue(LocalDeliveryIssue.receipt);
      await tester.pump();
      expect(find.text('Delivery paused'), findsOneWidget);
      await tester.tap(pending);
      await tester.pumpAndSettle();
      expect(find.textContaining('invalid audio receipt'), findsOneWidget);
      journal.showIssue(null);
      await tester.pump();
      expect(find.textContaining('invalid audio receipt'), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      now = now.add(const Duration(seconds: 9));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Phone microphone · 00:09'), findsOneWidget);
      expect(ownerChange.tryHold(), isFalse);
      await tester.tap(find.byIcon(Icons.settings_outlined));
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
      expect(find.byIcon(Icons.battery_unknown), findsOneWidget);
      wire.emit(Cv1DiagnosticsEvent(wire.generation, const Cv1Diagnostics(battery: 75)));
      await tester.pump();
      expect(find.text('75%'), findsOneWidget);
      expect(find.byIcon(Icons.battery_unknown), findsNothing);
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
      expect(find.textContaining('Waiting for CV1 audio'), findsOneWidget);

      await tester.tap(find.byTooltip('Mute'));
      await tester.pumpAndSettle();
      wire.emit(Cv1DiagnosticsEvent(wire.generation, const Cv1Diagnostics(battery: 0)));
      await tester.pump();
      expect(find.text('0%'), findsOneWidget);
      expect(find.byTooltip('Unmute'), findsOneWidget);
      expect(wire.subscriptions, [true, false]);
      expect(ownerChange.tryHold(), isFalse, reason: 'mute keeps the current capture owner');
      wire.reconnect();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Unmute'), findsOneWidget);
      expect(wire.subscriptions, [true, false]);
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pumpAndSettle();
      expect(wire.subscriptions.last, isTrue);
      wire.emit(Cv1RawButton(wire.generation, 2));
      await tester.pumpAndSettle();
      expect(inputs.cv1.active, isFalse);
      expect(wire.subscriptions.last, isFalse);
      expect(find.byIcon(Icons.battery_unknown), findsOneWidget);

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
