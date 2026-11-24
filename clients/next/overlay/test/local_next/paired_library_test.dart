import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/processing.dart';
import 'package:omi/local_next/recording_edit.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

void main() {
  final key = List.filled(43, 'A').join();
  const id = '00000000-0000-4000-8000-000000000001';
  test('archive search follows a cursor and retains transcript evidence', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final library = PairedLibrary('http://127.0.0.1:${server.port}', key)..verified = true;
    addTearDown(library.close);
    final requests = <Object?>[];
    server.listen((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/v1/local/conversations/search');
      expect(request.headers.value(HttpHeaders.authorizationHeader), 'Bearer $key');
      requests.add(jsonDecode(await utf8.decoder.bind(request).join()));
      switch (requests.length) {
        case 1:
          request.response.write(jsonEncode({'items': [], 'next_cursor': id}));
        case 2:
          request.response.write(
            jsonEncode({
              'items': [
                {
                  'id': id,
                  'title': 'Fixture',
                  'started_at': '2026-01-02T00:00:00Z',
                  'match_snippets': [
                    {'text': 'Привет', 'segment_id': 'line', 'start': 4.25, 'start_ms': 4250},
                  ],
                },
              ],
              'next_cursor': null,
            }),
          );
        case 3:
          request.response.statusCode = 503;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'reason': 'offline_route_blocked'}));
        case 4:
          request.response.statusCode = 503;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'reason': 'fixture_unavailable'}));
      }
      await request.response.close();
    });

    final first = (await library.searchArchive('привет'))!;
    expect(first.hits, isEmpty);
    expect(first.nextCursor, id);
    final second = (await library.searchArchive('привет', after: first.nextCursor))!;
    expect(second.hits.single.snippets.single.segmentId, 'line');
    expect(second.hits.single.snippets.single.startMs, 4250);
    expect(second.nextCursor, isNull);
    expect(await library.searchArchive('привет'), isNull);
    await expectLater(library.searchArchive('привет'), throwsA(LibraryFailure.unavailable));
    expect(requests, [
      {'query': 'привет'},
      {'query': 'привет', 'after': id},
      {'query': 'привет'},
      {'query': 'привет'},
    ]);
  });

  test('runtime diagnostics use the paired route and distinguish older servers from key rejection', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final library = PairedLibrary('http://127.0.0.1:${server.port}', key);
    addTearDown(library.close);
    var calls = 0, revoked = false;
    library.onKeyRejected = () => revoked = true;
    server.listen((request) async {
      expect(request.method, 'GET');
      expect(request.uri.path, '/v1/local/status');
      expect(request.headers.value(HttpHeaders.authorizationHeader), 'Bearer $key');
      switch (++calls) {
        case 1:
          request.response.statusCode = HttpStatus.notFound;
        case 2:
          request.response.write(
            jsonEncode({
              'backend': 'ready',
              'capture': {'state': 'received', 'audio_seconds': 12, 'frames_received': 3},
              'live_transcript': {'state': 'streaming', 'updates': 2},
            }),
          );
        case 3:
          request.response.statusCode = HttpStatus.forbidden;
      }
      await request.response.close();
    });
    expect(await library.readRuntimeStatus(), isNull);
    expect(revoked, isFalse);
    final status = await library.readRuntimeStatus();
    expect(status?.audioSeconds, 12);
    expect(status?.transcriptUpdates, 2);
    expect(status?.diarizationState.name, 'unknown');
    await expectLater(library.readRuntimeStatus(), throwsA(LibraryFailure.key));
    expect(revoked, isTrue);
    await expectLater(library.readRuntimeStatus(), throwsA(LibraryFailure.key));
    expect(calls, 3);
  });

  test('live tuning uses the paired route and treats a mismatched publication as unconfirmed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final library = PairedLibrary('http://127.0.0.1:${server.port}', key);
    addTearDown(library.close);
    var response = 0;
    final writes = <Object?>[];
    server.listen((request) async {
      expect(request.uri.path, '/v1/local/processing/live-tuning');
      expect(request.headers.value(HttpHeaders.authorizationHeader), 'Bearer $key');
      if (request.method == 'POST') {
        expect(request.contentLength, greaterThan(0));
        writes.add(jsonDecode(await utf8.decoder.bind(request).join()));
      }
      if (++response == 1) {
        request.response.statusCode = 404;
      } else {
        final (revision, speakers) = switch (response) {
          2 || 3 => (5, 2),
          4 => (6, 3),
          _ => (7, 4),
        };
        request.response.write(
          jsonEncode({
            'available': true,
            'revision': revision,
            'settings': {'max_speakers': speakers},
          }),
        );
      }
      await request.response.close();
    });
    expect(await library.readLiveTuning(), isNull);
    expect(await library.readLiveTuning(), (revision: 5, speakers: 2));
    await expectLater(library.setLiveSpeakerLimit(5, 3), throwsA(NextProcessingFailure.indeterminate));
    expect(await library.readLiveTuning(), (revision: 6, speakers: 3));
    expect(await library.setLiveSpeakerLimit(6, 4), (revision: 7, speakers: 4));
    expect(writes, [
      {'revision': 5, 'max_speakers': 3},
      {'revision': 6, 'max_speakers': 4},
    ]);
  });

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
  test('paired recording edits send bounded JSON and list favorites through the archive API', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final library = PairedLibrary('http://127.0.0.1:${server.port}', key);
    addTearDown(library.close);
    final edits = <Object?>[];
    server.listen((request) async {
      expect(request.headers.value(HttpHeaders.authorizationHeader), 'Bearer $key');
      final response = request.response;
      switch (request.uri.path) {
        case '/v1/users/profile':
          response.write(jsonEncode({'uid': 'alice', 'local_recording_edits_version': 1}));
        case '/v1/conversations':
          expect(request.method, 'GET');
          expect(request.uri.queryParameters['starred'], 'true');
          expect(request.uri.queryParameters['folder_id'], 'project-folder');
          response.write(
            jsonEncode([
              {...row, 'starred': true},
            ]),
          );
        case '/v1/local/conversations/$id/edit':
          expect(request.method, 'PATCH');
          expect(request.uri.hasQuery, isFalse);
          edits.add(jsonDecode(await utf8.decoder.bind(request).join()));
          if (edits.length == 1) {
            response.statusCode = HttpStatus.conflict;
          } else {
            response.write(
              jsonEncode({
                'status': 'Ok',
                'conversation': {...row, 'starred': true},
              }),
            );
          }
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    await library.verify();
    expect(library.recordingEdits, isTrue);
    await expectLater(
      library.editRecording(id, const RecordingEdit.title('Earlier', 'New title')),
      throwsA(RecordingEditFailure.conflict),
    );
    expect((await library.editRecording(id, const RecordingEdit.starred(false, true))).starred, isTrue);
    expect((await library.list(0, starredOnly: true, folderId: 'project-folder')).rows.single.starred, isTrue);
    expect(edits, [
      {'field': 'title', 'expected': sha256.convert(utf8.encode('Earlier')).toString(), 'value': 'New title'},
      {'field': 'starred', 'expected': false, 'value': true},
    ]);
  });

  test('a paired server supplies archive, transcript, audio and the durable upload receipt', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String>[];
    Uint8List envelope(Map<String, dynamic> fields) {
      final data = utf8.encode(jsonEncode(fields));
      final length = (ByteData(4)..setUint32(0, data.length, Endian.big)).buffer.asUint8List();
      return Uint8List.fromList([...LocalAudioJournal.magic, ...length, ...data]);
    }

    final part = envelope({'version': 2, 'id': id, 'server_id': 'fixture', 'preroll_frames': 0});
    final finish = envelope({
      'version': 3,
      'id': id,
      'recording_id': id,
      'server_id': 'fixture',
      'preroll_frames': 0,
      'group_version': 1,
      'kind': 'finish',
      'silence_seconds': 30,
      'index': 1,
    });
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
            if (request.method != 'POST' || payload.join(',') != part.join(',')) response.statusCode = 400;
            response.write(jsonEncode({'stored': true}));
          default:
            response.statusCode = 404;
        }
      }
      await response.close();
    });
    final library = PairedLibrary('http://127.0.0.1:${server.port}', key);
    expect(library.isSignedIn, isFalse);
    await library.verify();
    expect(library.isSignedIn, isTrue);
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
    await expectLater(library.uploadPart(part, 'other pairing'), throwsA(LibraryFailure.key));
    await expectLater(library.uploadPart(finish, library.audioOwnerId), throwsA(LibraryFailure.unavailable));
    expect(await library.uploadPart(part, library.audioOwnerId), {'stored': true});
    library.close();
    expect(library.isSignedIn, isFalse);
    await expectLater(library.detail(id), throwsA(LibraryFailure.key));
    expect(seen, [
      '/v1/users/profile',
      '/v1/conversations',
      '/v1/conversations/$id',
      '/v1/local/conversations/$id/audio',
      '/v1/local/audio/parts',
    ]);
  });

  test('archive uses paired headers, preserves pending rows and advances the storage offset', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final offsets = <String?>[];
    final ownership = <String?>[];
    final pending = {
      ...row,
      'structured': {'title': 'Запись', 'overview': ''},
      'status': 'processing',
      'external_data': {
        'local_recording': {'status': 'pending', 'duration_seconds': 12},
      },
    };
    server.listen((r) async {
      final response = r.response;
      if (r.uri.path == '/v1/users/profile') {
        response.write('{"uid":"alice"}');
      } else if (r.uri.path == '/v1/conversations') {
        offsets.add(r.uri.queryParameters['offset']);
        ownership.add(r.headers.value('x-omi-home-ownership'));
        if (r.headers.value(HttpHeaders.authorizationHeader) != 'Bearer $key' ||
            r.uri.queryParameters['statuses'] != 'processing,completed,failed' ||
            r.uri.queryParameters['include_discarded'] != 'true' ||
            r.uri.queryParameters['limit'] != '30') {
          response.statusCode = 403;
        } else {
          switch (offsets.last) {
            case '0':
              response.headers.set('x-omi-list-truncated', 'true'); // Older Local server.
              response.write(
                jsonEncode([
                  pending,
                  {...row, 'id': 'outside/paired/archive'},
                ]),
              );
            case '2':
              response.headers.set('x-omi-conversation-page-size', '3');
              response.headers.set('x-omi-has-more', 'true');
              response.write('[]');
            case '5':
              response.headers.set('x-omi-has-more', 'false');
              response.headers.set('x-omi-list-truncated', 'true');
              response.write(jsonEncode([row]));
            case '6':
              response.write('[{"broken":true}]');
            case '7':
              response.headers.set('x-omi-has-more', 'true');
              response.write('[]');
            default:
              response.statusCode = 404;
          }
        }
      } else {
        response.write(jsonEncode(row)); // A stale / wrong detail response.
      }
      await response.close();
    });
    final library = PairedLibrary('http://127.0.0.1:${server.port}', key);
    addTearDown(library.close);
    await library.verify();
    final first = await library.list(0);
    expect(first.rows.single.externalIntegration?.localRecording?['status'], 'pending');
    expect(first.rows.single.structured.title, 'Запись');
    expect((first.consumed, first.more, first.partial), (2, true, true));
    final hidden = await library.list(first.consumed);
    expect(hidden.rows, isEmpty);
    expect((hidden.consumed, hidden.more, hidden.partial), (3, true, false));
    final last = await library.list(first.consumed + hidden.consumed);
    expect((last.consumed, last.more, last.partial), (1, false, true));
    await expectLater(library.list(6), throwsA(LibraryFailure.malformed));
    expect((await library.list(7)).more, isFalse);
    expect(offsets, ['0', '2', '5', '6', '7']);
    expect(ownership, everyElement(isNull));
    await expectLater(library.detail('00000000-0000-4000-8000-000000000002'), throwsA(LibraryFailure.malformed));
  });

  test('archive rejects unauthenticated owners and never follows redirects or replays after 401', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    addTearDown(() => other.close(force: true));
    var forwarded = false;
    var reads = 0;
    other.listen((r) {
      forwarded = true;
      r.response.close();
    });
    server.listen((r) async {
      if (r.uri.path == '/v1/users/profile') {
        r.response.write('{"uid":"alice"}');
      } else if (++reads == 1) {
        await r.response.redirect(Uri.parse('http://127.0.0.1:${other.port}/v1/conversations'));
        return;
      } else {
        r.response.statusCode = 401;
      }
      await r.response.close();
    });
    final library = PairedLibrary('http://127.0.0.1:${server.port}', key);
    var rejections = 0;
    library.onKeyRejected = () => rejections++;
    await expectLater(library.list(0), throwsA(LibraryFailure.key));
    expect(reads, 0);
    await library.verify();
    await expectLater(library.list(0), throwsA(LibraryFailure.unavailable));
    expect(library.isSignedIn, isTrue);
    await expectLater(library.detail(id), throwsA(LibraryFailure.key));
    await expectLater(library.list(0), throwsA(LibraryFailure.key));
    expect(library.isSignedIn, isFalse);
    expect(rejections, 1);
    expect(reads, 2);
    expect(forwarded, isFalse);
  });

  test('restored custody permits journaling but a revoked key stops upload before any audio leaves', () async {
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
    addTearDown(pair.close);
    await pair.verify();
    final restored = PairedLibrary(pair.origin.origin, key, knownDelivery: pair.audioDelivery);
    addTearDown(restored.close);
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

  test('a queued part stays with its original pairing while another server records and delivers', () async {
    final documents = await Directory.systemTemp.createTemp('next-owner-fixture-');
    addTearDown(() => documents.delete(recursive: true));
    var oldAccepts = false;
    final oldReceipts = <String>[], newReceipts = <String>[];

    Future<PairedLibrary> receiver(bool Function() accepts, List<String> receipts) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/v1/users/profile') {
          response.write('{"uid":"alice","local_audio_delivery_version":2}');
        } else if (request.uri.path == '/v1/local/audio/parts' && accepts()) {
          final body = Uint8List.fromList(await request.expand((chunk) => chunk).toList());
          final size = ByteData.sublistView(body, 8, 12).getUint32(0);
          final header = jsonDecode(utf8.decode(body.sublist(12, 12 + size))) as Map;
          receipts.add(header['server_id'] as String);
          response.write(jsonEncode({'stored': true, 'id': header['id'], 'sha256': '${sha256.convert(body)}'}));
        } else {
          response.statusCode = HttpStatus.serviceUnavailable;
        }
        await response.close();
      });
      final library = PairedLibrary('http://127.0.0.1:${server.port}', key);
      addTearDown(library.close);
      await library.verify();
      return library;
    }

    LocalAudioJournal journalFor(PairedLibrary library) => LocalAudioJournal(
      directory: Directory('${documents.path}/outbox/${library.audioOwnerId}'),
      upload: library.uploadPart,
    );

    Future<void> record(LocalAudioJournal journal, PairedLibrary library) async {
      await journal.initialize();
      final capture = journal.beginForServer(source: 'phone', codec: 'pcm16', serverId: library.audioOwnerId);
      await capture.add([1, 2]);
      await capture.stop();
      await journal.drain();
    }

    final old = await receiver(() => oldAccepts, oldReceipts);
    final oldJournal = journalFor(old);
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    PairedLibrary.trackAudioRelease(old.audioOwnerId, release.future);
    var inspectedDuringSeal = false;
    final beforeRemoval = PairedLibrary.retainedAudioFor(old.audioOwnerId, documents: documents).then((retained) {
      inspectedDuringSeal = !release.isCompleted;
      return retained;
    });
    await record(oldJournal, old);
    expect(oldJournal.pendingParts, 1);
    oldJournal.dispose();
    old.close();
    release.complete();
    expect(await beforeRemoval, isTrue);
    expect(inspectedDuringSeal, isFalse);

    final next = await receiver(() => true, newReceipts);
    expect(await PairedLibrary.retainedAudioFor(next.audioOwnerId, documents: documents), isFalse);
    await expectLater(next.uploadPart(Uint8List(2), old.audioOwnerId), throwsA(LibraryFailure.key));
    final newJournal = journalFor(next);
    addTearDown(newJournal.dispose);
    await record(newJournal, next);
    expect(newReceipts, [next.audioOwnerId]);
    expect(await PairedLibrary.retainedAudioFor(old.audioOwnerId, documents: documents), isTrue);

    oldAccepts = true;
    final restored = PairedLibrary(old.origin.origin, key, knownDelivery: true);
    addTearDown(restored.close);
    final recoveredJournal = journalFor(restored);
    addTearDown(recoveredJournal.dispose);
    await recoveredJournal.initialize();
    await recoveredJournal.drain();
    expect(oldReceipts, [old.audioOwnerId]);
    expect(await PairedLibrary.retainedAudioFor(old.audioOwnerId, documents: documents), isFalse);
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

  test('processing drafts send exact JSON methods, keep redirects local and classify lost writes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = <({String method, String path, Object? body})>[];
    server.listen((request) async {
      final response = request.response;
      expect(request.headers.value(HttpHeaders.authorizationHeader), 'Bearer $key');
      expect(request.headers.contentType?.mimeType, 'application/json');
      expect(request.contentLength, greaterThan(0));
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      received.add((method: request.method, path: request.uri.path, body: body));
      if (request.uri.path.endsWith('/probe')) {
        await response.redirect(Uri.parse('/untrusted'), status: HttpStatus.temporaryRedirect);
        return;
      }
      response.statusCode = HttpStatus.serviceUnavailable;
      response.write(jsonEncode({'outcome': 'indeterminate'}));
      await response.close();
    });
    final library = PairedLibrary('http://127.0.0.1:${server.port}', key);
    addTearDown(library.close);
    final draft = {
      'profile': {'name': 'Fixture'},
      'api_key': 'synthetic-provider-key',
    };
    await expectLater(
      library.requestProcessingDraft(NextDraftOperation.probe, draft, null),
      throwsA(NextProcessingFailure.unavailable),
    );
    await expectLater(
      library.requestProcessingDraft(NextDraftOperation.save, {...draft, 'revision': 8}, null),
      throwsA(NextProcessingFailure.indeterminate),
    );
    await expectLater(
      library.requestProcessingDraft(NextDraftOperation.delete, {'revision': 8}, 'bad/id'),
      throwsA(NextProcessingFailure.invalid),
    );
    await expectLater(
      library.requestProcessingDraft(NextDraftOperation.delete, {'revision': 8}, 'prepared-1'),
      throwsA(NextProcessingFailure.indeterminate),
    );
    expect(received.map((event) => (event.method, event.path)), [
      ('POST', '/v1/local/processing/probe'),
      ('POST', '/v1/local/processing/save'),
      ('DELETE', '/v1/local/processing/profiles/prepared-1'),
    ]);
    expect(received.map((event) => event.body), [
      draft,
      {...draft, 'revision': 8},
      {'revision': 8},
    ]);
  });
}
