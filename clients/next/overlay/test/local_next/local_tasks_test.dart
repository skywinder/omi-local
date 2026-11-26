import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/action_item.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/gen/action_items_folders_wire.g.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/local_next_app.dart';
import 'package:omi/local_next/local_tasks_page.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_chat.dart';
import 'package:omi/local_next/recording_edit.dart';
import 'package:omi/local_next/task_due.dart';
import 'package:omi/local_next/task_reminder_sync.dart';
import 'package:omi/local_next/task_suggestion.dart';
import 'package:omi/widgets/transcript.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _recording = '00000000-0000-4000-8000-000000000001';

class _TaskLibrary extends PairedLibrary {
  _TaskLibrary() : super('100.64.0.1', List.filled(43, 'A').join()) {
    verified = true;
    recordingEdits = true;
    tasksAvailable = true;
    taskSuggestionsAvailable = true;
  }

  ActionItemWithMetadata? task;
  final opens = <String>[];
  int suggestionCalls = 0;
  String? acceptedDigest;
  LocalTaskDue? due;
  bool scheduleUnavailable = false;

  @override
  LocalTaskDue? taskDue(String id) => due;

  @override
  Future<List<LocalTaskReminder>> readTaskReminders() async {
    if (scheduleUnavailable) throw LibraryFailure.unavailable;
    final instant = due?.instant;
    if (task!.completed || instant == null) return [];
    return [(id: task!.id, description: task!.description, at: instant, exact: true)];
  }

  @override
  Future<RecordingChatProvider?> readTaskSuggestionProvider(String id) async =>
      const RecordingChatProvider(binding: 'fixture-binding', host: 'summary.example', model: 'fixture-model');

  @override
  Future<TaskSuggestions> suggestTasks(String id, String binding) async {
    expect(id, _recording);
    expect(binding, 'fixture-binding');
    suggestionCalls++;
    return const TaskSuggestions(
      rows: [
        TaskSuggestion(
          id: 'fixture-request',
          description: 'Send the budget',
          segmentId: 'line',
          segmentSha256: 'fixture-digest',
          excerpt: 'I’ll send the budget at noon.',
          startMs: 5000,
        ),
      ],
      contextLimited: true,
    );
  }

  @override
  Future<ServerConversation> detail(String id) async {
    opens.add(id);
    return ServerConversation.fromJson({
      'id': id,
      'created_at': '2026-01-02T11:00:00Z',
      'started_at': '2026-01-02T11:00:00Z',
      'finished_at': '2026-01-02T11:01:00Z',
      'structured': {'title': 'Budget meeting'},
      'transcript_segments': [
        {'id': 'line', 'text': 'Send the budget', 'start': 5.0, 'end': 7.0, 'is_user': true},
      ],
    });
  }

  @override
  Future<({List<ServerConversation> rows, int consumed, bool partial, bool more})> list(
    int offset, {
    bool starredOnly = false,
    String? folderId,
  }) async => (rows: [await detail(_recording)], consumed: 1, partial: false, more: false);

  @override
  Future<ActionItemWithMetadata> createTask(
    String requestId,
    String description, {
    String? conversationId,
    String? segmentId,
    String? segmentSha256,
  }) async {
    expect(conversationId, _recording);
    expect(segmentId, 'line');
    expect(description, 'Send the budget');
    acceptedDigest = segmentSha256;
    return task = ActionItemWithMetadata(
      id: requestId,
      description: description,
      completed: false,
      conversationId: conversationId,
      provenance: [
        GeneratedEvidenceRef(
          id: conversationId!,
          kind: 'conversation',
          scope: 'canonical',
          startSeconds: 5,
          transcriptSegmentIds: [segmentId!],
        ),
      ],
    );
  }

  @override
  Future<ActionItemsResponse> readTasks(int offset) async =>
      ActionItemsResponse(actionItems: [if (task != null) task!]);

  @override
  Future<ActionItemWithMetadata> readTask(String id) async => task!;

