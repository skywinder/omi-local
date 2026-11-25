import 'package:flutter/material.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'paired_library.dart';
import 'processing.dart';
import 'settings_labels.dart';

class NextLiveTuningSheet extends StatefulWidget {
  const NextLiveTuningSheet({super.key, required this.library});
  final PairedLibrary library;

  @override
  State<NextLiveTuningSheet> createState() => _NextLiveTuningSheetState();
}

class _NextLiveTuningSheetState extends State<NextLiveTuningSheet> {
  ({int revision, int speakers})? _confirmed;
  int? _draft;
  NextProcessingFailure? _failure;
  bool _busy = false, _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => _run(widget.library.readLiveTuning);

  Future<void> _run(Future<({int revision, int speakers})?> Function() request, {bool saving = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
      _saved = false;
    });
    try {
      final state = await request();
      if (!mounted) return;
      setState(() {
        _confirmed = state;
        _draft = state?.speakers;
        _saved = saving;
      });
    } on NextProcessingFailure catch (error) {
      if (!mounted) return;
      setState(() {
        _confirmed = null;
        _failure = error;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final confirmed = _confirmed;
    final draft = _draft;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(pairedSettingsLabel(context, 'liveSpeakerLimit')),
              trailing: IconButton(
                tooltip: l.recordingInfo,
                icon: const Icon(Icons.info_outline),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(l.recordingInfo),
                    content: Text(pairedSettingsLabel(context, 'liveSpeakerHelp')),
                    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(l.close))],
                  ),
                ),
              ),
            ),
            if (confirmed != null)
              DropdownButton<int>(
                key: const ValueKey('next-live-speakers'),
                value: draft,
                isExpanded: true,
                items: [for (var value = 1; value <= 4; value++) DropdownMenuItem(value: value, child: Text('$value'))],
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _draft = value;
                        _saved = false;
                      }),
              ),
            if (_busy) const LinearProgressIndicator(),
            if (_failure case final failure?)
              Text(processingFailureLabel(context, failure))
            else if (!_busy && confirmed == null)
              Text(pairedSettingsLabel(context, 'liveSpeakerUnsupported')),
            if (_saved) Text(pairedSettingsLabel(context, 'liveSpeakerSaved')),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy || confirmed == null || draft == null || draft == confirmed.speakers
                      ? null
                      : () => _run(() => widget.library.setLiveSpeakerLimit(confirmed.revision, draft), saving: true),
                  child: Text(l.saveChanges),
                ),
                TextButton(onPressed: _busy ? null : _load, child: Text(l.refresh)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
