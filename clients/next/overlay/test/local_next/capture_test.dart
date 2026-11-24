import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/capture.dart';
import 'package:omi/local_next/live_preview.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

class TestMic implements NextPhoneMicrophone {
  void Function(Uint8List)? samples;
  bool denied = false;
  final stopped = Completer<void>();

  @override
  Future<void> start(void Function(Uint8List) onSamples, void Function() onFailure) async {
    if (denied) throw PhoneCaptureDenied();
    samples = onSamples;
  }

  @override
  Future<void> stop() async {
    samples = null;
    stopped.complete();
  }
}

void main() {
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

  test('paired preview receives the phone frame after journal flush and Stop delivers the exact part', () async {
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
          response.write(jsonEncode({'uid': 'alice', 'local_audio_delivery_version': 2}));
        case '/v4/listen':
          expect(request.headers.value('x-omi-local-audio-outbox'), '1');
          expect(request.uri.queryParameters['source'], 'phone');
          expect(request.uri.queryParameters['codec'], 'pcm16');
          final socket = await WebSocketTransformer.upgrade(request);
          socket.listen((frame) {
            if (frame is List<int> && !received.isCompleted) {
              final part = scratch.listSync().whereType<File>().single.readAsBytesSync();
              received.complete((sent: frame, stored: part.sublist(part.length - frame.length)));
            }
          }, onDone: closed.complete);
          return;
        case '/v1/local/audio/parts':
          final body = Uint8List.fromList(await request.expand((bytes) => bytes).toList());
          uploaded.complete(body);
          final end = 12 + ByteData.sublistView(body).getUint32(8);
          final header = jsonDecode(utf8.decode(body.sublist(12, end))) as Map;
          response.write(jsonEncode({'stored': true, 'id': header['id'], 'sha256': sha256.convert(body).toString()}));
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });

    final journal = LocalAudioJournal(directory: scratch, upload: library.uploadPart);
    await journal.initialize();
    final preview = NextLivePreview(library.audioOwnerId, (owner, source, codec) async {
      final socket = await library.connectPreview(owner, source, codec);
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
      await capture.stop();
      await closed.future.timeout(const Duration(seconds: 5));
      await journal.drain();
      final part = await uploaded.future.timeout(const Duration(seconds: 5));
      expect(part.sublist(part.length - frame.length), frame);
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
