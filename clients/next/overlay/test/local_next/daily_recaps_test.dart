import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/daily_summary.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/daily_recap.dart';
import 'package:omi/local_next/local_next_app.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_chat.dart';

const _source = '00000000-0000-4000-8000-000000000001';

class _DailyLibrary extends PairedLibrary {
  _DailyLibrary() : super('100.64.0.1', List.filled(43, 'A').join()) {
    verified = true;
    dailyRecapsAvailable = true;
  }

  final requests = <String>[];
  LocalDailyRecap? saved;

  @override
  Future<({List<ServerConversation> rows, int consumed, bool partial, bool more})> list(
    int offset, {
    bool starredOnly = false,
    String? folderId,
  }) async => (rows: <ServerConversation>[], consumed: 0, partial: false, more: false);

  @override
  Future<ServerConversation> detail(String id) async {
    expect(id, _source);
    return ServerConversation.fromJson({
      'id': id,
      'created_at': '2026-01-02T11:00:00Z',
      'started_at': '2026-01-02T11:00:00Z',
      'finished_at': '2026-01-02T11:01:00Z',
      'structured': {'title': 'Source recording'},
    });
  }

  @override
  Future<List<LocalDailyRecap>> listDailyRecaps(int offset) async => [if (saved != null) saved!];

  @override
  Future<DailyRecapPreview> previewDailyRecap(DateTime date) async => const DailyRecapPreview(
    revision: 'fixture-revision',
    provider: RecordingChatProvider(binding: 'bound', host: 'model.example', model: 'fixture'),
    count: 2,
    sourceCount: 1,
    limited: true,
  );

  @override
  Future<LocalDailyRecap> generateDailyRecap(DateTime date, DailyRecapPreview preview, String id) async {
    requests.add(id);
    if (requests.length == 1) throw DailyRecapFailure.unavailable;
    return saved = LocalDailyRecap(
      summary: DailySummary(
        id: 'local',
        date: dailyRecapDay(date)['day']!,
        createdAt: date,
        headline: 'Today’s decisions',
        overview: 'Synthetic recap',
        stats: DayStats(totalConversations: 2),
        highlights: [
          TopicHighlight(topic: 'Budget', emoji: '', summary: 'Approved', conversationIds: [_source]),
        ],
      ),
      sourceIds: const [_source],
      limited: true,
    );
  }
}

void main() {
  testWidgets('daily recap waits for model consent, retries the same request, and opens a cited recording', (
    tester,
  ) async {
    final library = _DailyLibrary();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LocalNextLibraryPage(library: library, disconnect: () async {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Daily Recaps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create a day recap'));
    await tester.pumpAndSettle();
    expect(find.textContaining('fixture\nmodel.example'), findsOneWidget);
    expect(library.requests, isEmpty);
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(library.requests, hasLength(1));
    await tester.tap(find.text('Create a day recap'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(library.requests, [library.requests.first, library.requests.first]);
    expect(find.text('Synthetic recap'), findsOneWidget);
    expect(find.text('This recap covers part of the day’s recordings.'), findsOneWidget);
    await tester.tap(find.text('Open source recording · 1'));
    await tester.pumpAndSettle();
    expect(find.text('Source recording'), findsOneWidget);
  });
}
