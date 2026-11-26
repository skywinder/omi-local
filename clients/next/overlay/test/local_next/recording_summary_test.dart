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
  List<Map<String, dynamic>> sections = const [];
  SummaryJob? pendingJob;

  @override
  Future<ServerConversation> detail(String id) async => ServerConversation.fromJson({
    'id': id,
    'created_at': '2026-01-02T11:00:00Z',
    'started_at': '2026-01-02T11:00:00Z',
    'finished_at': '2026-01-02T11:01:00Z',
    'status': 'completed',
    'structured': {'title': 'My title', 'overview': overview, 'sections': sections},
    'transcript_segments': [
      {'id': 'line', 'text': 'Edited transcript', 'start': 5.0, 'end': 7.0, 'is_user': true},
    ],
  });

  @override
  Future<RecordingSummaryOptions> readSummaryOptions(String id) async => RecordingSummaryOptions(
    sourceRevision: 'fixture',
    published: (model: 'Published model', templateName: 'Published template'),
    providers: const [
      (
        name: 'Test provider',
        endpoint: RecordingChatProvider(binding: 'bound', host: 'model.example', model: 'fixture'),
      ),
    ],
    templates: const [(id: 'standard', name: 'Default template', prompt: 'Summarize.', digest: 'test-digest')],
    defaultBinding: 'bound',
    defaultTemplate: 'standard',
    job: pendingJob,
  );

  @override
  Future<SummaryJob> readSummaryJob(String id, String requestId) async {
    expect(requestId, pendingJob?.requestId);
    overview = 'Published in background';
    return (requestId: requestId, state: 'ready', error: null, progress: null);
  }

  @override
  Future<void> regenerateSummary(String id, SummaryRegeneration request) async {
    requests.add(request);
    if (requests.length == 1) throw RecordingSummaryFailure.unavailable;
    overview = 'New recap';
  }
}

void main() {
  testWidgets('saved provenance appears beside the recap and opens model selection', (tester) async {
    final library = _SummaryLibrary();
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RecordingPage(id: _id, library: library),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Published template · Published model'), findsOneWidget);
    expect(find.text('Default template'), findsNothing);
    await tester.tap(find.text('Choose template and model'));
    await tester.pumpAndSettle();
    expect(find.text('Default template'), findsWidgets);
    expect(library.requests, isEmpty);
  });

  testWidgets('a failed background recap tells the owner where to fix the model key', (tester) async {
    final library = _SummaryLibrary()
      ..summaryJobsAvailable = true
      ..pendingJob = (requestId: 'existing-request', state: 'failed', error: 'http_401', progress: null);
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RecordingPage(id: _id, library: library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((widget) => widget is PopupMenuButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Regenerate Recap'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Check the provider key on your Local server'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Regenerate Recap')).onPressed, isNotNull);
  });

  testWidgets('opening the background recap resumes an already submitted job', (tester) async {
    final library = _SummaryLibrary()
      ..summaryJobsAvailable = true
      ..pendingJob = (
        requestId: 'existing-request',
        state: 'queued',
        error: null,
        progress: (phase: 'sections', completed: 2, total: 8),
      );
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RecordingPage(id: _id, library: library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((widget) => widget is PopupMenuButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Regenerate Recap'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('The server is preparing the recap'), findsOneWidget);
    expect(find.text('Summarizing transcript sections · 2/8'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.25);
    expect(library.requests, isEmpty);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.textContaining('Published in background', findRichText: true), findsOneWidget);
  });

  testWidgets('a generated note section opens its source in the transcript', (tester) async {
    final library = _SummaryLibrary()
      ..overview = '## Decision\n\nWe will keep a local archive.'
      ..sections = [
        {
          'heading': 'Decision',
          'body_markdown': 'We will keep a local archive.',
          'source_segment_ids': ['line'],
        },
      ];
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RecordingPage(id: _id, library: library),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Decision'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('section-sources')));
    await tester.pumpAndSettle();
    final source = find.byKey(const ValueKey('section-source-line'));
    expect(source, findsOneWidget);
    expect(find.descendant(of: source, matching: find.text('0:05')), findsOneWidget);
    await tester.tap(source);
    await tester.pumpAndSettle();
    expect(source, findsNothing);
    expect(find.textContaining('Edited transcript', findRichText: true), findsOneWidget);
  });

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
