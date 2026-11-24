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
  test('editor probes and saves prepared network adapters, preserves key identity, deletes by revision only', () async {
    int revision = 7;
    final prepared = _profile('stt', 'local', 'Prepared local', revision: 1);
    final remote = {
      'id': 'remote',
      'name': 'Remote',
      'stage': 'stt',
      'kind': 'openai-compatible',
      'has_key': true,
      'can_edit': true,
      'configuration_revision': 3,
      'settings': {
        'provider_url': 'https://stt.example:443/v1',
        'language': 'en',
        'model': 'm0',
        'device': 'cpu',
        'diarization_model': 'none',
      },
    };
    final cards = <Map<String, dynamic>>[prepared, remote];
    final seen = <({String method, String path, Map body})>[];
    final library = await _serve((request) async {
      final path = request.uri.path;
      final body = request.method == 'GET'
          ? <String, dynamic>{}
          : jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      seen.add((method: request.method, path: path, body: body));
      if (path.endsWith('/models') || path.endsWith('/probe')) {
        request.response.write(
          jsonEncode({
            'state': 'available',
            'message': 'private diagnostic',
            'latency_ms': 12,
            'models': ['m0', 'm1'],
          }),
        );
        return;
      }
      if (path.endsWith('/save')) {
        final card = Map<String, dynamic>.from(body['profile'] as Map);
        card['id'] ??= 'added';
        card['can_edit'] = true;
        card['has_key'] = body['clear_key'] != true && (card['id'] == 'remote' || body['api_key'] != null);
        card['configuration_revision'] = ++revision;
        cards.removeWhere((old) => old['id'] == card['id']);
        cards.add(card);
      } else if (request.method == 'DELETE') {
        cards.removeWhere((card) => card['id'] == request.uri.pathSegments.last);
        revision++;
      }
      request.response.write(
        jsonEncode({
          'revision': revision,
          'profiles': cards,
          'effective': {'live': null, 'stt': prepared, 'diarization': null, 'summary': null, 'translation': null},
        }),
      );
    });
    final client = library.processingClient();
    var data = await client.fetch();
    final original = data.profiles.singleWhere((p) => p.id == 'remote');
    expect(original.editableDraft!.device, 'cpu');
    expect(original.hasKey, isTrue);
    expect(data.active(NextProcessingStage.stt)!.editableDraft, isNull);
    expect(data.canDelete(data.profiles.first), isFalse);
    const edited = NextProcessingDraft(
      stage: NextProcessingStage.stt,
      id: 'remote',
      name: 'Remote updated',
      endpoint: 'https://stt.example:443/next/v1',
      model: 'm1',
    );
    const changed = NextProcessingDraft(
      stage: NextProcessingStage.stt,
      id: 'remote',
      name: 'Remote',
      endpoint: 'https://stt.example/v1',
    );
    expect(edited.needsKeyDecision(original), isFalse);
    expect(changed.needsKeyDecision(original), isTrue); // Explicit default port is part of the registry identity.
    await expectLater(client.models(data, changed), throwsA(NextProcessingFailure.invalid));
    final catalog = await client.models(data, changed, apiKey: ' fixture-replacement ');
    expect(catalog.models, ['m0', 'm1']);
    expect(catalog.latencyMs, 12);
    expect(seen.last.body.containsKey('revision'), isFalse);
    expect(seen.last.body['api_key'], 'fixture-replacement');
    final check = await client.probe(data, edited, clearKey: true);
    expect(check.state, NextProbeState.available);
    expect(seen.last.body['clear_key'], isTrue);
    expect(seen.last.body.containsKey('api_key'), isFalse);
    data = await client.save(data, edited);
    expect(data.active(NextProcessingStage.stt)!.id, 'local');
    final saved = data.profiles.singleWhere((p) => p.id == 'remote');
    expect(saved.hasKey, isTrue);
    expect(saved.editableDraft!.model, 'm1');
    expect(seen.last.body.keys, unorderedEquals(['revision', 'profile']));
    expect(seen.last.body['revision'], 7);
    expect(seen.last.body['profile']['settings']['device'], 'cpu');
    const added = NextProcessingDraft(
      stage: NextProcessingStage.diarization,
      name: 'Speakers',
      endpoint: 'https://diarization.example',
      minSpeakers: 2,
      maxSpeakers: 4,
    );
    data = await client.save(data, added);
    expect(seen.last.body['profile']['settings'], {
      'base_url': 'https://diarization.example',
      'min_speakers': 2,
      'max_speakers': 4,
    });
    expect(seen.last.body['profile'].containsKey('id'), isFalse);
    final addedCard = data.profiles.singleWhere((p) => p.id == 'added');
    expect(addedCard.hasKey, isFalse);
    data = await client.delete(data, addedCard);
    expect(seen.last.method, 'DELETE');
    expect(seen.last.path, '/v1/local/processing/profiles/added');
    expect(seen.last.body, {'revision': 9});
    expect(data.active(NextProcessingStage.diarization), isNull);
    expect(seen.map((r) => r.path.split('/').last), ['processing', 'models', 'probe', 'save', 'save', 'added']);
  });

  test('prepared IDs and active drafts remain guarded; wrong save confirmation requires refresh', () async {
    final live = {
      'id': 'live',
      'stage': 'live',
      'kind': 'external',
      'name': 'Live',
      'can_edit': true,
      'has_key': true,
      'settings': {'url': 'wss://capture.example/asr'},
    };
    final locked = {
      ...live,
      'id': 'locked',
      'name': 'Host-managed',
      'settings': {'url': 'wss://capture.example/asr', 'python': 'private'},
    };
    final base = {
      'revision': 1,
      'profiles': [live, locked],
      'effective': {'live': live},
    };
    final calls = <NextDraftOperation>[];
    final client = NextProcessingClient(
      read: () async => base,
      activatePrepared: (_) async => throw StateError('unexpected'),
      draftRequest: (op, body, id) async {
        calls.add(op);
        return {
          'revision': 2,
          'profiles': [live, locked],
          'effective': {'live': live},
        };
      },
    );
    var data = await client.fetch();
    final active = data.profiles.first, host = data.profiles.last;
    expect(active.canEdit, isTrue);
    expect(host.canEdit, isFalse);
    final legacy = NextProcessingSettings.fromJson({
      'revision': 1,
      'profiles': [
        {
          ...live,
          'settings': {'url': 'wss://capture.example/asr?auth=fixture'},
        },
      ],
      'effective': {'live': null},
    });
    expect(legacy.profiles.single.editableDraft, isNull);
    await expectLater(client.delete(data, active), throwsA(NextProcessingFailure.invalid));
    await expectLater(client.delete(data, host), throwsA(NextProcessingFailure.invalid));
    const pretendsEditable = NextProcessingDraft(
      stage: NextProcessingStage.live,
      id: 'locked',
      name: 'Host-managed',
      endpoint: 'wss://capture.example/asr',
    );
    await expectLater(client.save(data, pretendsEditable), throwsA(NextProcessingFailure.invalid));
    await expectLater(client.models(data, active.editableDraft!), throwsA(NextProcessingFailure.invalid));
    expect(calls, isEmpty);
    await expectLater(client.save(data, active.editableDraft!), throwsA(NextProcessingFailure.indeterminate));
    await expectLater(client.save(data, active.editableDraft!), throwsA(NextProcessingFailure.conflict));
    expect(calls, [NextDraftOperation.save]);
    data = await client.fetch();
    expect(data.revision, 1);
  });

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
