import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:uuid/uuid.dart';

import 'paired_library.dart';
import 'recording_chat.dart';
import 'settings_labels.dart';

typedef ArchiveChatSelection = ({ArchiveChatThread? thread});

class ArchiveChatThreadPicker extends StatefulWidget {
  const ArchiveChatThreadPicker({super.key, required this.library, required this.selectedId});

  final PairedLibrary library;
  final String? selectedId;

  @override
  State<ArchiveChatThreadPicker> createState() => _ThreadPickerState();
}

class _ThreadPickerState extends State<ArchiveChatThreadPicker> {
  List<ArchiveChatThread> _threads = [];
  ArchiveChatThread? _draft;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    final threads = await widget.library.readArchiveChatThreads();
    if (mounted) setState(() => _threads = threads);
  });

  void _open(ArchiveChatThread? thread) => Navigator.pop(context, (thread: thread));

  Future<void> _create() async {
    final label = pairedSettingsLabel(context, 'archiveChatNewThread');
    final title = await showDialog<String>(context: context, builder: (_) => _NewThreadDialog(label, _draft?.title));
    if (!mounted || title == null) return;
    final draft = _draft = _draft?.title == title ? _draft! : (id: const Uuid().v4(), title: title);
    await _run(() async {
      final created = await widget.library.createArchiveChatThread(draft.id, draft.title);
      if (mounted) _open(created);
    });
  }

  Future<void> _delete(ArchiveChatThread thread) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(thread.title),
        content: Text(pairedSettingsLabel(context, 'archiveChatDeleteThreadConfirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l10n.delete)),
        ],
      ),
    );
    if (!mounted || accepted != true) return;
    await _run(() async {
      await widget.library.deleteArchiveChatThread(thread.id);
      if (!mounted) return;
      if (widget.selectedId == thread.id) {
        _open(null);
      } else {
        setState(() => _threads.removeWhere((row) => row.id == thread.id));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    String label(String key) => pairedSettingsLabel(context, key);
    final error = _error;
    return PopScope(
      canPop: !_busy,
      child: FractionallySizedBox(
        heightFactor: 0.72,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              ListTile(
                leading: IconButton(
                  tooltip: context.l10n.close,
                  icon: const Icon(Icons.close),
                  onPressed: _busy ? null : () => Navigator.pop(context),
                ),
                title: Text(label('archiveChatThreads')),
                trailing: IconButton(
                  tooltip: label('archiveChatNewThread'),
                  icon: const Icon(Icons.add),
                  onPressed: _busy ? null : _create,
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (error != null)
                ListTile(
                  title: Text(switch (error) {
                    RecordingChatFailure.threadLimit => label('archiveChatThreadLimit'),
                    LibraryFailure.key => context.l10n.invalidKey,
                    _ => context.l10n.couldNotLoadPage,
                  }),
                  trailing: TextButton(onPressed: _busy ? null : _load, child: Text(context.l10n.refresh)),
                ),
              Expanded(
                child: ListView(
                  children: [
                    ListTile(
                      title: Text(label('archiveChatSharedThread')),
                      selected: widget.selectedId == null,
                      onTap: _busy ? null : () => _open(null),
                    ),
                    for (final thread in _threads)
                      ListTile(
                        title: Text(thread.title),
                        selected: widget.selectedId == thread.id,
                        onTap: _busy ? null : () => _open(thread),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: '${context.l10n.delete} · ${thread.title}',
                          onPressed: _busy ? null : () => _delete(thread),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewThreadDialog extends StatefulWidget {
  const _NewThreadDialog(this.label, this.initialTitle);

  final String label;
  final String? initialTitle;

  @override
  State<_NewThreadDialog> createState() => _NewThreadDialogState();
}

class _NewThreadDialogState extends State<_NewThreadDialog> {
  late String _title = widget.initialTitle ?? '';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.label),
    content: TextFormField(
      initialValue: _title,
      autofocus: true,
      maxLength: 100,
      decoration: InputDecoration(labelText: pairedSettingsLabel(context, 'archiveChatThreadTitle')),
      onChanged: (value) => setState(() => _title = value),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l10n.cancel)),
      FilledButton(
        onPressed: _title.trim().isEmpty ? null : () => Navigator.pop(context, _title.trim()),
        child: Text(context.l10n.create),
      ),
    ],
  );
}
