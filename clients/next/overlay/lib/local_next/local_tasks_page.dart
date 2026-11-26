import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/backend/schema/action_item.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'paired_library.dart';
import 'recording_edit.dart';
import 'recording_page.dart';
import 'settings_labels.dart';
import 'task_editor.dart';
import 'task_reminder_editor.dart';
import 'task_reminder_sync.dart';

class LocalTasksPage extends StatefulWidget {
  const LocalTasksPage({super.key, required this.library, this.reminders});
  final PairedLibrary library;
  final TaskReminderSync? reminders;

  @override
  State<LocalTasksPage> createState() => _LocalTasksPageState();
}

class _LocalTasksPageState extends State<LocalTasksPage> {
  final _tasks = <String, ActionItemWithMetadata>{};
  int _offset = 0;
  bool _busy = false;
  bool _more = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool append = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _loadFailed = false;
    });
    try {
      final page = await widget.library.readTasks(append ? _offset : 0);
      if (!mounted) return;
      setState(() {
        if (!append) {
          _offset = 0;
          _tasks.clear();
        }
        for (final task in page.actionItems) {
          _tasks[task.id] = task;
        }
        _offset += page.actionItems.length;
        _more = page.hasMore;
      });
      if (!append) _syncReminders();
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    if (await createLocalTask(context, widget.library) && mounted) await _load();
  }

  Future<void> _save(ActionItemWithMetadata task, RecordingEdit edit) async {
    final saved = await widget.library.editTask(task.id, edit);
    if (mounted) {
      setState(() => _tasks[saved.id] = saved);
      _syncReminders();
    }
  }

  void _syncReminders() {
    if (widget.reminders case final reminders?) {
      unawaited(reminders.sync(widget.library, pairedSettingsLabel(context, 'localReminderTitle')));
    }
  }

  Future<void> _editReminder(ActionItemWithMetadata task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final saved = await widget.library.readTask(task.id);
      if (!mounted) return;
      setState(() {
        _tasks[saved.id] = saved;
        _busy = false;
      });
      if (saved.isLocked || saved.completed) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            TaskReminderEditor(initial: widget.library.taskDue(saved.id), save: (edit) => _save(saved, edit)),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(taskEditError(context, error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(ActionItemWithMetadata task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _save(task, RecordingEdit.taskCompleted(task.completed, !task.completed));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(taskEditError(context, error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(ActionItemWithMetadata task) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => RecordingTextEditor(
      label: context.l10n.edit,
      initial: task.description,
      maxLength: 4096,
      multiline: true,
      errorText: taskEditError,
      onSave: (value) => _save(task, RecordingEdit.taskDescription(task.description, value.trim())),
    ),
  );

  Future<void> _source(ActionItemWithMetadata task) async {
    try {
      final saved = await widget.library.readTask(task.id);
      final recordingId = saved.conversationId;
      if (!mounted || recordingId == null) return;
      final reference = saved.provenance
          ?.where((ref) => ref.kind == 'conversation' && ref.id == recordingId)
          .firstOrNull;
      final segmentId = reference?.transcriptSegmentIds?.firstOrNull;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RecordingPage(
            library: widget.library,
            id: recordingId,
            initialMatch: segmentId == null
                ? null
                : TranscriptMatchSnippet(text: '', segmentId: segmentId, start: reference?.startSeconds),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.couldNotLoadPage)));
      }
    }
  }

  Widget? _subtitle(ActionItemWithMetadata task) {
    final reminder = taskReminderLabel(context, widget.library.taskDue(task.id));
    if (reminder != null) return Text(reminder);
    return task.conversationId == null ? null : Text(pairedSettingsLabel(context, 'localTaskSource'));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final supportsReminders = widget.library.taskRemindersAvailable;
    final rows = [..._tasks.values];
    // Keep each partition in the server's order as tasks enter and leave it.
    final ordered = [...rows.where((row) => !row.completed), ...rows.where((row) => row.completed)];
    return Scaffold(
      appBar: AppBar(
        title: Text(l.tasks),
        actions: [
          IconButton(tooltip: l.refresh, icon: const Icon(Icons.refresh), onPressed: _busy ? null : _load),
          IconButton(tooltip: l.addTask, icon: const Icon(Icons.add), onPressed: _busy ? null : _add),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_loadFailed)
            ListTile(
              title: Text(l.couldNotLoadPage),
              trailing: TextButton(onPressed: _load, child: Text(l.retry)),
            ),
          Expanded(
            child: ListView(
              children: [
                if (widget.reminders case final reminders? when supportsReminders)
                  TaskReminderSettings(library: widget.library, reminders: reminders),
                for (final task in ordered)
                  ListTile(
                    key: ValueKey(task.id),
                    leading: Checkbox(
                      value: task.completed,
                      onChanged: _busy || task.isLocked ? null : (_) => _toggle(task),
                    ),
                    title: Text(task.description),
                    subtitle: _subtitle(task),
                    onTap: task.conversationId == null || task.isLocked ? null : () => _source(task),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (supportsReminders && !task.completed)
                          IconButton(
                            tooltip: pairedSettingsLabel(context, 'localReminderEdit'),
                            icon: const Icon(Icons.alarm_outlined),
                            onPressed: _busy || task.isLocked ? null : () => _editReminder(task),
                          ),
                        IconButton(
                          tooltip: l.edit,
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: _busy || task.isLocked ? null : () => _edit(task),
                        ),
                      ],
                    ),
                  ),
                if (!_busy && !_loadFailed && ordered.isEmpty && !_more)
                  ListTile(title: Text(pairedSettingsLabel(context, 'localTaskEmpty'))),
                if (_more) TextButton(onPressed: _busy ? null : () => _load(append: true), child: Text(l.showMore)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
