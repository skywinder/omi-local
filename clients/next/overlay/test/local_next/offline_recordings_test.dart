import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/offline_recordings.dart';
import 'package:omi/local_next/offline_recordings_page.dart';
import 'package:omi/local_next/paired_library.dart';

const _id = '7bbadf12-0000-4000-8100-000000000001';
const _otherId = '7bbadf12-0000-4000-8100-000000000002';
const _firstOwner = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _secondOwner = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

ServerConversation _conversation(String id) => ServerConversation.fromJson({
  'id': id,
  'created_at': '2026-01-02T11:00:00Z',
  'started_at': '2026-01-02T11:00:00Z',
  'finished_at': '2026-01-02T11:00:20Z',
  'status': 'completed',
  'source': 'phone',
  'structured': {'title': 'Download fixture', 'overview': 'Offline summary'},
  'transcript_segments': [
    {'id': 'line', 'text': 'Saved text with a timestamp', 'start': 7, 'end': 14, 'is_user': false},
  ],
  'external_data': {
    'local_transcript': {'recording_results_id': _otherId, 'private_provider_setting': 'never saved'},
  },
});

Future<int> _audio(File file, int remaining) async {
  const length = 900;
  if (remaining < length) throw OfflineRecordingFailure.limit;
  await file.writeAsBytes(List.filled(length, 0));
  return length;
}

class _OfflineLibrary extends PairedLibrary {
  _OfflineLibrary(this._records) : super('100.64.1.2', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');

  final NextOfflineRecordings _records;
  @override
  NextOfflineRecordings get offlineRecordings => _records;
  int detailRequests = 0;

  @override
  Future<ServerConversation> detail(String id) async {
    detailRequests++;
    throw LibraryFailure.unavailable;
  }
}

void main() {
  late Directory directory;
  setUp(() async => directory = await Directory.systemTemp.createTemp('next-offline-test-'));
  tearDown(() => directory.delete(recursive: true));
  NextOfflineRecordings store(String owner, {int limit = NextOfflineRecordings.byteLimit}) =>
      NextOfflineRecordings(owner, directory: () async => directory, limit: limit);

  test('a partial download and revocation leave no readable copy; the device limit spans owners', () async {
    final one = store(_firstOwner, limit: 2500);
    final two = store(_secondOwner, limit: 2500);
    await expectLater(
      one.save(
        _id,
        load: () async => _conversation(_id),
        canPublish: () => true,
        download: (target, _) async {
          await target.writeAsBytes([1, 2, 3]);
          throw const SocketException('fixture disconnected');
        },
      ),
      throwsA(isA<SocketException>()),
    );
    expect(await one.read(_id), isNull);
    expect(await one.list(), isEmpty);

    var permitted = true;
    await expectLater(
      one.save(
        _id,
        load: () async => _conversation(_id),
        canPublish: () => permitted,
        download: (target, _) async {
          final bytes = await _audio(target, 900);
          permitted = false;
          return bytes;
        },
      ),
      throwsA(OfflineRecordingFailure.unavailable),
    );
    expect(await one.list(), isEmpty);

    final begin = Completer<void>();
    final publish = Completer<void>();
    final first = one.save(
      _id,
      load: () async => _conversation(_id),
      canPublish: () => true,
      download: (target, budget) async {
        begin.complete();
        await publish.future;
        return _audio(target, budget);
      },
    );
    await begin.future;
    expect(await one.list(), isEmpty); // Both files are still in a staging directory.
    final second = two.save(
      _otherId,
      load: () async => _conversation(_otherId),
      canPublish: () => true,
      download: _audio,
    );
    final rejected = expectLater(second, throwsA(OfflineRecordingFailure.limit));
    publish.complete();
    await first;
    await rejected;
    expect(await two.read(_id), isNull);
    final saved = (await store(_firstOwner).list()).single;
    expect((await saved.readDetail()).transcriptSegments.single.start, 7);
    expect((await saved.readDetail()).externalIntegration?.localTranscript, isEmpty);
    await one.remove(_id);
    await two.save(_otherId, load: () async => _conversation(_otherId), canPublish: () => true, download: _audio);
    await one.clear();
    expect(await two.list(), hasLength(1));
  });

  testWidgets('downloaded list opens a read-only transcript without a request to the paired server', (tester) async {
    final records = store(_firstOwner);
    final library = _OfflineLibrary(records);
    addTearDown(library.close);
    await tester.runAsync(
      () => records.save(_id, load: () async => _conversation(_id), download: _audio, canPublish: () => true),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OfflineRecordingsPage(library: library),
        ),
      );
    });
    for (var i = 0; i < 10 && find.text('Download fixture').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump();
    }
    await tester.runAsync(() async {
      await tester.tap(find.text('Download fixture'));
      await tester.pump();
    });
    for (var i = 0; i < 10 && find.text('Offline copy').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump();
    }
    expect(find.text('Offline copy'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Play'), findsOneWidget);
    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved text with a timestamp', findRichText: true), findsOneWidget);
    expect(library.detailRequests, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
