import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/processing.dart';

final _key = List.filled(43, 'P').join();

Map<String, dynamic> _profile(String stage, String id, String name, {int? revision}) => {
  'stage': stage,
  'id': id,
  'name': name,
  'kind': stage == 'stt' ? 'whisperkit' : 'openai-compatible',
  if (revision != null) 'configuration_revision': revision,
  'can_edit': false,
  'has_key': true,
  'settings': {'provider_url': 'https://fixture.invalid/v1'},
};

Map<String, dynamic> _registry(int revision, {bool changed = false}) {
  final prepared = _profile('stt', 'current-stt', 'Подготовленный профиль', revision: 6);
  final summary = _profile('summary', 'model', 'Summary model');
  return {
    'version': 1,
    'revision': revision,
    'profiles': [prepared, summary],
    'effective': {
      'stt': changed ? prepared : _profile('stt', 'current-stt', 'Действующий профиль', revision: 2),
      'live': null,
      'summary': summary,
      'translation': {...summary, 'stage': 'translation', 'inherited_from': 'summary'},
    },
  };
}

Future<PairedLibrary> _serve(Future<void> Function(HttpRequest) handler) async {
  final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  http.listen((request) async {
    expect(request.headers.value(HttpHeaders.authorizationHeader), 'Bearer $_key');
    await handler(request);
    await request.response.close();
  });
  final library = PairedLibrary('http://127.0.0.1:${http.port}', _key);
  addTearDown(() async {
    library.close();
    await http.close(force: true);
  });
  return library;
}

void main() {
  test(
    'reads prepared and effective profiles and activates only the explicitly confirmed revision on its paired server',
    () async {
      final requests = <String>[];
      final library = await _serve((request) async {
        requests.add('${request.method} ${request.uri.path}');
        if (request.method == 'POST') {
          expect(request.headers.contentType?.mimeType, 'application/json');
          expect(request.headers.value(HttpHeaders.transferEncodingHeader), isNull);
          final body = await utf8.decoder.bind(request).join();
          expect(request.contentLength, utf8.encode(body).length);
          expect(jsonDecode(body), {'revision': 7, 'stage': 'stt', 'id': 'current-stt'});
          request.response.write(jsonEncode(_registry(8, changed: true)));
        } else {
          request.response.write(jsonEncode(_registry(7)));
        }
      });
      var permitted = false;
      final client = NextProcessingClient(
        read: library.readProcessing,
        activatePrepared: library.activateProcessing,
        permitsActivation: () => permitted,
      );
      final settings = await client.fetch();
      final stt = settings.active(NextProcessingStage.stt)!;
      expect(stt.name, 'Действующий профиль');
      expect(stt.configurationRevision, 2);
      expect(settings.choices(NextProcessingStage.stt).single.configurationRevision, 6);
      expect(settings.active(NextProcessingStage.translation)!.inheritedFrom, NextProcessingStage.summary);
      expect(settings.supports(NextProcessingStage.live), isTrue);
      expect(settings.supports(NextProcessingStage.diarization), isFalse);
      expect(settings.canActivate(NextProcessingStage.live, null), isTrue);
      expect(settings.canActivate(NextProcessingStage.stt, null), isFalse);
      expect(settings.canActivate(NextProcessingStage.live, stt.id), isFalse);
      await expectLater(
        client.activate(settings, NextProcessingStage.stt, stt.id),
        throwsA(NextProcessingFailure.invalid),
      );
      permitted = true;
      await expectLater(
        client.activate(settings, NextProcessingStage.summary, 'model'),
        throwsA(NextProcessingFailure.invalid),
      );
      expect(requests, ['GET /v1/local/processing']);
      final applied = await client.activate(settings, NextProcessingStage.stt, stt.id);
      expect(applied.active(NextProcessingStage.stt)!.name, 'Подготовленный профиль');
      expect(applied.active(NextProcessingStage.stt)!.configurationRevision, 6);
      expect(applied.revision, 8);
      await expectLater(
        client.activate(settings, NextProcessingStage.live, null),
        throwsA(NextProcessingFailure.conflict),
      );
      expect(requests, ['GET /v1/local/processing', 'POST /v1/local/processing/activate']);
    },
  );

  test(
    'conflicting, uncertain or unconfirmed publication consumes approval and requires an explicit refresh',
    () async {
      final published = Completer<void>(), release = Completer<void>();
      int reads = 0, writes = 0;
      final library = await _serve((request) async {
        if (request.method == 'GET') {
          reads++;
          request.response.write(jsonEncode(_registry(7)));
          return;
        }
        await request.drain<void>();
        writes++;
        if (writes == 1) {
          published.complete();
          await release.future;
          request.response.statusCode = 409;
        } else if (writes == 2) {
          request.response.statusCode = 503;
        }
        request.response.write(
          writes == 3
              ? jsonEncode(_registry(8)) // A newer revision carrying an older configuration is insufficient.
              : '{"error":"private provider detail"}',
        );
      });
      final client = library.processingClient();
      var settings = await client.fetch();
      Future<NextProcessingSettings> change() => client.activate(settings, NextProcessingStage.stt, 'current-stt');
      final first = expectLater(change(), throwsA(NextProcessingFailure.conflict));
      await published.future;
      await expectLater(change(), throwsA(NextProcessingFailure.conflict));
      await expectLater(client.fetch(), throwsA(NextProcessingFailure.conflict));
      release.complete();
      await first;
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(change(), throwsA(NextProcessingFailure.conflict));
        settings = await client.fetch();
        await expectLater(change(), throwsA(NextProcessingFailure.indeterminate));
      }
      await expectLater(change(), throwsA(NextProcessingFailure.conflict));
      expect(reads, 3);
      expect(writes, 3);
    },
  );
}
