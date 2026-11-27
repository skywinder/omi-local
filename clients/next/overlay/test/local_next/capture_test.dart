import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:omi/local_next/capture.dart';
import 'package:omi/local_next/live_preview.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

class _Recorder implements FlutterSoundRecorder {
  final events = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #openRecorder) {
      events.add('open');
      return Future<FlutterSoundRecorder?>.value(this);
    }
    if (invocation.memberName == #startRecorder) {
      events.add('start');
      return Future<void>.value();
    }
    if (invocation.memberName == #closeRecorder) {
      events.add('close');
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class TestMic implements NextPhoneMicrophone {
  @override
  Stream<bool> get interruptions => audioSession.stream;
  final audioSession = StreamController<bool>.broadcast(sync: true);
  final recorders = <void Function(Uint8List)>[];
  Completer<void>? stopGate;

  void Function(Uint8List)? samples;
  bool denied = false;
  final stopped = Completer<void>();

  @override
  Future<void> start(void Function(Uint8List) onSamples, void Function() onFailure) async {
    if (denied) throw PhoneCaptureDenied();
    samples = onSamples;
    recorders.add(onSamples);
  }

  @override
  Future<void> stop({bool reopening = false}) async {
    samples = null;
    if (!stopped.isCompleted) stopped.complete();
    await stopGate?.future;
  }
}

class _Watchdog implements Timer {
  _Watchdog(this.callback);
  final void Function() callback;

  @override
  bool isActive = true;

  @override
  int tick = 0;

  @override
  void cancel() => isActive = false;

  void expire() {
    if (!isActive) return;
    cancel();
    tick++;
    callback();
  }
}

void main() {
  for (final isIOS in [true, false]) {
    test('only iOS restores playback after phone capture (iOS: $isIOS)', () async {
      final recorder = _Recorder();
      final microphone = FlutterPhoneMicrophone(
        requestPermission: () async => true,
        makeRecorder: () => recorder,
        isIOS: isIOS,
        isAndroid: false,
        configureSession: (configuration) async {
          recorder.events.add('configure');
          expect(configuration.avAudioSessionCategory, AVAudioSessionCategory.playback);
          expect(configuration.avAudioSessionCategoryOptions, isNull);
        },
      );
      await microphone.start((_) {}, () {});
      await microphone.stop();
      await microphone.stop();
      expect(recorder.events, ['open', 'start', 'close', if (isIOS) 'configure']);
    });
  }

  test('system interruption and lost PCM recover within the same durable recording', () async {
    final scratch = await Directory.systemTemp.createTemp();
    addTearDown(() => scratch.delete(recursive: true));
    final journal = LocalAudioJournal(directory: scratch, upload: (_, owner) async => {'stored': false});
    await journal.initialize();
    final mic = TestMic();
    final timers = <_Watchdog>[];
    final delays = <Duration>[];
    final capture = NextPhoneCapture(
      journal,
      'test',
      mic,
      makeTimer: (delay, callback) {
        delays.add(delay);
        final timer = _Watchdog(callback);
        timers.add(timer);
        return timer;
      },
    );
    addTearDown(() async {
      await capture.stop();
      capture.dispose();
      journal.dispose();
      await mic.audioSession.close();
    });

    await capture.start();
    expect(capture.micStatus, PhoneMicStatus.waiting);
    final startedAt = capture.startedAt;
    final first = Uint8List.fromList([1, 2, 3, 4]);
    final second = Uint8List.fromList([5, 6, 7, 8]);
    mic.recorders.single(first);
    expect(capture.micStatus, PhoneMicStatus.recording);
    mic.audioSession.add(true);
    expect(capture.micStatus, PhoneMicStatus.interrupted);
    timers.last.expire();
    mic.recorders.first(Uint8List.fromList([9, 9]));
    expect(mic.recorders, hasLength(1));
    mic.audioSession.add(false);
    expect(capture.micStatus, PhoneMicStatus.recovering);
    timers.last.expire();
    await pumpEventQueue();
    expect(mic.recorders, hasLength(2));
    mic.recorders.first(Uint8List.fromList([9, 9]));
    mic.recorders.last(second);
    expect(capture.micStatus, PhoneMicStatus.recording);
    expect(capture.startedAt, startedAt);
    timers.last.expire();
    await pumpEventQueue();
    expect(mic.recorders, hasLength(3));
    expect(delays.last, const Duration(seconds: 8));
    timers.last.expire();
    await pumpEventQueue();
    expect(mic.recorders, hasLength(4));
    expect(capture.active, isTrue);
    expect(capture.micStatus, PhoneMicStatus.recovering);
    expect(delays.last, const Duration(seconds: 16));
    mic.recorders.last(Uint8List.fromList([13, 14]));
    expect(delays.last, const Duration(seconds: 4));
    await capture.stop();
    expect(capture.problem, isNull);
    await journal.drain();
    final part = await scratch.listSync().whereType<File>().single.readAsBytes();
    final end = 12 + ByteData.sublistView(part).getUint32(8);
    final audio = ByteData.sublistView(part, end);
    expect(audio.getUint32(0), first.length);
    expect(audio.getUint32(8), second.length);
    expect(audio.getUint32(16), 2);
    expect(part.sublist(end + 4, end + 8), first);
    expect(part.sublist(end + 12, end + 16), second);
    expect(part.sublist(end + 20), [13, 14]);
  });

  test('phone intent survives a runtime close and explicit Stop clears it', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final scratch = await Directory.systemTemp.createTemp();
    addTearDown(() => scratch.delete(recursive: true));
    final journal = LocalAudioJournal(directory: scratch, upload: (_, owner) async => {'stored': false});
    await journal.initialize();
    final mic = TestMic();
    final first = NextPhoneCapture(journal, 'test', mic, preferences: prefs);
    await first.start();
    expect(first.resumeRequested, isTrue);
    await first.close();
    first.dispose();
    final reopened = NextPhoneCapture(journal, 'test', mic, preferences: prefs);
    expect(reopened.resumeRequested, isTrue);
    final other = NextPhoneCapture(journal, 'another server', mic, preferences: prefs);
    expect(other.resumeRequested, isFalse);
    other.dispose();
    await reopened.start();
    await reopened.stop();
    expect(reopened.resumeRequested, isFalse);
    reopened.dispose();
    journal.dispose();
    await mic.audioSession.close();
  });

  test('Stop while reopening wins over the watchdog and retires old callbacks', () async {
    final scratch = await Directory.systemTemp.createTemp();
    addTearDown(() => scratch.delete(recursive: true));
    final journal = LocalAudioJournal(directory: scratch, upload: (_, owner) async => {'stored': false});
    await journal.initialize();
    final mic = TestMic();
    late _Watchdog watchdog;
    final capture = NextPhoneCapture(journal, 'test', mic, makeTimer: (_, callback) => watchdog = _Watchdog(callback));
    await capture.start();
    mic.stopGate = Completer<void>();
    watchdog.expire();
    final stopped = capture.stop();
    mic.audioSession.add(false);
    mic.recorders.first(Uint8List.fromList([1, 2]));
    mic.stopGate!.complete();
    await stopped;
    expect(mic.recorders, hasLength(1));
    expect(capture.active, isFalse);
    expect(capture.problem, CaptureProblem.empty);
    expect(scratch.listSync(), isEmpty);
    capture.dispose();
    journal.dispose();
    await mic.audioSession.close();
  });

  test('PCM from microphone survives bad receipt and process restart until its exact part is acknowledged', () async {
    final scratch = await Directory.systemTemp.createTemp();
    addTearDown(() => scratch.delete(recursive: true));
    final id = LocalAudioJournal.serverIdentity('http://127.0.0.1:8080', 'synthetic');
    final journal = LocalAudioJournal(directory: scratch, upload: (body, owner) async => {'stored': true});
    await journal.initialize();
    final mic = TestMic();
    final capture = NextPhoneCapture(journal, id, mic);
    await capture.start();
    expect(capture.active, isTrue);
    final pcm = Uint8List.fromList(List.generate(6000, (i) => i % 250));
    mic.samples!(pcm);
    await capture.stop();
    await journal.drain();
    expect(capture.problem, isNull);
    final saved = scratch.listSync().whereType<File>().single;
    expect(saved.path, endsWith('.ready'));
    final durable = await saved.readAsBytes();
    capture.dispose();
    journal.dispose();

    final delivered = <Uint8List>[];
    final restarted = LocalAudioJournal(
      directory: scratch,
      upload: (body, owner) async {
        expect(owner, id);
        delivered.add(body);
        final fields = ByteData.sublistView(body);
        final end = 12 + fields.getUint32(8);
        final header = jsonDecode(utf8.decode(body.sublist(12, end)));
        expect(header['source'], 'phone');
        expect(header['codec'], 'pcm16');
        final decoded = <int>[];
        for (int offset = end; offset < body.length;) {
          final length = fields.getUint32(offset);
          offset += 4;
          decoded.addAll(body.sublist(offset, offset + length));
          offset += length;
        }
        expect(decoded, pcm);
        return {'stored': true, 'id': header['id'], 'sha256': sha256.convert(body).toString()};
      },
    );
    await restarted.initialize();
    await restarted.drain();
    expect(delivered.single, durable);
    expect(scratch.listSync(), isEmpty);
    restarted.dispose();
  });

  test('denied microphone access publishes no audio and exits recording', () async {
    final scratch = await Directory.systemTemp.createTemp();
    addTearDown(() => scratch.delete(recursive: true));
    final journal = LocalAudioJournal(
      directory: scratch,
      upload: (body, owner) async => throw StateError('unexpected upload'),
    );
    await journal.initialize();
    final mic = TestMic()..denied = true;
    final capture = NextPhoneCapture(journal, 'synthetic', mic);
    await capture.start();
    await capture.stop();
    expect(capture.active, isFalse);
    expect(capture.problem, CaptureProblem.permission);
    expect(scratch.listSync(), isEmpty);
    capture.dispose();
    journal.dispose();
  });

  test('a paired silence signal leaves phone capture running until explicit Stop', () async {
    final scratch = await Directory.systemTemp.createTemp();
    addTearDown(() => scratch.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final key = 'A' * 43;
    final received = Completer<({List<int> sent, List<int> stored})>();
    final uploaded = Completer<Uint8List>();
    final ready = Completer<void>();
    final closed = Completer<void>();
    final library = PairedLibrary('http://127.0.0.1:${server.port}', key);
    addTearDown(library.close);
    server.listen((request) async {
      final response = request.response;
      expect(request.headers.value(HttpHeaders.authorizationHeader), 'Bearer $key');
      switch (request.uri.path) {
        case '/v1/users/profile':
          response.write(
            jsonEncode({'uid': 'alice', 'local_audio_delivery_version': 2, 'local_conversation_group_version': 1}),
          );
        case '/v4/listen':
          expect(request.headers.value('x-omi-local-audio-outbox'), '1');
          expect(request.headers.value('x-omi-local-group-silence'), isNull);
          final group = request.headers.value('x-omi-local-recording-group');
          expect(group, isNull);
          expect(request.uri.queryParameters['source'], 'phone');
          expect(request.uri.queryParameters['codec'], 'pcm16');
          final socket = await WebSocketTransformer.upgrade(request);
          socket.listen((frame) {
            if (frame is List<int> && !received.isCompleted) {
              final part = scratch.listSync().whereType<File>().single.readAsBytesSync();
              received.complete((sent: frame, stored: part.sublist(part.length - frame.length)));
              socket.add(
                jsonEncode({
                  'type': 'service_status',
                  'provider': 'local_audio_group',
                  'status': 'flush_part',
                  'reason': group,
                }),
              );
            }
          }, onDone: closed.complete);
          return;
        case '/v1/local/audio/parts':
          final body = Uint8List.fromList(await request.expand((bytes) => bytes).toList());
          final end = 12 + ByteData.sublistView(body).getUint32(8);
          final header = jsonDecode(utf8.decode(body.sublist(12, end))) as Map;
          if (body.length > end) uploaded.complete(body);
          response.write(jsonEncode({'stored': true, 'id': header['id'], 'sha256': sha256.convert(body).toString()}));
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });

    final journal = LocalAudioJournal(directory: scratch, upload: library.uploadPart, groupSilence: () => 60);
    await journal.initialize();
    final preview = NextLivePreview(library.audioOwnerId, (owner, source, codec, {silence}) async {
      final socket = await library.connectPreview(owner, source, codec, silence: silence);
      ready.complete();
      return socket;
    });
    final mic = TestMic();
    final capture = NextPhoneCapture(journal, library.audioOwnerId, mic, preview: preview);
    try {
      await capture.start();
      await ready.future.timeout(const Duration(seconds: 5));
      await pumpEventQueue();
      final frame = Uint8List.fromList([10, 11, 12, 13]);
      mic.samples!(frame);
      final observed = await received.future.timeout(const Duration(seconds: 5));
      expect(observed.sent, frame);
      expect(observed.stored, frame);
      await pumpEventQueue();
      expect(capture.active, isTrue);
      expect(mic.stopped.isCompleted, isFalse);
      final next = Uint8List.fromList([14, 15, 16, 17]);
      mic.samples!(next);
      await capture.stop();
      await closed.future.timeout(const Duration(seconds: 5));
      expect(capture.active, isFalse);
      await journal.drain();
      final part = await uploaded.future.timeout(const Duration(seconds: 5));
      expect(part.sublist(part.length - next.length), next);
      expect(scratch.listSync(), isEmpty);
      expect(capture.problem, isNull);
    } finally {
      await capture.stop();
      capture.dispose();
      preview.dispose();
      journal.dispose();
    }
  });
}
