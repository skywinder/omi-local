import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/processing.dart';

void main() {
  final key = List.filled(43, 'A').join();
  const id = '00000000-0000-4000-8000-000000000001';
  final row = {
    'id': id,
    'created_at': '2025-01-01T12:00:00Z',
    'started_at': null,
    'finished_at': null,
    'structured': {'title': 'Fixture', 'overview': 'Summary'},
    'transcript_segments': [
      {'text': 'Hello', 'is_user': false, 'start': 1.5, 'end': 2.0},
    ],
  };
  test('a paired server supplies archive, transcript, audio and the durable upload receipt', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String>[];
    server.listen((request) async {
      seen.add(request.uri.path);
      final response = request.response;
      if (request.headers.value(HttpHeaders.authorizationHeader) != 'Bearer $key') {
        response.statusCode = 403;
      } else {
        switch (request.uri.path) {
          case '/v1/users/profile':
            response.write(
              jsonEncode({'uid': 'alice', 'local_audio_playback_version': 1, 'local_audio_delivery_version': 2}),
            );
          case '/v1/conversations':
            response.write(
              jsonEncode([
                row,
                {'broken': true},
              ]),
            );
          case '/v1/conversations/$id':
            response.write(jsonEncode(row));
          case '/v1/local/conversations/$id/audio':
            response.headers.contentType = ContentType('audio', 'wav');
            response.add([1, 2, 3]);
          case '/v1/local/audio/parts':
            final payload = await request.expand((part) => part).toList();
            if (request.method != 'POST' || payload.join(',') != '4,5') response.statusCode = 400;
            response.write(jsonEncode({'stored': true}));
          default:
            response.statusCode = 404;
        }
      }
      await response.close();
    });
    final library = PairedLibrary('http://127.0.0.1:${server.port}', key);
    await library.verify();
    expect(library.audioDelivery, isTrue);
    expect(library.audioPlayback, isTrue);
    final page = await library.list(0);
    expect(page.rows.single.structured.title, 'Fixture');
    expect(page.partial, isTrue);
    expect(page.consumed, 2);
    expect((await library.detail(id)).transcriptSegments.single.start, 1.5);
    final dir = await Directory.systemTemp.createTemp('next-audio-test-');
    addTearDown(() => dir.delete(recursive: true));
    final wav = File('${dir.path}/fixture');
    await library.downloadAudio(id, wav);
    expect(await wav.readAsBytes(), [1, 2, 3]);
    final part = Uint8List.fromList([4, 5]);
    await expectLater(library.uploadPart(part, 'other pairing'), throwsA(LibraryFailure.key));
    expect(await library.uploadPart(part, library.audioOwnerId), {'stored': true});
    library.close();
    await expectLater(library.detail(id), throwsA(LibraryFailure.key));
    expect(seen, [
      '/v1/users/profile',
      '/v1/conversations',
      '/v1/conversations/$id',
      '/v1/local/conversations/$id/audio',
      '/v1/local/audio/parts',
    ]);
  });

  test('restored custody permits journaling but a revoked key stops upload before any audio leaves', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((r) async {
      requests.add(r.uri.path);
      if (requests.length == 1) {
        r.response.write(jsonEncode({'uid': 'alice', 'local_audio_delivery_version': 2}));
      } else {
        r.response.statusCode = 403;
      }
      await r.response.close();
    });
    final pair = PairedLibrary('http://127.0.0.1:${server.port}', key);
    await pair.verify();
    await pair.save();
    final restored = (await PairedLibrary.restore())!;
    expect(restored.verified, isFalse);
    expect(restored.audioDelivery, isTrue);
    expect(restored.audioOwnerId, pair.audioOwnerId);
    var rejected = false;
    restored.onKeyRejected = () => rejected = true;
    await expectLater(restored.uploadPart(Uint8List(1), pair.audioOwnerId), throwsA(LibraryFailure.key));
    expect(rejected, isTrue);
    expect(restored.audioDelivery, isFalse);
    await expectLater(restored.list(0), throwsA(LibraryFailure.key));
    expect(requests, ['/v1/users/profile', '/v1/users/profile']);
  });

  test('a redirect cannot forward the app key to a second server', () async {
    final from = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final to = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => from.close(force: true));
    addTearDown(() => to.close(force: true));
    var redirected = false;
    to.listen((r) {
      redirected = true;
      r.response.close();
    });
    from.listen((r) => r.response.redirect(Uri.parse('http://127.0.0.1:${to.port}/v1/users/profile')));
    final library = PairedLibrary('http://127.0.0.1:${from.port}', key);
    await expectLater(library.verify(), throwsA(LibraryFailure.unavailable));
    expect(redirected, isFalse);
    expect(() => PairedLibrary('http://example.org', key), throwsA(LibraryFailure.address));
    expect(() => PairedLibrary('https://example.org/#x', key), throwsA(LibraryFailure.address));
    expect(() => PairedLibrary('https://example.org', 'bad'), throwsA(LibraryFailure.key));
  });

  test('the paired live upgrade refuses redirects and revokes on a forbidden response', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    var revoked = false;
    server.listen((request) async {
      paths.add(request.uri.path);
      final response = request.response;
      if (request.uri.path == '/v1/users/profile') {
        response.write(jsonEncode({'uid': 'alice', 'local_audio_delivery_version': 2}));
      } else if (request.uri.path == '/v4/listen') {
        if (!revoked) {
          await response.redirect(Uri.parse('/redirected'));
          return;
        }
        response.statusCode = HttpStatus.forbidden;
      }
      await response.close();
    });
    final library = PairedLibrary('http://127.0.0.1:${server.port}', key);
    addTearDown(library.close);
    var rejections = 0;
    library.onKeyRejected = () => rejections++;
    await expectLater(library.connectPreview('another pairing', 'phone', 'pcm16'), throwsA(LibraryFailure.key));
    expect(paths, isEmpty);
    await expectLater(
      library.connectPreview(library.audioOwnerId, 'phone', 'pcm16'),
      throwsA(isA<WebSocketException>()),
    );
    expect(paths, ['/v1/users/profile', '/v4/listen']);
    expect(rejections, 0);
    revoked = true;
    await expectLater(
      library.connectPreview(library.audioOwnerId, 'phone', 'pcm16'),
      throwsA(isA<WebSocketException>()),
    );
    expect(rejections, 1);
    expect(library.audioDelivery, isFalse);
  });

  test('paired processing sends one JSON activation and distinguishes refusal, uncertainty and revocation', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <(String, String)>[];
    final payloads = <Object?>[];
    var activationStatus = HttpStatus.forbidden;
    var readStatus = HttpStatus.ok;
    server.listen((request) async {
      final response = request.response;
      seen.add((request.method, request.uri.path));
      if (request.headers.value(HttpHeaders.authorizationHeader) != 'Bearer $key') {
        response.statusCode = HttpStatus.unauthorized;
      } else if (request.method == 'POST') {
        if (request.headers.contentType?.mimeType != 'application/json' || request.contentLength <= 0) {
          response.statusCode = HttpStatus.badRequest;
        } else {
          payloads.add(jsonDecode(await utf8.decoder.bind(request).join()));
          response.statusCode = activationStatus;
        }
        response.write(jsonEncode({'error': 'private processing detail'}));
      } else {
        response.statusCode = readStatus;
        response.write(jsonEncode({'revision': 7, 'profiles': [], 'effective': {}}));
      }
      await response.close();
    });
    final library = PairedLibrary('http://127.0.0.1:${server.port}', key);
    addTearDown(library.close);
    var rejections = 0;
    library.onKeyRejected = () => rejections++;
    final payload = {'stage': 'live', 'id': 'prepared-profile', 'revision': 7};
    expect((await library.readProcessing())['revision'], 7);
    await expectLater(library.activateProcessing(payload), throwsA(NextProcessingFailure.invalid));
    expect(rejections, 0);
    activationStatus = HttpStatus.serviceUnavailable;
    await expectLater(library.activateProcessing(payload), throwsA(NextProcessingFailure.indeterminate));
    expect(payloads, [payload, payload]);
    expect(seen, [
      ('GET', '/v1/local/processing'),
      ('POST', '/v1/local/processing/activate'),
      ('POST', '/v1/local/processing/activate'),
    ]);

    readStatus = HttpStatus.unauthorized;
    await expectLater(library.readProcessing(), throwsA(NextProcessingFailure.unauthorized));
    expect(rejections, 1);
    await expectLater(library.readProcessing(), throwsA(NextProcessingFailure.unauthorized));
    expect(seen, hasLength(4));
  });
}
