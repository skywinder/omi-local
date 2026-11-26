import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/archive_search_page.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_chat.dart';
import 'package:omi/local_next/recording_chat_page.dart';
import 'package:omi/local_next/recording_page.dart';
import 'package:omi/models/chat_evidence_reference.dart';
import 'package:omi/widgets/transcript.dart';

const _id = '00000000-0000-4000-8000-000000000001';
const _secondId = '00000000-0000-4000-8000-000000000002';

class _ChatLibrary extends PairedLibrary {
  _ChatLibrary() : super('100.64.0.1', List.filled(43, 'A').join());
  final turns = <RecordingChatTurn>[];
  int detailReads = 0;
  final opened = <String>[];

  @override
  Future<ServerConversation> detail(String id) async {
    detailReads++;
    opened.add(id);
    return ServerConversation.fromJson({
      'id': id,
      'created_at': '2026-01-02T11:00:00Z',
      'started_at': '2026-01-02T11:00:00Z',
      'finished_at': '2026-01-02T11:01:00Z',
      'structured': {'title': 'Synthetic plan'},
      'transcript_segments': [
        if (id == _secondId)
          {'id': 'april', 'text': 'The follow-up was in April.', 'start': 17.0, 'end': 19.0, 'is_user': true}
        else
          {'id': 'plan', 'text': 'Accepted the plan.', 'start': 4.25, 'end': 6.0, 'is_user': true},
      ],
    });
  }

  @override
  Future<RecordingChatPageData?> readRecordingChat(String? id, {int? before}) async => RecordingChatPageData(
    turns: turns,
    nextBefore: null,
    provider: const RecordingChatProvider(binding: 'selected', host: 'model.example', model: 'test-model'),
    hasTranscript: true,
  );

  @override
  Future<RecordingChatTurn> askRecordingChat({
    required String? id,
    required String turnId,
    required String? previous,
    required String binding,
    required String question,
    List<RecordingChatTurn> history = const [],
    bool storeArchive = false,
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

class _ArchiveChatLibrary extends _ChatLibrary {
  _ArchiveChatLibrary({this.stored = false});
  final bool stored;
  final priorQuestions = <List<String>>[];
  final previousIds = <String?>[];
  final cursors = <int?>[];
  RecordingChatTurn? older;

  @override
  Future<RecordingChatPageData?> readRecordingChat(String? id, {int? before}) async {
    cursors.add(before);
    return RecordingChatPageData(
      turns: before == null ? turns : [older!],
      nextBefore: before == null && older != null ? 4 : null,
      provider: const RecordingChatProvider(binding: 'selected', host: 'model.example', model: 'test-model'),
      hasTranscript: true,
      storedHistory: stored,
    );
  }

  @override
  Future<RecordingChatTurn> askRecordingChat({
    required String? id,
    required String turnId,
    required String? previous,
    required String binding,
    required String question,
    List<RecordingChatTurn> history = const [],
    bool storeArchive = false,
  }) async {
    expect(id, isNull);
    expect(binding, 'selected');
    expect(storeArchive, stored);
    previousIds.add(previous);
    priorQuestions.add(history.map((turn) => turn.question).toList());
    final turn = RecordingChatTurn(
      id: turnId,
      question: question,
      answer: 'Two meetings discussed the plan.',
      contextLimited: true,
      references: const [
        ChatEvidenceReference(
          id: 'first',
          kind: ChatEvidenceReferenceKind.conversationSegment,
          state: ChatEvidenceReferenceState.available,
          conversationId: _id,
          segmentId: 'plan',
          startMs: 4250,
          title: 'First meeting',
          summary: 'Accepted the plan.',
        ),
        ChatEvidenceReference(
          id: 'second',
          kind: ChatEvidenceReferenceKind.conversationSegment,
          state: ChatEvidenceReferenceState.available,
          conversationId: _secondId,
          segmentId: 'april',
          startMs: 17000,
          title: 'Second meeting',
          summary: 'The follow-up was in April.',
        ),
      ],
    );
    if (stored) turns.insert(0, turn);
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

  testWidgets('archive chat opens a cited recording and keeps follow-up context when returning', (tester) async {
    final library = _ArchiveChatLibrary();
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ArchiveSearchPageView(library: library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chat_bubble_outline));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Compare the meetings');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
    await tester.pumpAndSettle();
    expect(find.textContaining('First meeting'), findsOneWidget);
    expect(find.textContaining('Second meeting'), findsOneWidget);
    await tester.tap(find.text('The follow-up was in April.'));
    await tester.pumpAndSettle();
    expect(library.opened, [_secondId]);
    expect(tester.widget<TranscriptWidget>(find.byType(TranscriptWidget)).followTargetSegmentId, 'april');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'When?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(library.priorQuestions, [
      <String>[],
      ['Compare the meetings'],
    ]);
  });

  testWidgets('saved archive history reloads, pages, and sends only its head to the paired server', (tester) async {
    final library = _ArchiveChatLibrary(stored: true);
    addTearDown(library.close);
    library.turns.add(
      const RecordingChatTurn(
        id: 'first',
        question: 'A saved question',
        answer: 'An answer from the server',
        references: [],
        contextLimited: false,
      ),
    );
    library.older = const RecordingChatTurn(
      id: 'older',
      question: 'An older question',
      answer: '',
      references: [],
      contextLimited: false,
      sourcesUnavailable: true,
    );
    Widget screen() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RecordingChatPage.archive(library: library, onOpenSource: (_, __) {}),
    );
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    expect(find.text('An answer from the server'), findsOneWidget);
    final labels = AppLocalizations.of(tester.element(find.byType(RecordingChatPage)));
    await tester.tap(find.text(labels.showMore));
    await tester.pumpAndSettle();
    expect(library.cursors, [null, 4]);
    expect(find.text('An original recording is unavailable. This answer is hidden.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'A follow-up question');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('saved in the shared history'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
    await tester.pumpAndSettle();
    expect(library.previousIds, ['first']);
    expect(library.priorQuestions, [<String>[]]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    expect(find.text('A follow-up question'), findsOneWidget);
  });
}
