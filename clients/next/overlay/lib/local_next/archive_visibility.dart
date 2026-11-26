import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_labels.dart';

class ArchiveVisibility {
  const ArchiveVisibility({this.minimumSeconds = 0, this.hideWithoutAudio = false, this.hideNoSpeech = false});

  final int minimumSeconds;
  final bool hideWithoutAudio;
  final bool hideNoSpeech;
  bool get active => minimumSeconds > 0 || hideWithoutAudio || hideNoSpeech;

  bool includes(ServerConversation row, {bool cachedAudioFile = false}) {
    final local = row.externalIntegration?.localRecording;
    final transcript = row.externalIntegration?.localTranscript;
    final duration = local?['duration_seconds'];
    final hasDuration = duration is num && duration.isFinite && duration >= 0;
    final start = row.startedAt;
    final end = row.finishedAt;
    final seconds = hasDuration
        ? duration
        : start != null && end != null
        ? end.difference(start).inMicroseconds / Duration.microsecondsPerSecond
        : row.transcriptSegments.isEmpty
        ? null
        : row.getDurationInSeconds();
    if (minimumSeconds > 0 && seconds != null && seconds >= 0 && seconds < minimumSeconds) return false;
    if (hideNoSpeech && local?['status'] == 'no_speech') return false;
    final hasAudio =
        transcript != null ||
        row.hasAudio() ||
        cachedAudioFile ||
        (local != null && local['group'] != true && local['results'] == null && local['status'] != 'waiting_for_parts');
    return !hideWithoutAudio || hasAudio;
  }

  static Future<ArchiveVisibility> read(String owner) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final values = prefs.getStringList('next.archive.visibility.$owner');
      if (values != null && values.length == 3) {
        final seconds = int.tryParse(values.first);
        if (seconds != null && seconds >= 0) {
          return ArchiveVisibility(
            minimumSeconds: seconds,
            hideWithoutAudio: values[1] == '1',
            hideNoSpeech: values[2] == '1',
          );
        }
      }
    } on Exception {
      // The library is still usable if device preferences are unavailable.
    }
    return const ArchiveVisibility();
  }

  Future<bool> save(String owner) async => (await SharedPreferences.getInstance()).setStringList(
    'next.archive.visibility.$owner',
    [minimumSeconds.toString(), hideWithoutAudio ? '1' : '0', hideNoSpeech ? '1' : '0'],
  );
}

class ArchiveVisibilityDialog extends StatefulWidget {
  const ArchiveVisibilityDialog(this.initial, {super.key});
  final ArchiveVisibility initial;

  @override
  State<ArchiveVisibilityDialog> createState() => _ArchiveVisibilityDialogState();
}

class _ArchiveVisibilityDialogState extends State<ArchiveVisibilityDialog> {
  late final seconds = TextEditingController(text: widget.initial.minimumSeconds.toString());

  @override
  void dispose() {
    seconds.dispose();
    super.dispose();
  }

  late bool noAudio = widget.initial.hideWithoutAudio;
  late bool noSpeech = widget.initial.hideNoSpeech;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(pairedSettingsLabel(context, 'archiveVisibility')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: seconds,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: pairedSettingsLabel(context, 'archiveMinimumSeconds')),
              maxLength: 9,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(pairedSettingsLabel(context, 'archiveHideWithoutAudio')),
              value: noAudio,
              onChanged: (value) => setState(() => noAudio = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(pairedSettingsLabel(context, 'archiveHideNoSpeech')),
              value: noSpeech,
              onChanged: (value) => setState(() => noSpeech = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l10n.cancel)),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            ArchiveVisibility(
              minimumSeconds: int.tryParse(seconds.text) ?? 0,
              hideWithoutAudio: noAudio,
              hideNoSpeech: noSpeech,
            ),
          ),
          child: Text(context.l10n.save),
        ),
      ],
    );
  }
}
