import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/gen/conversation_wire.g.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/local_next_app.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_page.dart';
import 'package:omi/pages/conversation_detail/widgets/conversation_markdown_widget.dart';
import 'package:omi/pages/conversation_detail/widgets/note_sections_sliver.dart';
import 'package:omi/widgets/transcript.dart';

class _ExistingRecording extends PairedLibrary {
  _ExistingRecording({this.sections = const []}) : super('100.64.0.1', List.filled(43, 'A').join());

  final List<Map<String, dynamic>> sections;

  @override
  Future<GeneratedConversation> detail(String id) async => GeneratedConversation.fromJson({
    'id': id,
    'created_at': '2026-01-01T00:00:00Z',
    'started_at': null,
    'finished_at': null,
    'structured': {'title': 'Fixture meeting', 'overview': 'Meeting summary', 'sections': sections},
    'external_data': {'local_transcript': <String, dynamic>{}},
    'transcript_segments': [
      {'id': 'line-1', 'is_user': true, 'text': 'Fixture utterance', 'start': 62.0, 'end': 63.0},
      {'is_user': false, 'text': 'Legacy first line', 'start': 64.0, 'end': 65.0},
      {'is_user': false, 'text': 'Legacy second line', 'start': 66.0, 'end': 67.0},
    ],
  });
}

Future<void> _openDetail(WidgetTester tester, _ExistingRecording library) async {
  addTearDown(library.close);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RecordingPage(library: library, id: '00000000-0000-4000-8000-000000000001'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a fresh install asks for pairing and reports a rejected key before network access', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(const LocalNextApp());
    await tester.pumpAndSettle();
    expect(find.text('Omi Local Next'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '100.64.0.1');
    await tester.enterText(find.byType(TextField).last, 'short');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid key'), findsOneWidget);
    expect(find.text('Conversations'), findsNothing);
  });

  testWidgets('detail renders the upstream summary and timestamped transcript for an older server', (tester) async {
    await _openDetail(tester, _ExistingRecording());
    expect(find.text('Fixture meeting'), findsOneWidget);
    expect(find.byType(ConversationMarkdownSliver), findsOneWidget);
    expect(find.text('Meeting summary', findRichText: true), findsOneWidget);
    expect(find.text('Play'), findsNothing);
    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Transcript')));
    await tester.pumpAndSettle();
    expect(find.byType(TranscriptWidget), findsOneWidget);
    expect(find.byKey(const ValueKey('transcript-segment-line-1')), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Fixture utterance', findRichText: true), findsOneWidget);
    expect(find.text('Legacy second line', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('1:02'), findsOneWidget);
    expect(find.text('Play'), findsNothing);
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'meeting');
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('Meeting summary'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'UTTERANCE');
    await tester.pump();
    expect(find.text('1:02'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'absent');
    await tester.pump();
    expect(find.text('0/0'), findsOneWidget);
  });

  testWidgets('section citations reach the transcript on an older server without loading Markdown images', (
    tester,
  ) async {
    var networkImageLoads = 0;
    final previousClientProvider = debugNetworkImageHttpClientProvider;
    debugNetworkImageHttpClientProvider = () {
      networkImageLoads++;
      throw StateError('A summary tried to resolve an external image');
    };
    try {
      await _openDetail(
        tester,
        _ExistingRecording(
          sections: [
            {
              'heading': 'Decision',
              'body_markdown':
                  '**Approved**\n\n![tracker](https://fixture.invalid/private.png)'
                  '\n\n![file](file:///unavailable-fixture.png)',
              'source_segment_ids': ['unknown', 'local-next-1', 'line-1', 'line-1'],
            },
          ],
        ),
      );
      expect(find.byType(NoteSectionsSliver), findsOneWidget);
      expect(find.text('Decision', findRichText: true), findsOneWidget);
      expect(find.text('Approved', findRichText: true), findsOneWidget);
      expect(find.descendant(of: find.byType(ConversationMarkdownSliver), matching: find.byType(Image)), findsNothing);
      expect(networkImageLoads, 0);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('section-sources')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('section-source-line-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('section-source-unknown')), findsNothing);
      expect(find.byKey(const ValueKey('section-source-local-next-1')), findsNothing);
      expect(find.text('Fixture utterance', findRichText: true), findsOneWidget);
      expect(find.text('1:02'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('section-source-line-1')));
      await tester.pumpAndSettle();
      expect(find.byType(TranscriptWidget), findsOneWidget);
      expect(tester.widget<TranscriptWidget>(find.byType(TranscriptWidget)).currentSegmentId, 'line-1');
      expect(find.byKey(const ValueKey('transcript-segment-line-1')), findsOneWidget);
      expect(find.text('Play'), findsNothing);
    } finally {
      debugNetworkImageHttpClientProvider = previousClientProvider;
    }
  });
}
