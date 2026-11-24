import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/action_item.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/gen/action_items_folders_wire.g.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/local_next_app.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_edit.dart';
import 'package:omi/widgets/transcript.dart';

const _recording = '00000000-0000-4000-8000-000000000001';

class _TaskLibrary extends PairedLibrary {
  _TaskLibrary() : super('100.64.0.1', List.filled(43, 'A').join()) {
    verified = true;
    recordingEdits = true;
    tasksAvailable = true;
  }

  ActionItemWithMetadata? task;
  final opens = <String>[];

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
  }) async {
    expect(conversationId, _recording);
    expect(segmentId, 'line');
    expect(description, 'Send the budget');
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
  Future<ActionItemWithMetadata> editTask(String id, RecordingEdit edit) async => task = task!.copyWith(
    description: edit.field == 'description' ? edit.value as String : null,
    completed: edit.field == 'completed' ? edit.value as bool : null,
  );
}

void main() {
  testWidgets('a transcript task can be accepted, edited, completed and reopened at its source', (tester) async {
    final library = _TaskLibrary();
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: LocalNextLibraryPage(library: library, disconnect: () async {}),
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
