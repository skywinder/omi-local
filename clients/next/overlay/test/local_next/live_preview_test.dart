import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/live_preview.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

class _Server {
  late HttpServer http;
  final connected = StreamController<WebSocket>.broadcast();
  final received = StreamController<dynamic>.broadcast();
  final sockets = <WebSocket>[];
  final requests = <Uri>[];

  Future<void> open() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((request) async {
      requests.add(request.uri);
      expect(request.headers.value(HttpHeaders.authorizationHeader), 'Bearer fixture');
      expect(request.headers.value('X-Omi-Local-Audio-Outbox'), '1');
      expect(request.headers.value('X-App-Platform'), 'ios');
      final ws = await WebSocketTransformer.upgrade(request, compression: CompressionOptions.compressionOff);
      sockets.add(ws);
      ws.listen(received.add);
      connected.add(ws);
    });
    addTearDown(() async {
      for (final ws in sockets) {
        await ws.close();
      }
      await http.close(force: true);
      await received.close();
      await connected.close();
    });
  }

  Uri get origin => Uri(scheme: 'http', host: '127.0.0.1', port: http.port);

  Future<WebSocket> dial(String owner, String source, String codec) async {
    expect(owner, 'paired');
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      return await upgradePairedPreview(
        client,
        origin,
        'fixture',
        source,
        codec,
        audioOrigin: const {'X-App-Platform': 'ios'},
      );
    } finally {
      client.close();
    }
  }
}

Future<void> _until(NextLivePreview preview, bool Function() done) {
  if (done()) return Future.value();
  final result = Completer<void>();
  void listen() {
    if (!result.isCompleted && done()) result.complete();
  }

  preview.addListener(listen);
  return result.future.timeout(const Duration(seconds: 4)).whenComplete(() => preview.removeListener(listen));
}

String _snapshot(String id, int revision, List<Map<String, dynamic>> rows, {int? control}) => jsonEncode({
  'type': 'local_transcript_snapshot',
  'preview_id': id,
  'revision': revision,
  'segments': rows,
  if (control != null) 'translation_revision': control,
});

Map<String, dynamic> _row(String id, String text, {String? translation}) => {
  'id': id,
  'start': 0.0,
  'end': 1.0,
  'text': text,
  'speaker': 'SPEAKER_02',
  'is_draft': true,
  if (translation != null)
    'translations': [
      {'lang': 'de', 'text': translation},
    ],
};

