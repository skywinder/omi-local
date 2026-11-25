import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:omi/backend/schema/conversation.dart';

import 'paired_library.dart';
import 'recording_page.dart';
import 'settings_labels.dart';
import 'wav_level.dart';

class GainSamples extends StatefulWidget {
  const GainSamples({super.key, required this.library});
  final PairedLibrary library;

  @override
  State<GainSamples> createState() => _GainSamplesState();
}

class _GainSamplesState extends State<GainSamples> {
  final _samples = <({String id, String label, WavLevel level})>[];
  bool _busy = false;
  String? _notice;

  String _label(ServerConversation row) {
    final when = DateFormat.MMMd().add_Hms().format((row.startedAt ?? row.createdAt).toLocal());
    return '${recordingInput(context, row)} · $when';
  }

  Future<void> _measure() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final page = await widget.library.list(0);
      if (!mounted) return;
      final rows = page.rows
          .where(
            (r) =>
                r.source?.name == 'omi' &&
                (r.externalIntegration?.localRecording != null || r.externalIntegration?.localTranscript != null),
          )
          .toList();
      if (rows.isEmpty) {
        setState(() => _notice = 'gainNoSamples');
        return;
      }
      final row = await showModalBottomSheet<ServerConversation>(
        context: context,
        builder: (sheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final r in rows)
                ListTile(
                  title: Text(_label(r)),
                  subtitle: Text(recordingTitle(context, r)),
                  onTap: () => Navigator.pop(sheet, r),
                ),
            ],
          ),
        ),
      );
      if (!mounted || row == null) return;
      final level = await widget.library.readRecordingLevel(row.id);
      if (!mounted) return;
      setState(() {
        _samples.removeWhere((sample) => sample.id == row.id);
        _samples.insert(0, (id: row.id, label: _label(row), level: level));
        if (_samples.length > 2) _samples.removeLast();
      });
    } catch (_) {
      if (mounted) setState(() => _notice = 'gainReadFailed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _db(double value) => value.isFinite ? value.toStringAsFixed(1) : '−∞';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(pairedSettingsLabel(context, 'gainCompareHelp')),
      TextButton.icon(
        onPressed: _busy ? null : _measure,
        icon: const Icon(Icons.graphic_eq),
        label: Text(pairedSettingsLabel(context, 'gainMeasure')),
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_notice case final key?) Text(pairedSettingsLabel(context, key)),
      for (final sample in _samples)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(sample.label),
          subtitle: Text(
            '${sample.level.seconds.toStringAsFixed(1)} s · RMS ${_db(sample.level.rms)} dBFS · Peak ${_db(sample.level.peak)} dBFS'
            '\n${pairedSettingsLabel(context, 'gainAtLimit')}: ${sample.level.atLimit}',
          ),
        ),
    ],
  );
}
