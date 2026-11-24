import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_chat.dart';
import 'package:omi/local_next/recording_page.dart';
import 'package:omi/models/chat_evidence_reference.dart';
import 'package:omi/widgets/transcript.dart';

const _id = '00000000-0000-4000-8000-000000000001';

class _ChatLibrary extends PairedLibrary {
  _ChatLibrary() : super('100.64.0.1', List.filled(43, 'A').join());
  final turns = <RecordingChatTurn>[];
  int detailReads = 0;

  @override
  Future<ServerConversation> detail(String id) async {
    detailReads++;
    return ServerConversation.fromJson({
      'id': id,
      'created_at': '2026-01-02T11:00:00Z',
      'started_at': '2026-01-02T11:00:00Z',
      'finished_at': '2026-01-02T11:01:00Z',
      'structured': {'title': 'Synthetic plan'},
      'transcript_segments': [
        {'id': 'plan', 'text': 'Accepted the plan.', 'start': 4.25, 'end': 6.0, 'is_user': true},
      ],
    });
  }

  @override
  Future<RecordingChatPageData?> readRecordingChat(String id, {int? before}) async => RecordingChatPageData(
    turns: turns,
    nextBefore: null,
    provider: const RecordingChatProvider(binding: 'selected', host: 'model.example', model: 'test-model'),
    hasTranscript: true,
  );

  @override
  Future<RecordingChatTurn> askRecordingChat({
    required String id,
    required String turnId,
    required String? previous,
    required String binding,
    required String question,
  }) async {
    expect(id, _id);
    expect(binding, 'selected');
    expect(previous, isNull);
    final turn = RecordingChatTurn(
      id: turnId,
      question: question,
      answer: 'Yes, the plan was accepted.',
      contextLimited: false,
      references: const [
        ChatEvidenceReference(
          id: 'ref',
          kind: ChatEvidenceReferenceKind.conversationSegment,
          state: ChatEvidenceReferenceState.available,
          conversationId: _id,
          segmentId: 'plan',
          startMs: 4250,
          summary: 'Accepted the plan.',
        ),
      ],
    );
    turns.insert(0, turn);
    return turn;
  }
}

void main() {
  testWidgets('chat obtains consent for the configured model and returns to the sourced line', (tester) async {
    final library = _ChatLibrary();
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RecordingPage(library: library, id: _id),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chat_bubble_outline));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Was the plan accepted?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('model.example'), findsWidgets);
    expect(library.turns, isEmpty);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
    await tester.pumpAndSettle();
    expect(find.text('Yes, the plan was accepted.'), findsOneWidget);
    await tester.tap(find.text('Accepted the plan.'));
    await tester.pumpAndSettle();
    expect(library.detailReads, 2);
    expect(find.byType(TabBar), findsOneWidget);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller?.index, 1);
    expect(find.byType(TranscriptWidget), findsOneWidget);
    expect(tester.widget<TranscriptWidget>(find.byType(TranscriptWidget)).followTargetSegmentId, 'plan');
    expect(find.textContaining('Accepted the plan.', findRichText: true), findsOneWidget);
  });
}
