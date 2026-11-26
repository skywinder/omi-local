import 'package:flutter/material.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:permission_handler/permission_handler.dart';

import 'paired_library.dart';
import 'recording_edit.dart';
import 'settings_labels.dart';
import 'task_due.dart';
import 'task_editor.dart';
import 'task_reminder_sync.dart';

String? taskReminderLabel(BuildContext context, LocalTaskDue? due) {
  final format = MaterialLocalizations.of(context);
  if (due?.date case final date?) return '${format.formatMediumDate(date)} · 09:00 · ${due!.timezone}';
  if (due?.instant case final instant?) {
    final local = instant.toLocal();
    return '${format.formatMediumDate(local)} · ${TimeOfDay.fromDateTime(local).format(context)}';
  }
  return null;
}

class TaskReminderEditor extends StatefulWidget {
  const TaskReminderEditor({super.key, required this.initial, required this.save});
  final LocalTaskDue? initial;
  final Future<void> Function(RecordingEdit) save;

  @override
  State<TaskReminderEditor> createState() => _TaskReminderEditorState();
}

class _TaskReminderEditorState extends State<TaskReminderEditor> {
  late bool _exact = widget.initial?.instant != null;
  late DateTime _date =
      widget.initial?.date ?? widget.initial?.instant?.toLocal() ?? DateUtils.dateOnly(DateTime.now());
  late TimeOfDay _time = TimeOfDay.fromDateTime(widget.initial?.instant?.toLocal() ?? DateTime(2000, 1, 1, 9));
  bool _saving = false;
  String? _error;

  Future<void> _pickDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final chosen = await showDatePicker(
      context: context,
      firstDate: today,
      initialDate: _date.isBefore(today) ? today : _date,
      lastDate: DateTime(today.year + 100, 12, 31),
    );
    if (mounted && chosen != null) setState(() => _date = chosen);
  }

  Future<void> _pickTime() async {
    final chosen = await showTimePicker(context: context, initialTime: _time);
    if (mounted && chosen != null) setState(() => _time = chosen);
  }

  Future<void> _submit({bool remove = false}) async {
    if (_saving) return;
    final time = _exact ? _time : const TimeOfDay(hour: 9, minute: 0);
    final scheduled = DateTime(_date.year, _date.month, _date.day, time.hour, time.minute);
    if (!remove && (scheduled.hour != time.hour || scheduled.minute != time.minute)) {
      setState(() => _error = pairedSettingsLabel(context, 'localReminderInvalidTime'));
      return;
    }
    if (!remove && !scheduled.isAfter(DateTime.now())) {
      setState(() => _error = pairedSettingsLabel(context, 'localReminderPast'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      LocalTaskDue? due;
      if (!remove) {
        final timezone = await TaskReminderSync.timezone();
        if (!mounted) return;
        final day = DateUtils.dateOnly(_date).toIso8601String().split('T').first;
        due = _exact ? LocalTaskDue.time(scheduled, timezone) : LocalTaskDue.day(day, timezone);
      }
      await widget.save(RecordingEdit.taskDue(widget.initial?.wire, due?.wire));
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = taskEditError(context, error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String label(String key) => pairedSettingsLabel(context, key);
    final l = context.l10n;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(label('localReminderEdit')),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text(label('localReminderDay')),
                  selected: !_exact,
                  onSelected: _saving ? null : (_) => setState(() => _exact = false),
                ),
                ChoiceChip(
                  label: Text(label('localReminderTime')),
                  selected: _exact,
                  onSelected: _saving ? null : (_) => setState(() => _exact = true),
                ),
              ],
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today_outlined),
              title: Text(MaterialLocalizations.of(context).formatMediumDate(_date)),
              onTap: _saving ? null : _pickDate,
            ),
            if (_exact)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule),
                title: Text(_time.format(context)),
                onTap: _saving ? null : _pickTime,
              )
            else
              Text(label('localReminderDayTime')),
            if (_error case final error?) Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
        actions: [
          if (taskReminderLabel(context, widget.initial) != null)
            TextButton(
              onPressed: _saving ? null : () => _submit(remove: true),
              child: Text(label('localReminderRemove')),
            ),
          TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(l.cancel)),
          FilledButton(onPressed: _saving ? null : _submit, child: Text(l.save)),
        ],
      ),
    );
  }
}

class TaskReminderSettings extends StatefulWidget {
  const TaskReminderSettings({super.key, required this.library, required this.reminders});
  final PairedLibrary library;
  final TaskReminderSync reminders;

  @override
  State<TaskReminderSettings> createState() => _TaskReminderSettingsState();
}

class _TaskReminderSettingsState extends State<TaskReminderSettings> {
  bool _working = false;

  Future<void> _perform(Future<void> Function() action) async {
    setState(() => _working = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        final message = pairedSettingsLabel(context, 'localReminderSyncFailed');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reminders = widget.reminders;
    String label(String key) => pairedSettingsLabel(context, key);
    return ListenableBuilder(
      listenable: reminders,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            title: Text(label('localReminderDevice')),
            subtitle: Text(
              label(
                reminders.permissionMissing
                    ? 'localReminderPermission'
                    : reminders.syncFailed
                    ? 'localReminderSyncFailed'
                    : 'localReminderDeviceHelp',
              ),
            ),
            value: reminders.enabled,
            onChanged: _working
                ? null
                : (value) => _perform(() => reminders.setEnabled(widget.library, value, label('localReminderTitle'))),
          ),
          if (reminders.permissionMissing)
            TextButton(
              onPressed: () => _perform(() async {
                await openAppSettings();
              }),
              child: Text(context.l10n.settings),
            ),
          if (reminders.enabled && !reminders.permissionMissing && !reminders.precise)
            ListTile(
              subtitle: Text(label('localReminderApproximate')),
              trailing: TextButton(
                onPressed: _working ? null : () => _perform(reminders.exactSettings),
                child: Text(label('localReminderExactSettings')),
              ),
            ),
        ],
      ),
    );
  }
}
