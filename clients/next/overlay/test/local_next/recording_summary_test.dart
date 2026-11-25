import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_chat.dart';
import 'package:omi/local_next/recording_page.dart';
import 'package:omi/local_next/recording_summary.dart';

const _id = '00000000-0000-4000-8000-000000000001';

class _SummaryLibrary extends PairedLibrary {
  _SummaryLibrary() : super('100.64.0.1', List.filled(43, 'A').join()) {
    verified = true;
    recordingEdits = true;
    summaryRegenerationAvailable = true;
  }

  final requests = <SummaryRegeneration>[];
  String overview = 'Old recap';

  @override
  Future<ServerConversation> detail(String id) async => ServerConversation.fromJson({
    'id': id,
    'created_at': '2026-01-02T11:00:00Z',
    'started_at': '2026-01-02T11:00:00Z',
    'finished_at': '2026-01-02T11:01:00Z',
    'status': 'completed',
    'structured': {'title': 'My title', 'overview': overview},
    'transcript_segments': [
      {'id': 'line', 'text': 'Edited transcript', 'start': 5.0, 'end': 7.0, 'is_user': true},
    ],
  });

  @override
  Future<RecordingSummaryOptions> readSummaryOptions(String id) async => const RecordingSummaryOptions(
    sourceRevision: 'fixture',
    providers: [
      (
        name: 'Test provider',
        endpoint: RecordingChatProvider(binding: 'bound', host: 'model.example', model: 'fixture'),
      ),
    ],
    templates: [(id: 'standard', name: 'Default template', prompt: 'Summarize.', digest: 'test-digest')],
    defaultBinding: 'bound',
    defaultTemplate: 'standard',
  );

  @override
  Future<void> regenerateSummary(String id, SummaryRegeneration request) async {
    requests.add(request);
    if (requests.length == 1) throw RecordingSummaryFailure.unavailable;
    overview = 'New recap';
  }
}

void main() {
  testWidgets('regeneration requires consent and retries the original request before refreshing the recap', (
    tester,
  ) async {
    final library = _SummaryLibrary();
    ServerConversation? refreshed;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RecordingPage(id: _id, library: library, onEdited: (row) => refreshed = row),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('My title'), findsOneWidget);
    await tester.tap(find.byWidgetPredicate((widget) => widget is PopupMenuButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Regenerate Recap'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Only decisions.');
    final start = find.widgetWithText(FilledButton, 'Regenerate Recap');

    Future<void> requestConsent() async {
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(find.textContaining('fixture\nmodel.example'), findsOneWidget);
    }

    await requestConsent();
    expect(library.requests, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(library.requests, isEmpty);
    await requestConsent();
    await tester.tap(start.last);
    await tester.pumpAndSettle();
    expect(library.requests.single.prompt, 'Only decisions.');
    expect(library.overview, 'Old recap');
    await requestConsent();
    await tester.tap(start.last);
    await tester.pumpAndSettle();
    expect(library.requests.last, library.requests.first);
    expect(find.text('My title'), findsOneWidget);
    expect(library.overview, 'New recap');
    expect(refreshed?.structured.overview, 'New recap');
  });
}
