import 'dart:async';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/archive.dart';
import 'package:omi/local_next/local_next_app.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_edit.dart';
import 'package:omi/local_next/recording_page.dart';
import 'package:omi/pages/conversations/widgets/conversation_state_tile.dart';
import 'package:omi/pages/conversations/widgets/date_list_item.dart';
import 'package:omi/ui/components/omi_partial_notice.dart';
import 'package:omi/widgets/transcript.dart';

const _firstId = '00000000-0000-4000-8000-000000000001';
const _secondId = '00000000-0000-4000-8000-000000000002';
const _thirdId = '00000000-0000-4000-8000-000000000003';

typedef _Page = ({List<ServerConversation> rows, int consumed, bool partial, bool more});

class _ArchiveLibrary extends PairedLibrary {
  _ArchiveLibrary(this.page, this.record, {this.search, String address = '100.64.0.1'})
    : super(address, List.filled(43, 'A').join()) {
    verified = true;
  }
  final Future<_Page> Function(int) page;
  final ServerConversation record;
  final Future<ArchiveSearchPage?> Function(String, String?, bool)? search;
  final offsets = <int>[];
  final opened = <String>[];

  @override
  Future<_Page> list(int offset, {bool starredOnly = false, String? folderId}) {
    offsets.add(offset);
    return page(offset);
  }

  @override
  Future<ServerConversation> detail(String id) async {
    opened.add(id);
    return record;
  }

  @override
  Future<ArchiveSearchPage?> searchArchive(String query, {String? after, bool byMeaning = false}) =>
      search!(query, after, byMeaning);
}

class _RecoveringLibrary extends _ArchiveLibrary {
  _RecoveringLibrary(super.page, super.record);

  bool online = false;

  @override
  Future<void> verify() async {
    if (!online) throw LibraryFailure.unavailable;
    verified = true;
  }
}

class _RetryLibrary extends _ArchiveLibrary {
  _RetryLibrary(this.failed, this.pending)
    : super((_) async => (rows: [failed], consumed: 1, partial: false, more: false), failed);
  final ServerConversation failed;
  final ServerConversation pending;
  final retries = <String>[];

  @override
  Future<void> retryProcessing(String id) async => retries.add(id);

  @override
  Future<ServerConversation> detail(String id) async => retries.isEmpty ? failed : pending;

  @override
  Future<ServerConversation> refreshSavedRecording(String id) => detail(id);
}

class _PublishingLibrary extends _ArchiveLibrary {
  _PublishingLibrary(ServerConversation pending, this.published)
    : super((_) async => (rows: [pending], consumed: 1, partial: false, more: false), pending) {
    recordingEdits = true;
  }
  final ServerConversation published;
  final refreshes = <String>[];
  final edits = <String>[];

  @override
  Future<void> verify() async {}

  @override
  Future<ServerConversation> refreshSavedRecording(String id) async {
    refreshes.add(id);
    if (refreshes.length == 2) throw LibraryFailure.unavailable;
    return refreshes.length == 1 ? record : published;
  }

  @override
  Future<ServerConversation> editRecording(String id, RecordingEdit edit) async {
    edits.add(id);
    return published;
  }
}

class _GroupedPublishingLibrary extends _ArchiveLibrary {
  _GroupedPublishingLibrary(ServerConversation pending, this.terminal, this.published, this.other)
    : super((_) async => (rows: [pending, published], consumed: 2, partial: false, more: false), pending);

  final ServerConversation terminal;
  final ServerConversation published;
  final ServerConversation other;
  var finished = false;

  @override
  Future<void> verify() async {}

  @override
  Future<ServerConversation> refreshSavedRecording(String id) async => finished ? terminal : record;

  @override
  Future<ServerConversation> detail(String id) async {
    opened.add(id);
    return id == other.id ? other : published;
  }
}

ServerConversation _row(
  String id,
  String title,
  DateTime start, {
  String? localState,
  Map<String, dynamic> recording = const {},
  DateTime? created,
  String category = 'other',
  String emoji = '📌',
  Map<String, dynamic> transcript = const {},
}) => ServerConversation.fromJson({
  'id': id,
  'created_at': (created ?? start).toUtc().toIso8601String(),
  'started_at': start.toUtc().toIso8601String(),
  'finished_at': start.add(const Duration(minutes: 8)).toUtc().toIso8601String(),
  'structured': {'title': title, 'overview': 'Local archive detail', 'emoji': emoji, 'category': category},
  'source': 'phone',
  'status': localState == null ? 'completed' : 'processing',
  'external_data': localState == null
      ? {'local_transcript': transcript}
      : {
          'local_recording': {'status': localState, ...recording},
        },
});

