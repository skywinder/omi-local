import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/local_next/cv1_capture.dart';
import 'package:omi/local_next/cv1_transport.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

class _Radio implements Cv1Transport {
  final stream = StreamController<Cv1TransportEvent>(sync: true);
  final commands = <(int, int, bool)>[];
  final enabling = Completer<void>();

  @override
  Stream<Cv1TransportEvent> get events => stream.stream;

  @override
  Future<void> setAudio(int generation, int subscription, bool enabled) async {
    commands.add((generation, subscription, enabled));
    if (commands.length == 1) await enabling.future;
  }

  @override
  Future<void> scan() async {}

  @override
  Future<void> connect(String id) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> close() => stream.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Dart and the native bridge exchange generation and subscription on the same audio command', () async {
    const channel = MethodChannel('org.omilocal.next/cv1');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final received = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      received.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final transport = ChannelCv1Transport();
    await transport.scan();
    await transport.connect('example-device');
    await transport.setAudio(4, 7, true);
    await transport.setAudio(4, 7, false);
    await transport.disconnect();
    await transport.close();

    expect(received.map((call) => call.method), ['scan', 'connect', 'setAudio', 'setAudio', 'disconnect', 'close']);
    expect(received[1].arguments, {'id': 'example-device'});
    expect(received[2].arguments, {'generation': 4, 'subscription': 7, 'enabled': true});
    expect(received[3].arguments, {'generation': 4, 'subscription': 7, 'enabled': false});
  });

  test('raw bytes retain their CV1 header and retired audio cannot lack a subscription ID', () {
    final bytes = Uint8List.fromList([0xff, 0xff, 0, 0x08, 0]);
    final event = Cv1TransportEvent.fromMessage({'type': 'audio', 'generation': 4, 'subscription': 7, 'bytes': bytes});
    expect(event, isA<Cv1RawAudio>());
    final audio = event! as Cv1RawAudio;
    expect((audio.generation, audio.subscription, audio.bytes), (4, 7, bytes));
    expect(Cv1TransportEvent.fromMessage({'type': 'audio', 'generation': 4, 'bytes': bytes}), isNull);
    final rejected = Cv1TransportEvent.fromMessage({'type': 'state', 'phase': 'ready', 'generation': 5, 'codec': 1});
    expect((rejected! as Cv1TransportState).phase, Cv1LinkPhase.failed);
  });

  test('CV1 diagnostics reject invalid measurements and retire with the link generation', () async {
    final folder = await Directory.systemTemp.createTemp('next-cv1-diagnostics-');
    final journal = LocalAudioJournal(directory: folder, upload: (body, owner) async => <String, dynamic>{});
    final capture = NextCv1Capture(journal, 'fixture-owner', canStart: () => true);
    final radio = _Radio();
    final connection = Cv1Connection(radio, capture);
    try {
      radio.stream.add(const Cv1TransportState(Cv1LinkPhase.ready, 1, codec: 20));
      final first = Cv1TransportEvent.fromMessage({
        'type': 'diagnostics',
        'generation': 1,
        'values': {'battery': 75, 'rssi': -63, 'firmware': 'fixture-fw', 'led': 30, 'ledWritable': true},
      })!;
      radio.stream.add(first);
      expect(connection.diagnostics?.battery, 75);
      expect(connection.diagnostics?.ledWritable, isTrue);
      expect(connection.rssiHistory.single.value, -63);
      expect(connection.connectedAt, isNotNull);
      radio.stream.add(const Cv1TransportState(Cv1LinkPhase.reconnecting, 2));
      expect(connection.connectedAt, isNull);
      expect(connection.diagnostics, isNull);
      radio.stream.add(const Cv1TransportState(Cv1LinkPhase.ready, 3, codec: 21));
      radio.stream.add(first);
      expect(connection.diagnostics, isNull);
      final fresh = Cv1TransportEvent.fromMessage({
        'type': 'diagnostics',
        'generation': 3,
        'values': {'battery': 101, 'rssi': -73, 'gain': '4'},
      })!;
      radio.stream.add(fresh);
      expect(connection.diagnostics?.battery, isNull);
      expect(connection.diagnostics?.gain, isNull);
      expect(connection.rssiHistory.map((sample) => sample.value), [-63, -73]);
      expect(connection.reconnections, 1);
    } finally {
      await connection.close();
      connection.dispose();
      await capture.close();
      capture.dispose();
      journal.dispose();
      await folder.delete(recursive: true);
    }
  });

  test('CV1 history retains real charge and link events across launches without retaining signal samples', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var now = DateTime.utc(2026, 11, 25);
    final history = Cv1History(preferences: prefs, now: () => now);
    history.beginLink();
    history.measureBattery(80);
    history.measureSignal(-69);
    now = now.add(const Duration(seconds: 10));
    history.measureBattery(80);
    history.addEvent((
      at: now,
      phase: Cv1LinkPhase.reconnecting,
      reason: Cv1LinkReason.dropped,
      code: 8,
      battery: 80,
      rssi: -69,
      uptime: const Duration(seconds: 10),
      downtime: null,
    ));
    now = now.add(const Duration(seconds: 8));
    history.beginLink();
    history.measureBattery(80);
    await history.flush();

    final restored = Cv1History(preferences: prefs, now: () => now);
    expect(restored.battery.map((sample) => sample.value), [80, 80]);
    expect(restored.battery.map((sample) => sample.series).toSet(), hasLength(2));
    expect(restored.events.single.rssi, -69);
    expect(restored.events.single.code, 8);
    expect(restored.signal, isEmpty);
    expect(restored.exportLog(), contains('"reason": "dropped"'));
    now = now.add(const Duration(days: 8));
    final expired = Cv1History(preferences: prefs, now: () => now);
    expect(expired.battery, isEmpty);
    expect(expired.events, isEmpty);
  });

  test('Stop and Start while enabling supersede the subscription, even on the same link', () async {
    final folder = await Directory.systemTemp.createTemp('next-cv1-radio-');
    final journal = LocalAudioJournal(directory: folder, upload: (body, owner) async => throw StateError('offline'));
    await journal.initialize();
    final capture = NextCv1Capture(journal, 'fixture-owner', canStart: () => true);
    final radio = _Radio();
    final connection = Cv1Connection(radio, capture);
    try {
      radio.stream.add(const Cv1TransportState(Cv1LinkPhase.ready, 1, codec: 21));
      await Future<void>.sync(capture.start);
      await Future<void>.delayed(Duration.zero);
      final first = radio.commands.single.$2;
      await capture.stop();
      await Future<void>.sync(capture.start);
      radio.enabling.complete();
      await Future<void>.delayed(Duration.zero);
      final second = radio.commands.last.$2;
      expect(second, isNot(first));
      expect(radio.commands, [(1, first, true), (1, first, false), (1, second, true)]);

      // 0x08 is a 20 ms Opus packet type. A second counter-contiguous start
      // would normally confirm the first frame for the journal.
      final packet1 = Uint8List.fromList([0, 0, 0, 0x08, 0x11]);
      final packet2 = Uint8List.fromList([1, 0, 0, 0x08, 0x22]);
      radio.stream.add(Cv1RawAudio(1, first, packet1));
      radio.stream.add(Cv1RawAudio(1, first, packet2));
      await journal.flushPendingWrites();
      expect(capture.hasPersistedAudio, isFalse);

      radio.stream.add(Cv1RawAudio(1, second, packet1));
      radio.stream.add(Cv1RawAudio(1, second, packet2));
      await journal.flushPendingWrites();
      expect(capture.hasPersistedAudio, isTrue);
    } finally {
      await connection.close();
      await capture.close();
      connection.dispose();
      capture.dispose();
      await journal.drain();
      journal.dispose();
      await folder.delete(recursive: true);
    }
  });
}