  @override
  Future<ActionItemWithMetadata> editTask(String id, RecordingEdit edit) async {
    if (edit.field == 'due') {
      expect(edit.wire['expected'], due?.wire);
      final value = edit.value as Map<String, dynamic>?;
      due = value == null ? null : LocalTaskDue(value);
    }
    return task = task!.copyWith(
      description: edit.field == 'description' ? edit.value as String : null,
      completed: edit.field == 'completed' ? edit.value as bool : null,
    );
  }
}

void main() {
  testWidgets(
    'a task can gain an exact reminder and completion clears the local alarm',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('org.omilocal.next/reminders');
      final messenger = tester.binding.defaultBinaryMessenger;
      final schedules = <List>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'timezone':
            return 'Asia/Yerevan';
          case 'replace':
            schedules.add(call.arguments as List);
          case 'clear':
            schedules.add([]);
            return null;
        }
        return {'allowed': true, 'precise': true};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final future = DateTime.now().add(const Duration(days: 2));
      final library = _TaskLibrary()
        ..taskRemindersAvailable = true
        ..task = const ActionItemWithMetadata(id: 'fixture-task', description: 'Test appointment', completed: false)
        ..due = LocalTaskDue.day(future.toIso8601String().split('T').first, 'Asia/Yerevan');
      final reminders = TaskReminderSync()..bind(library);
      addTearDown(reminders.dispose);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LocalTasksPage(library: library, reminders: reminders),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Task reminders on this phone'));
      await tester.pumpAndSettle();
      expect(reminders.enabled, isTrue);
      await tester.tap(find.byTooltip('Set reminder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exact time'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(library.due?.kind, 'instant');
      expect(library.due?.timezone, 'Asia/Yerevan');
      expect(schedules.last.single, containsPair('id', 'fixture-task'));

      final last = schedules.length;
      library.scheduleUnavailable = true;
      await reminders.sync(library, 'Omi task reminder');
      await tester.pumpAndSettle();
      expect(reminders.syncFailed, isTrue);
      expect(schedules.length, last);
      library.scheduleUnavailable = false;
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(reminders.syncFailed, isFalse);
      expect(schedules.last, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('task suggestions require model consent and separate acceptance of source evidence', (tester) async {
    final library = _TaskLibrary();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LocalNextLibraryPage(library: library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Budget meeting'));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((widget) => widget is PopupMenuButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suggest tasks'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Suggest tasks'));
    await tester.pumpAndSettle();
    expect(find.textContaining('fixture-model\nsummary.example'), findsOneWidget);
    expect(library.suggestionCalls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(library.suggestionCalls, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Suggest tasks'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(library.suggestionCalls, 1);
    expect(library.task, isNull);
    expect(find.textContaining('I’ll send the budget at noon.'), findsOneWidget);
    expect(find.text('The model reviewed only part of this transcript.'), findsOneWidget);
    await tester.tap(find.text('Add Task'));
    await tester.pumpAndSettle();
    expect(library.task?.id, 'fixture-request');
    expect(library.acceptedDigest, 'fixture-digest');
    expect(find.byTooltip('Task added'), findsOneWidget);
    expect(find.text('Add Task'), findsNothing);
  });

  testWidgets('a transcript task can be accepted, edited, completed and reopened at its source', (tester) async {
    final library = _TaskLibrary();
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: LocalNextLibraryPage(library: library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Budget meeting'));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((widget) => widget is PopupMenuButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add task from transcript'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send the budget'));
    await tester.pumpAndSettle();
    expect(library.task, isNull);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(library.task?.description, 'Send the budget');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tasks'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Send approved budget');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(library.task?.completed, isTrue);
    await tester.tap(find.text('Open source recording'));
    await tester.pumpAndSettle();
    expect(tester.widget<TranscriptWidget>(find.byType(TranscriptWidget)).followTargetSegmentId, 'line');
  });
}