Future<void> _show(WidgetTester tester, PairedLibrary library) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: LocalNextLibraryPage(library: library),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a finished recording opens its result list without reopening itself', (tester) async {
    final date = DateTime.utc(2026, 1, 2);
    final first = _row(_secondId, 'One published conversation', date, transcript: {'recording_results_id': _firstId});
    final second = _row(
      _thirdId,
      'Another published conversation',
      date,
      transcript: {'recording_results_id': _firstId},
    );
    final group = _row(
      _firstId,
      'Recording',
      date,
      localState: 'published',
      recording: {
        'group': true,
        'results': [first.toJson(), second.toJson()],
      },
    );
    final library = _GroupedPublishingLibrary(group, group, first, second)..finished = true;
    addTearDown(library.close);
    await _show(tester, library);
    await tester.pumpAndSettle();
    await tester.tap(find.text('One published conversation'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open recording results'));
    await tester.pumpAndSettle();
    expect(find.text('Recording results'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('Another published conversation'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Open recording results'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('One published conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Recording results'), findsNothing);
    expect(library.opened, [_secondId, _thirdId]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a waiting group keeps the choice open after all recordings publish', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final date = DateTime.utc(2026, 1, 2);
    final first = _row(_secondId, 'First conversation from the group', date);
    final second = _row(_thirdId, 'Second conversation from the group', date.add(const Duration(minutes: 10)));
    final waiting = _row(
      _firstId,
      'Local recording',
      date,
      localState: 'waiting_for_parts',
      recording: {
        'group': true,
        'results': [first.toJson()],
      },
    );
    final done = _row(
      _firstId,
      'Local recording',
      date,
      localState: 'published',
      recording: {
        'group': true,
        'results': [first.toJson(), second.toJson()],
      },
    );
    final library = _GroupedPublishingLibrary(waiting, done, first, second);
    addTearDown(library.close);
    await _show(tester, library);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recording'));
    await tester.pumpAndSettle();
    expect(find.text('Recording results'), findsOneWidget);
    expect(find.text('Waiting for audio from the phone'), findsOneWidget);
    expect(find.text('First conversation from the group'), findsOneWidget);
    expect(find.text('Second conversation from the group'), findsNothing);

    library.finished = true;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for audio from the phone'), findsNothing);
    expect(library.opened, isEmpty);
    await tester.tap(find.text('Second conversation from the group'));
    await tester.pumpAndSettle();
    expect(library.opened, [_thirdId]);
    expect(find.byType(TabBar), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ConversationStateTile), findsNWidgets(2));
    expect(find.text('First conversation from the group'), findsOneWidget);
    expect(find.text('Second conversation from the group'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an open saved recording survives offline, follows publication and replaces its archive row', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final date = DateTime.utc(2026, 1, 2);
    final library = _PublishingLibrary(
      _row(_firstId, 'Processing', date, localState: 'processing'),
      _row(_secondId, 'Finished conversation', date),
    );
    addTearDown(library.close);
    await _show(tester, library);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ConversationStateTile));
    await tester.pumpAndSettle();
    expect(find.byType(RecordingPage), findsOneWidget);
    expect(library.refreshes, [_firstId]);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(library.refreshes, [_firstId, _firstId]);
    expect(find.text('Finished conversation'), findsNothing);
    expect(find.byType(TabBar), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(library.refreshes, [_firstId, _firstId, _firstId]);
    expect(find.text('Finished conversation'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to favorites'));
    await tester.pumpAndSettle();
    expect(library.edits, [_secondId]);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ConversationStateTile), findsOneWidget);
    expect(find.text('Finished conversation'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('only a capable server offers retry and the refreshed pending row loses the action', (tester) async {
    final library = _RetryLibrary(
      _row(
        _firstId,
        'Failed',
        DateTime.utc(2026),
        localState: 'failed',
        recording: {
          'failure': {'stage': 'summary', 'code': 'http_401', 'attempts': 3},
        },
      ),
      _row(_firstId, 'Pending', DateTime.utc(2026), localState: 'pending'),
    );
    Future<void> show(bool available) async {
      library.processingRetryAvailable = available;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RecordingPage(key: ValueKey(available), library: library, id: _firstId),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show(false);
    expect(find.text('Retry processing'), findsNothing);
    await show(true);
    expect(
      find.textContaining('HTTP 401. Check the API key and its permissions for this provider.', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Attempts: 3', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 401', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Retry processing'));
    await tester.pumpAndSettle();
    expect(library.retries, [_firstId]);
    expect(find.text('Retry processing'), findsNothing);
    expect(find.text('Queued for processing'), findsOneWidget);
  });

  testWidgets('local WAV duration survives a truncated transcript on the list and details', (tester) async {
    final start = DateTime.utc(2026, 11, 24);
    final speech = {'id': 'line', 'text': 'Synthetic preview', 'is_user': false, 'start': 0.0, 'end': 14.0};
    ServerConversation row({required bool local, DateTime? finished}) => ServerConversation.fromJson({
      'id': _firstId,
      'created_at': start.toIso8601String(),
      'started_at': start.toIso8601String(),
      'finished_at': finished?.toIso8601String(),
      'structured': {'title': 'Long recording', 'overview': 'Synthetic recap', 'emoji': '🎙️'},
      'source': 'phone',
      'status': 'completed',
      'transcript_segments': [speech],
      if (local)
        'external_data': {
          'local_transcript': {'segment_preview': true},
        },
    });
    final end = start.add(const Duration(minutes: 76, seconds: 46));
    expect(recordingDuration(row(local: false, finished: end)), 14);
    expect(recordingDuration(row(local: true, finished: null)), 14);
    expect(recordingDuration(row(local: true, finished: start.subtract(const Duration(seconds: 1)))), 14);
    final imported = row(local: true, finished: end);
    expect(recordingDuration(imported), 4606);
    SharedPreferences.setMockInitialValues({});
    final library = _ArchiveLibrary(
      (_) async => (rows: [imported], consumed: 1, partial: false, more: false),
      imported,
    );
    await _show(tester, library);
    await tester.pumpAndSettle();
    expect(find.textContaining('1h 16m'), findsOneWidget);
    await tester.tap(find.text('Long recording'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1h 16m'), findsOneWidget);
  });

  test('cold offline archive is scoped to its pairing and a successful empty page clears the cache', () async {
    SharedPreferences.setMockInitialValues({});
    final row = _row(_firstId, 'Saved title', DateTime.utc(2026));
    var offline = false;
    var rows = [row];
    Future<_Page> page(int offset) async {
      if (offline) throw const SocketException('offline fixture');
      return (rows: rows, consumed: rows.length, partial: false, more: false);
    }

    final same = _ArchiveLibrary(page, row);
    final online = PairedArchiveProvider(same);
    await online.refresh();
    online.dispose();
    offline = true;
    final cold = PairedArchiveProvider(same);
    await cold.refresh();
    expect(cold.showingCached, isTrue);
    expect(cold.rowById(_firstId)?.structured.title, 'Saved title');
    final other = PairedArchiveProvider(_ArchiveLibrary(page, row, address: '100.64.0.2'));
    await other.refresh();
    expect(other.entries, isEmpty);
    offline = false;
    rows = [];
    await cold.recoverAfterServerCheck();
    expect(cold.showingCached, isFalse);
    offline = true;
    await cold.refresh();
    expect(cold.entries, isEmpty);
    cold.dispose();
    other.dispose();
    same.close();
  });

  testWidgets('the open archive recovers on the next successful profile check without a tap', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final row = _row(_firstId, 'Available again', DateTime.utc(2026));
    final library = _RecoveringLibrary((_) async => (rows: [row], consumed: 1, partial: false, more: false), row)
      ..verified = false;
    await _show(tester, library);
    expect(find.text('Available again'), findsNothing);
    expect(library.offsets, isEmpty);
    library.online = true;
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(find.text('Available again'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(library.offsets, [0]);
    await tester.pumpWidget(const SizedBox());
    library.close();
  });

  test('reconnection retries the interrupted page once and keeps the already loaded cards', () async {
    final row = _row(_firstId, 'First page', DateTime.utc(2026));
    final older = _row(_secondId, 'Older page', DateTime.utc(2025));
    var online = true;
    final library = _ArchiveLibrary((offset) async {
      if (!online) throw const SocketException('offline fixture');
      return (rows: [offset == 0 ? row : older], consumed: 1, partial: false, more: offset == 0);
    }, row);
    final archive = PairedArchiveProvider(library);
    addTearDown(archive.dispose);
    addTearDown(library.close);
    await archive.refresh();
    online = false;
    await archive.loadMore();
    online = true;
    await Future.wait([archive.recoverAfterServerCheck(), archive.recoverAfterServerCheck()]);
    await archive.recoverAfterServerCheck();
    expect(library.offsets, [0, 1, 1]);
    expect(archive.rowById(_firstId), row);
    expect(archive.rowById(_secondId), older);
    expect(archive.failure, isNull);
  });

  testWidgets('failed card identifies the recording phone and the failed provider stage', (tester) async {
    final row = _row(
      _firstId,
      'Test',
      DateTime.utc(2026),
      localState: 'failed',
      recording: {
        'origin': {'phone_platform': 'ios', 'phone_model': 'iPhone Air'},
        'failure': {'stage': 'summary', 'code': 'http_503', 'attempts': 3},
      },
    );
    final library = _ArchiveLibrary((_) async => (rows: [row], consumed: 1, partial: false, more: false), row);
    await _show(tester, library);
    expect(find.textContaining('iPhone Air · Phone microphone'), findsOneWidget);
    expect(find.textContaining('HTTP 503'), findsOneWidget);
    expect(find.textContaining('Attempts: 3'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    library.close();
  });

  testWidgets('category labels retain the subject emoji and filtering can reach older matching recordings', (
    tester,
  ) async {
    final time = DateTime.utc(2026, 1, 2);
    final work = _row(_firstId, 'Work recording', time, category: 'work', emoji: '💻');
    final personal = _row(_secondId, 'Older personal recording', time, category: 'personal', emoji: '🎙️');
    final library = _ArchiveLibrary((offset) async {
      return (rows: [offset == 0 ? work : personal], consumed: 1, partial: false, more: offset == 0);
    }, personal);
    addTearDown(library.close);
    await _show(tester, library);
    expect(find.text('💻'), findsOneWidget);
    expect(find.textContaining('· Work'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('archive-category')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'person');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-category-work')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('conversation-category-personal')));
    await tester.pumpAndSettle();
    expect(find.text('Work recording'), findsNothing);
    await tester.tap(find.text('show more ↓'));
    await tester.pumpAndSettle();
    expect(library.offsets, [0, 0, 1]);
    expect(find.text('Older personal recording'), findsOneWidget);
    expect(find.text('👤'), findsOneWidget);
  });

  testWidgets('a durable delivery refreshes the archive and follows local processing to its result', (tester) async {
    final time = DateTime.utc(2026, 1, 2);
    final existing = _row(_firstId, 'Existing', time);
    final pending = _row(_secondId, 'Pending', time, localState: 'pending');
    final completed = _row(_secondId, 'Completed', time);
    var outcome = 0;
    final library = _ArchiveLibrary((_) async {
      if (outcome == 1) throw LibraryFailure.unavailable;
      final rows = [existing, if (outcome == 2) pending, if (outcome == 3) completed];
      return (rows: rows, consumed: rows.length, partial: false, more: false);
    }, completed);
    var visible = true;
    final archive = PairedArchiveProvider(library, canRefreshRecordings: () => visible);
    try {
      await archive.refresh();
      outcome = 1;
      archive.refreshAfterRecording();
      archive.refreshAfterRecording();
      await tester.pump(const Duration(milliseconds: 1));
      expect(library.offsets, [0, 0]);
      expect(archive.rowById(_firstId), existing);
      expect(archive.failure, isNull);
      outcome = 2;
      visible = false;
      await tester.pump(const Duration(seconds: 5));
      expect(library.offsets, [0, 0]);
      visible = true;
      await tester.pump(const Duration(seconds: 5));
      expect(archive.rowById(_secondId), pending);
      outcome = 3;
      await tester.pump(const Duration(seconds: 5));
      expect(archive.rowById(_secondId), completed);
      await tester.pump(const Duration(seconds: 10));
      expect(library.offsets, [0, 0, 0, 0]);
    } finally {
      archive.dispose();
      library.close();
    }
  });

  testWidgets('scrubbing a paired WAV moves the transcript and clears the highlight in silence', (tester) async {
    final time = DateTime.utc(2026);
    final row = ServerConversation.fromJson({
      'id': _firstId,
      'created_at': time.toIso8601String(),
      'started_at': time.toIso8601String(),
      'finished_at': time.add(const Duration(seconds: 12)).toIso8601String(),
      'structured': {'title': 'Playback'},
      'external_data': {'local_transcript': <String, dynamic>{}},
      'transcript_segments': [
        {'id': 'first', 'text': 'Opening', 'start': 1.0, 'end': 3.0, 'is_user': true},
        {'id': 'second', 'text': 'Closing', 'start': 8.0, 'end': 11.0, 'is_user': true},
      ],
    });
    final library = _ArchiveLibrary((_) async => (rows: [row], consumed: 1, partial: false, more: false), row)
      ..audioPlayback = true;
    addTearDown(library.close);
    await _show(tester, library);
    await tester.tap(find.text('Playback'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transcript').first);
    await tester.pumpAndSettle();
    TranscriptWidget transcript() => tester.widget<TranscriptWidget>(find.byType(TranscriptWidget));
    final slider = find.byType(Slider);
    expect(transcript().currentSegmentId, isNull);
    final bounds = tester.getRect(slider).deflate(24);
    for (final (fraction, segment) in [(0.75, 'second'), (0.5, null), (0.16, 'first')]) {
      await tester.tapAt(Offset(bounds.left + fraction * bounds.width, bounds.center.dy));
      await tester.pumpAndSettle();
      expect(transcript().currentSegmentId, segment);
    }
    await tester.tapAt(Offset(bounds.left + 0.75 * bounds.width, bounds.center.dy));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Forward 10 seconds'));
    await tester.pumpAndSettle();
    expect(find.text('0:12 / 0:12'), findsOneWidget);
    await tester.tap(find.byTooltip('Back 10 seconds'));
    await tester.pumpAndSettle();
    expect(transcript().currentSegmentId, 'first');
    await tester.tap(find.text('1.0×'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5×'));
    await tester.pumpAndSettle();
    expect(find.text('1.5×'), findsOneWidget);
    expect(find.byTooltip('Play'), findsOneWidget);
  });

  testWidgets('archive search crosses an empty storage page and opens the matching transcript line', (tester) async {
    final time = DateTime.utc(2026, 1, 2);
    final row = ServerConversation.fromJson({
      'id': _secondId,
      'created_at': time.toIso8601String(),
      'started_at': time.toIso8601String(),
      'finished_at': time.add(const Duration(seconds: 6)).toIso8601String(),
      'structured': {'title': 'Older saved recording'},
      'transcript_segments': [
        {'id': 'first', 'text': 'Opening words', 'start': 0.0, 'end': 2.0, 'is_user': true},
        {'id': 'hit', 'text': 'Matching words', 'start': 4.25, 'end': 6.0, 'is_user': true},
      ],
    });
    final requests = <(String, String?)>[];
    final library = _ArchiveLibrary(
      (_) async => (rows: <ServerConversation>[], consumed: 0, partial: false, more: false),
      row,
      search: (query, cursor, byMeaning) async {
        expect(byMeaning, isFalse);
        requests.add((query, cursor));
        if (cursor == null) return (hits: <ArchiveSearchHit>[], nextCursor: _firstId);
        return (
          hits: [
            (
              id: row.id,
              title: row.structured.title,
              startedAt: time,
              snippets: [const TranscriptMatchSnippet(text: 'Matching words', segmentId: 'hit', start: 4.25)],
            ),
          ],
          nextCursor: null,
        );
      },
    );
    await _show(tester, library);
    await tester.tap(find.byTooltip('Search conversations'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'matching');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(requests, [('matching', null), ('matching', _firstId)]);
    await tester.tap(find.text('Matching words'));
    await tester.pumpAndSettle();
    expect(library.opened, [_secondId]);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller?.index, 1);
    expect(tester.widget<TranscriptWidget>(find.byType(TranscriptWidget)).followTargetSegmentId, 'hit');
    expect(find.textContaining('Matching words', findRichText: true), findsOneWidget);
  });

  testWidgets('meaning search waits for submission and keeps the ranked order', (tester) async {
    final time = DateTime.utc(2026, 1, 2);
    final older = _row(_firstId, 'Relevant older result', time);
    final newer = _row(_secondId, 'Newer result', time.add(const Duration(days: 1)));
    var requests = 0;
    final library = _ArchiveLibrary(
      (_) async => (rows: <ServerConversation>[], consumed: 0, partial: false, more: false),
      older,
      search: (query, cursor, byMeaning) async {
        expect(byMeaning, isTrue);
        expect(cursor, isNull);
        expect(query, 'borrow money');
        if (++requests == 1) return null;
        return (
          hits: [
            (id: older.id, title: older.structured.title, startedAt: time, snippets: <TranscriptMatchSnippet>[]),
            (
              id: newer.id,
              title: newer.structured.title,
              startedAt: time.add(const Duration(days: 1)),
              snippets: <TranscriptMatchSnippet>[],
            ),
          ],
          nextCursor: null,
        );
      },
    );
    await _show(tester, library);
    await tester.tap(find.byTooltip('Search conversations'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Meaning'));
    await tester.enterText(find.byType(TextField), 'borrow money');
    await tester.pumpAndSettle();
    expect(requests, 0);
    await tester.tap(find.text('Find by meaning'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Semantic search is unavailable'), findsOneWidget);
    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Relevant older result')).dy,
      lessThan(tester.getTopLeft(find.text('Newer result')).dy),
    );
  });

  testWidgets('paired feed groups by local start date and opens a selected archive row after an older-page retry', (
    tester,
  ) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 9);
    final yesterday = DateTime(now.year, now.month, now.day - 1, 22);
    final early = _row(_firstId, 'Earlier today', today);
    final late = _row(_secondId, 'Later today', today.add(const Duration(hours: 2)));
    final pending = _row(
      _thirdId,
      'Wire placeholder',
      yesterday,
      localState: 'pending',
      created: today.add(const Duration(hours: 3)),
    );
    var firstAppend = true;
    final library = _ArchiveLibrary((offset) async {
      if (offset == 0) return (rows: [pending, early], consumed: 3, partial: true, more: true);
      if (firstAppend) {
        firstAppend = false;
        throw LibraryFailure.unavailable;
      }
      return (rows: [early, late], consumed: 2, partial: false, more: false);
    }, late);
    addTearDown(library.close);
    await _show(tester, library);
    await tester.pumpAndSettle();
    expect(tester.widgetList<DateListItem>(find.byType(DateListItem)).map((h) => h.date), [
      DateTime(today.year, today.month, today.day),
      DateTime(yesterday.year, yesterday.month, yesterday.day),
    ]);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.byType(ConversationStateTile), findsNWidgets(2));
    expect(find.text('📌'), findsNWidgets(2));
    expect(find.text('Recording'), findsOneWidget);
    expect(find.textContaining(' · Pending'), findsOneWidget);
    expect(find.text('Wire placeholder'), findsNothing);
    expect(find.byType(OmiPartialNotice), findsOneWidget);
    await tester.tap(find.text('show more ↓'));
    await tester.pumpAndSettle();
    expect(library.offsets, [0, 3]);
    expect(find.text('Earlier today'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search_partial_retry')));
    await tester.pumpAndSettle();
    expect(library.offsets, [0, 3, 3]);
    expect(find.byType(DateListItem), findsNWidgets(2));
    expect(find.text('Earlier today'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Later today')).dy, lessThan(tester.getTopLeft(find.text('Earlier today')).dy));
    expect(find.text('show more ↓'), findsNothing);
    await tester.drag(find.text('Later today'), const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsNothing);
    expect(library.opened, isEmpty);
    await tester.tap(find.text('Later today'));
    await tester.pumpAndSettle();
    expect(find.byType(RecordingPage), findsOneWidget);
    expect(library.opened, [_secondId]);
    expect(find.text('Local archive detail', findRichText: true), findsOneWidget);
  });

  testWidgets('a delayed prior pairing cannot repopulate the displayed archive and revoked access clears its rows', (
    tester,
  ) async {
    final stale = _row(_firstId, 'Old server', DateTime(2026, 1, 1));
    final current = _row(_secondId, 'Current server', DateTime(2026, 1, 2));
    final oldPage = Completer<_Page>();
    final old = _ArchiveLibrary((_) => oldPage.future, stale);
    var revoked = false;
    final next = _ArchiveLibrary(
      (_) async {
        if (revoked) throw LibraryFailure.key;
        return (rows: [current], consumed: 1, partial: false, more: false);
      },
      current,
      address: '100.64.0.2',
    );
    addTearDown(old.close);
    addTearDown(next.close);
    await _show(tester, old);
    await _show(tester, next);
    oldPage.complete((rows: [stale], consumed: 1, partial: false, more: false));
    await tester.pumpAndSettle();
    expect(find.text('Current server'), findsOneWidget);
    expect(find.text('Old server'), findsNothing);
    revoked = true;
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Current server'), findsNothing);
    expect(find.text('Invalid key'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
