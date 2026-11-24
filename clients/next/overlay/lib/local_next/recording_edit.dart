import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'settings_labels.dart';

enum RecordingEditFailure implements Exception { conflict, unavailable, folderTooLarge }

class RecordingEdit {
  const RecordingEdit.title(String this.expected, String this.value) : field = 'title', segmentId = null;
  const RecordingEdit.starred(bool this.expected, bool this.value) : field = 'starred', segmentId = null;
  const RecordingEdit.segment(String this.segmentId, String this.expected, String this.value) : field = 'segment_text';
  const RecordingEdit.folder(String? this.expected, String? this.value) : field = 'folder', segmentId = null;

  final String field;
  final String? segmentId;
  final Object? expected;
  final Object? value;

  Map<String, Object?> get wire => {
    'field': field,
    'expected': field == 'title' || field == 'segment_text'
        ? sha256.convert(utf8.encode(expected as String)).toString()
        : expected,
    'value': value,
    if (segmentId != null) 'segment_id': segmentId!,
  };
}

String recordingEditError(BuildContext context, Object error) => switch (error) {
  RecordingEditFailure.conflict => pairedSettingsLabel(context, 'recordingEditConflict'),
  RecordingEditFailure.folderTooLarge => pairedSettingsLabel(context, 'localFolderTooLarge'),
  _ => pairedSettingsLabel(context, 'recordingEditUnavailable'),
};

class RecordingTextEditor extends StatefulWidget {
  const RecordingTextEditor({
    super.key,
    required this.label,
    required this.initial,
    required this.maxLength,
    required this.multiline,
    required this.onSave,
  });

  final String label;
  final String initial;
  final int maxLength;
  final bool multiline;
  final Future<void> Function(String) onSave;

  @override
  State<RecordingTextEditor> createState() => _RecordingTextEditorState();
}

class _RecordingTextEditorState extends State<RecordingTextEditor> {
  late final _input = TextEditingController(text: widget.initial);
  bool _saving = false;
  Object? _error;

  Future<void> _save() async {
    final value = widget.multiline ? _input.text : _input.text.trim();
    if (_saving || value.trim().isEmpty || value.runes.length > widget.maxLength) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (value != widget.initial) await widget.onSave(value);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final error = _error;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(widget.label),
        content: TextField(
          controller: _input,
          enabled: !_saving,
          autofocus: true,
          maxLength: widget.maxLength,
          minLines: widget.multiline ? 3 : 1,
          maxLines: widget.multiline ? 7 : 1,
          textInputAction: widget.multiline ? TextInputAction.newline : TextInputAction.done,
          onChanged: (_) => setState(() {}),
          onSubmitted: widget.multiline ? null : (_) => _save(),
          decoration: InputDecoration(
            errorText: error == null ? null : recordingEditError(context, error),
            errorMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: Text(l.cancel)),
          FilledButton(onPressed: _saving || _input.text.trim().isEmpty ? null : _save, child: Text(l.save)),
        ],
      ),
    );
  }
}
