import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/ui/format/omi_duration.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'paired_library.dart';
import 'recording_chat.dart';
import 'settings_labels.dart';
import 'task_editor.dart';
import 'task_suggestion.dart';

class TaskSuggestionsPage extends StatefulWidget {
  const TaskSuggestionsPage({super.key, required this.id, required this.library});

  final String id;
  final PairedLibrary library;

  @override
  State<TaskSuggestionsPage> createState() => _TaskSuggestionsPageState();
}

class _TaskSuggestionsPageState extends State<TaskSuggestionsPage> {
  final _added = <String>{};
  RecordingChatProvider? _provider;
  TaskSuggestions? _results;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    setState(() => _provider = null);
    final provider = await widget.library.readTaskSuggestionProvider(widget.id);
    if (mounted) setState(() => _provider = provider);
  });

  Future<void> _suggest(RecordingChatProvider provider) async {
    final l = context.l10n;
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(pairedSettingsLabel(context, 'localTaskSuggest')),
        content: Text(
          '${pairedSettingsLabel(context, 'localTaskSuggestConsent')}\n\n${provider.model}\n${provider.host}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.send)),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    await _run(() async {
      final results = await widget.library.suggestTasks(widget.id, provider.binding);
      if (mounted) setState(() => _results = results);
    });
  }

  Future<void> _accept(TaskSuggestion row) => _run(() async {
    await widget.library.createTask(
      row.id,
      row.description,
      conversationId: widget.id,
      segmentId: row.segmentId,
      segmentSha256: row.segmentSha256,
    );
    if (mounted) setState(() => _added.add(row.id));
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final provider = _provider;
    final results = _results;
    final error = _error;
    return Scaffold(
      appBar: AppBar(
        title: Text(pairedSettingsLabel(context, 'localTaskSuggest')),
        actions: [IconButton(icon: const Icon(Icons.refresh), tooltip: l.refresh, onPressed: _busy ? null : _load)],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(OmiSpacing.md),
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (error != null) Text(taskEditError(context, error)),
            if (!_busy && provider == null && error == null)
              Text(pairedSettingsLabel(context, 'recordingChatNoProvider')),
            if (provider != null)
              FilledButton(
                onPressed: _busy ? null : () => _suggest(provider),
                child: Text(pairedSettingsLabel(context, 'localTaskSuggest')),
              ),
            if (results?.contextLimited == true) Text(pairedSettingsLabel(context, 'localTaskSuggestLimited')),
            if (results?.rows.isEmpty == true) Text(pairedSettingsLabel(context, 'localTaskNoSuggestions')),
            for (final row in results?.rows ?? const <TaskSuggestion>[])
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(row.description),
                subtitle: Text(
                  row.startMs == null ? row.excerpt : '${OmiDuration.offset(row.startMs! / 1000)} · ${row.excerpt}',
                ),
                trailing: _added.contains(row.id)
                    ? Tooltip(message: pairedSettingsLabel(context, 'localTaskAdded'), child: const Icon(Icons.check))
                    : TextButton(onPressed: _busy ? null : () => _accept(row), child: Text(l.addTask)),
              ),
          ],
        ),
      ),
    );
  }
}
