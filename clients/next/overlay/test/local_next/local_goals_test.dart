import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/gen/goals_wire.g.dart';
import 'package:omi/backend/schema/gen/task_intelligence_wire.g.dart' show GeneratedGoalProgressEvent;
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/local_goal.dart';
import 'package:omi/local_next/local_next_app.dart';
import 'package:omi/local_next/paired_library.dart';

const _recording = '00000000-0000-4000-8000-000000000001';

class _GoalLibrary extends PairedLibrary {
  _GoalLibrary() : super('100.64.0.1', List.filled(43, 'A').join()) {
    verified = true;
    goalsAvailable = true;
    recordingEdits = true;
  }

  Map<String, Object?>? created;
  Map<String, Object?>? progress;
  final now = DateTime.utc(2026, 11, 25);

  GeneratedGoalResponse get goal => GeneratedGoalResponse(
    id: 'goal_fixture',
    goalId: 'goal_fixture',
    title: 'Read 12 books',
    desiredOutcome: 'Read 12 books',
    status: 'background',
    source: 'user',
    isActive: true,
    createdAt: now,
    updatedAt: now,
    goalType: 'numeric',
    currentValue: progress == null ? 0 : 3,
    targetValue: 12,
    minValue: 0,
    maxValue: 12,
    metric: GeneratedGoalMetric(type: 'numeric', current: progress == null ? 0 : 3, target: 12, min: 0),
  );

  @override
  Future<({List<ServerConversation> rows, int consumed, bool partial, bool more})> list(
    int offset, {
    bool starredOnly = false,
    bool archivedOnly = false,
    String? folderId,
  }) async => (
    rows: offset == 0 ? [await detail(_recording)] : <ServerConversation>[],
    consumed: 1,
    partial: false,
    more: false,
  );

  @override
  Future<ServerConversation> detail(String id) async => ServerConversation.fromJson({
    'id': id,
    'created_at': '2026-01-02T11:00:00Z',
    'started_at': '2026-01-02T11:00:00Z',
    'finished_at': '2026-01-02T11:01:00Z',
    'status': 'completed',
    'structured': {'title': 'Book discussion'},
  });

  @override
  Future<List<GeneratedGoalResponse>> listGoals() async => [if (created != null) goal];

  @override
  Future<void> createGoal(Map<String, Object?> body) async {
    created = body;
  }

  @override
  Future<LocalGoalDetail> readGoal(String id) async => LocalGoalDetail(
    goal: goal,
    revision: 'fixture-revision',
    legacyHistory: const [],
    events: [
      if (progress != null)
        GeneratedGoalProgressEvent.fromJson({
          'created_at': now.toIso8601String(),
          'event_id': 'event',
          'goal_id': id,
          'kind': 'metric_update',
          'sequence': 1,
          'summary': progress!['note'],
          'metric': progress!['metric'],
          'evidence_refs': [
            {'id': _recording, 'kind': 'conversation', 'scope': 'canonical'},
          ],
        }),
    ],
  );

  @override
  Future<void> logGoalProgress(String id, Map<String, Object?> body) async {
    expect(id, goal.id);
    progress = body;
  }
}

void main() {
  testWidgets('create a local goal and log progress with the recording as evidence', (tester) async {
    final library = _GoalLibrary();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LocalNextLibraryPage(library: library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Goals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Goal'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Read 12 books');
    await tester.enterText(find.byType(TextField).at(1), '12');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(library.created?['target'], 12);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book discussion'));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((widget) => widget is PopupMenuButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log progress'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read 12 books'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Log progress'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Finished three books.');
    await tester.enterText(find.byType(TextField).at(1), '3');
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(library.progress?['expected_revision'], 'fixture-revision');
    expect(library.progress?['conversation_id'], _recording);
    expect(find.text('3 / 12'), findsOneWidget);
    expect(find.text('Finished three books.'), findsOneWidget);
    expect(find.text('Open source recording'), findsOneWidget);
  });
}
