import 'package:flutter/material.dart';

import 'paired_library.dart';
import 'recording_summary.dart';
import 'settings_labels.dart';

/// Reads saved provenance separately from the defaults for the next generation.
class RecordingSummaryInfo extends StatefulWidget {
  const RecordingSummaryInfo({super.key, required this.id, required this.library, required this.onChoose});

  final String id;
  final PairedLibrary library;
  final VoidCallback onChoose;

  @override
  State<RecordingSummaryInfo> createState() => _RecordingSummaryInfoState();
}

class _RecordingSummaryInfoState extends State<RecordingSummaryInfo> {
  late final Future<RecordingSummaryOptions> options = widget.library.readSummaryOptions(widget.id);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(pairedSettingsLabel(context, 'summaryPublished'), style: Theme.of(context).textTheme.labelMedium),
        FutureBuilder<RecordingSummaryOptions>(
          future: options,
          builder: (context, snapshot) {
            final saved = snapshot.data?.published;
            final unknown = pairedSettingsLabel(context, 'summaryProvenanceUnknown');
            return Text(
              snapshot.hasError
                  ? pairedSettingsLabel(context, 'providerUnavailable')
                  : snapshot.connectionState != ConnectionState.done
                  ? '…'
                  : '${saved?.templateName ?? unknown} · ${saved?.model ?? unknown}',
            );
          },
        ),
        TextButton.icon(
          onPressed: widget.onChoose,
          icon: const Icon(Icons.tune),
          label: Text(pairedSettingsLabel(context, 'summaryChooseTemplateModel')),
        ),
      ],
    ),
  );
}