void main() {
  test('paired preview handshake, persisted audio and versioned corrections/translation use the real wire', () async {
    final server = _Server();
    await server.open();
    final preview = NextLivePreview('paired', server.dial);
    addTearDown(preview.dispose);
    preview.setTranslation('de', other: 'ru');
    final connected = server.connected.stream.first;
    final control = server.received.stream.first;
    preview.begin('rec', 'phone', 'pcm16');
    final peer = await connected;
    expect(jsonDecode(await control as String), {
      'type': 'translation',
      'language': 'de',
      'other_language': 'ru',
      'revision': 1,
    });
    expect(server.requests.single.path, '/v4/listen');
    expect(server.requests.single.queryParameters, {
      'source': 'phone',
      'codec': 'pcm16',
      'sample_rate': '16000',
      'channels': '1',
      'language': 'multi',
      'stt_service': 'offline_capture',
      'include_speech_profile': 'false',
      'create_speakers': 'false',
    });
    peer.add(jsonEncode({'type': 'service_status', 'provider': 'offline_capture', 'status': 'ready'}));
    peer.add(jsonEncode({'type': 'service_status', 'provider': 'local_live_preview', 'status': 'ready'}));
    await _until(preview, () => preview.phase == NextPreviewPhase.listening);
    final audio = server.received.stream.first;
    preview.addPersisted('old', 'phone', 'pcm16', Uint8List.fromList([9, 9]), startSeconds: 0);
    preview.addPersisted('rec', 'omi', 'opus', Uint8List.fromList([0xf8]), startSeconds: 0);
    preview.addPersisted('rec', 'phone', 'pcm16', Uint8List.fromList([1, 2]), startSeconds: 3.5);
    expect(await audio, [1, 2]);
    peer.add(_snapshot('trial', 1, [_row('a', 'first', translation: 'erste')], control: 1));
    await _until(preview, () => preview.lines.isNotEmpty);
    expect(preview.lines.single.start, 3.5);
    expect(preview.lines.single.end, 4.5);
    expect(preview.lines.single.speaker, 'SPEAKER_02');
    expect(preview.lines.single.isDraft, isTrue);
    expect(preview.lines.single.translations, {'de': 'erste'});
    peer.add(_snapshot('trial', 1, []));
    peer.add(_snapshot('trial', 2, [_row('a', 'corrected', translation: 'wrong control')], control: 0));
    await _until(preview, () => preview.lines.single.text == 'corrected');
    expect(preview.lines.single.translations, {'de': 'erste'});
    peer.add(_snapshot('trial', 3, [_row('a', 'corrected', translation: 'neu')], control: 1));
    await _until(preview, () => preview.lines.single.translations['de'] == 'neu');
    peer.add(
      _snapshot('trial', 4, [
        {
          ..._row('a', 'direction changed'),
          'translations': [
            {'lang': 'ru', 'text': 'перевод'},
          ],
        },
      ], control: 1),
    );
    await _until(preview, () => preview.lines.single.text == 'direction changed');
    expect(preview.lines.single.translations, {'ru': 'перевод'});
    peer.add(
      _snapshot('trial', 5, [
        {..._row('a', 'first half'), 'end': 0.5},
        {..._row('b', 'second half'), 'start': 0.5},
      ], control: 1),
    );
    await _until(preview, () => preview.lines.length == 2);
    expect(preview.lines.every((line) => line.translations.isEmpty), isTrue);
    final off = server.received.stream.first;
    preview.setTranslation('');
    expect(preview.lines.every((line) => line.translations.isEmpty), isTrue);
    expect(jsonDecode(await off as String), {'type': 'translation', 'language': '', 'revision': 2});
    peer.add(_snapshot('trial', 6, []));
    await _until(preview, () => preview.lines.isEmpty);
    preview.end('rec');
    expect(preview.phase, NextPreviewPhase.idle);
  });

  test(
    'reconnect preserves earlier drafts, uses fresh audio offsets and stops retrying terminal provider failure',
    () async {
      final server = _Server();
      await server.open();
      final preview = NextLivePreview('paired', server.dial, retryDelay: Duration.zero);
      addTearDown(preview.dispose);
      final first = server.connected.stream.first;
      preview.begin('first', 'omi', 'opus_fs320');
      final initial = await first;
      initial.add(jsonEncode({'type': 'service_status', 'provider': 'local_live_preview', 'status': 'ready'}));
      await _until(preview, () => preview.phase == NextPreviewPhase.listening);
      final firstAudio = server.received.stream.first;
      preview.addPersisted('first', 'omi', 'opus_fs320', Uint8List.fromList([0x78, 1]), startSeconds: 0);
      await firstAudio;
      initial.add(_snapshot('prefix', 1, [_row('x', 'before')]));
      await _until(preview, () => preview.lines.length == 1);
      final next = server.connected.stream.first;
      await initial.close(WebSocketStatus.goingAway);
      final replacement = await next;
      replacement.add(jsonEncode({'type': 'service_status', 'provider': 'local_live_preview', 'status': 'ready'}));
      await _until(preview, () => preview.phase == NextPreviewPhase.listening);
      final nextAudio = server.received.stream.first;
      preview.addPersisted('first', 'omi', 'opus_fs320', Uint8List.fromList([0x78, 2]), startSeconds: 9);
      expect(await nextAudio, [0x78, 2]);
      replacement.add(_snapshot('prefix', 2, []));
      replacement.add(_snapshot('suffix', 1, [_row('x', 'after')]));
      await _until(preview, () => preview.lines.length == 2);
      expect(preview.lines.map((line) => line.text), ['before', 'after']);
      expect(preview.lines.map((line) => line.id).toSet(), hasLength(2));
      expect(preview.lines.last.start, 9);
      preview.confirmConversationBoundary('different recording', 8 * 16000);
      expect(preview.savedGroupId, isNull);
      preview.confirmConversationBoundary('first', 8 * 16000);
      preview.confirmConversationBoundary('first', 7 * 16000); // Older upload, acknowledged late.
      expect(preview.savedGroupId, 'first');
      expect(preview.boundarySeconds, 8);
      expect(preview.phase, NextPreviewPhase.listening);
      expect(preview.lines.map((line) => line.text), ['after']);
      replacement.add(
        _snapshot('suffix', 2, [
          _row('early', 'Old text in a newer snapshot'),
          {..._row('x', 'Revised next conversation'), 'start': 1.0, 'end': 2.0},
        ]),
      );
      await _until(preview, () => preview.lines.last.text == 'Revised next conversation');
      expect(preview.lines.last.start, 10);
      preview.confirmConversationBoundary('first', 10 * 16000);
      expect(preview.lines.map((line) => line.text), ['Revised next conversation']);
      replacement.add(_snapshot('suffix', 3, [_row('early', 'Still stored on the server')]));
      await _until(preview, () => preview.lines.isEmpty);
      replacement.add(
        jsonEncode({
          'type': 'service_status',
          'provider': 'local_live_preview',
          'status': 'stt_failed',
          'reason': 'busy',
        }),
      );
      await _until(preview, () => preview.phase == NextPreviewPhase.unavailable);
      expect(preview.reason, 'busy');
      preview.end('retired');
      expect(preview.phase, NextPreviewPhase.unavailable);
      preview.end('first');
      final fresh = server.connected.stream.first;
      preview.begin('second', 'phone', 'pcm16');
      final third = await fresh;
      expect(preview.lines, isEmpty);
      expect(preview.savedGroupId, isNull);
      third.add(_snapshot('other', 1, [_row('z', 'fresh')]));
      await _until(preview, () => preview.lines.length == 1);
      third.add(_snapshot('other', 2, []));
      await _until(preview, () => preview.lines.isEmpty);
      expect(server.requests, hasLength(3));
    },
  );

  test('a prolonged outage checkpoints offline audio once and resumes the same active recording', () async {
    final server = _Server();
    await server.open();
    final directory = await Directory.systemTemp.createTemp('next-reconnect-');
    addTearDown(() => directory.delete(recursive: true));
    final delivered = <Uint8List>[];
    final journal = LocalAudioJournal(
      directory: directory,
      upload: (body, owner) async {
        expect(owner, 'paired');
        final size = ByteData.sublistView(body, 8, 12).getUint32(0);
        final header = jsonDecode(utf8.decode(body.sublist(12, 12 + size)));
        delivered.add(body);
        return {'id': header['id'], 'stored': true, 'sha256': sha256.convert(body).toString()};
      },
    );
    addTearDown(journal.dispose);
    await journal.initialize();
    final recording = journal.beginForServer(source: 'phone', codec: 'pcm16', serverId: 'paired');
    final restored = Completer<void>();
    final attempted = Completer<void>();
    final recoveries = <Future<void>>[];
    var attempts = 0;
    final preview = NextLivePreview(
      'paired',
      (owner, source, codec) async {
        attempts++;
        if (attempts > 1 && attempts <= 6) throw const SocketException('offline');
        if (attempts == 7) {
          attempted.complete();
          await restored.future;
        }
        return server.dial(owner, source, codec);
      },
      retryDelay: const Duration(milliseconds: 1),
      onReconnect: () => recoveries.add(journal.recoverConnection()),
    );
    addTearDown(preview.dispose);
    final first = server.connected.stream.first;
    preview.begin(recording.recordingId, 'phone', 'pcm16');
    final ready = jsonEncode({'type': 'service_status', 'provider': 'local_live_preview', 'status': 'ready'});
    final accepted = jsonEncode({'type': 'service_status', 'provider': 'offline_capture', 'status': 'ready'});
    final firstPeer = await first;
    firstPeer.add(ready);
    await _until(preview, () => preview.phase == NextPreviewPhase.listening);
    expect(recoveries, isEmpty);
    await firstPeer.close(WebSocketStatus.goingAway);
    await attempted.future.timeout(const Duration(seconds: 4));
    expect(preview.reason, 'reconnecting');
    await recording.add([1, 2, 3, 4]);
    expect(delivered, isEmpty);
    final next = server.connected.stream.first;
    restored.complete();
    final peer = await next;
    peer.add(accepted);
    peer.add(accepted);
    peer.add(ready);
    await _until(preview, () => preview.phase == NextPreviewPhase.listening);
    await recoveries.single;
    await journal.drain();
    expect(journal.activeRecordings, 1);
    expect(journal.deliveryRevision, 1);
    expect(delivered.single.sublist(delivered.single.length - 4), [1, 2, 3, 4]);
    await recording.add([5, 6]);
    await recording.stop();
    await journal.drain();
    expect(journal.deliveryRevision, 2);
    expect(delivered.last.sublist(delivered.last.length - 2), [5, 6]);
    preview.end(recording.recordingId);
  });

  test('rejects same-origin redirects and forged upgrade responses before sending any audio', () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = Uri(scheme: 'http', host: '127.0.0.1', port: http.port);
    final routes = <String>[];
    http.listen((req) async {
      routes.add(req.uri.path);
      if (routes.length == 1) {
        await req.response.redirect(origin.resolve('/other'));
      } else {
        req.response.statusCode = HttpStatus.switchingProtocols;
        req.response.headers
          ..set('Connection', 'Upgrade')
          ..set('Upgrade', 'websocket')
          ..set('Sec-WebSocket-Accept', 'forged');
        await req.response.close();
      }
    });
    try {
      for (final expected in [302, 101]) {
        final client = HttpClient()..findProxy = (_) => 'DIRECT';
        await expectLater(
          upgradePairedPreview(client, origin, 'fixture', 'phone', 'pcm16'),
          throwsA(isA<WebSocketException>().having((e) => e.httpStatusCode, 'status', expected)),
        );
      }
      expect(routes, ['/v4/listen', '/v4/listen']);
    } finally {
      await http.close(force: true);
    }
  });
}
