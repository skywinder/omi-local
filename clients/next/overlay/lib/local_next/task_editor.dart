import 'package:flutter/material.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:uuid/uuid.dart';

import 'paired_library.dart';
import 'recording_edit.dart';
import 'settings_labels.dart';

String taskEditError(BuildContext context, Object error) => error == RecordingEditFailure.conflict
    ? pairedSettingsLabel(context, 'localTaskChanged')
    : recordingEditError(context, error);

Future<bool> createLocalTask(
  BuildContext context,
  PairedLibrary library, {
  String? conversationId,
  String? segmentId,
  String initial = '',
}) async {
  String? previous;
  String? requestId;
  var created = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => RecordingTextEditor(
      label: context.l10n.addTask,
      initial: initial,
      maxLength: 4096,
      multiline: true,
      saveUnchanged: true,
      errorText: taskEditError,
      onSave: (value) async {
        final description = value.trim();
        if (description != previous) {
          requestId = const Uuid().v4();
          previous = description;
        }
        await library.createTask(requestId!, description, conversationId: conversationId, segmentId: segmentId);
        created = true;
      },
    ),
  );
  return created;
}
