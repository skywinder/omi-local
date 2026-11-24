import 'package:flutter/material.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/pages/conversation_detail/widgets/detail_search_bar.dart';
import 'package:omi/ui/format/omi_duration.dart';
import 'package:omi/utils/l10n_extensions.dart';

/// Returns the selected transcript match to the detail view.
class RecordingSearch extends StatefulWidget {
  const RecordingSearch({
    super.key,
    required this.title,
    required this.summary,
    required this.lines,
    required this.canPlay,
  });

  final String title;
  final String summary;
  final List<TranscriptSegment> lines;
  final bool canPlay;

  @override
  State<RecordingSearch> createState() => _RecordingSearchState();
}

class _RecordingSearchState extends State<RecordingSearch> {
  final controller = TextEditingController();
  final focus = FocusNode();
  List<({String text, TranscriptSegment? line})> hits = [];
  int index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focus.requestFocus();
    });
  }

  void search(String text) {
    final query = text.trim().toLowerCase();
    setState(() {
      index = 0;
      hits = query.isEmpty
          ? []
          : [
              for (final value in [widget.title, widget.summary])
                if (value.toLowerCase().contains(query)) (text: value, line: null),
              for (final segment in widget.lines)
                if (segment.text.toLowerCase().contains(query)) (text: segment.text, line: segment),
            ];
    });
  }

  @override
  void dispose() {
    focus.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final match = hits.isEmpty ? null : hits[index];
    final line = match?.line;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.search)),
      body: Column(
        children: [
          DetailSearchBar(
            controller: controller,
            focusNode: focus,
            query: controller.text.trim(),
            currentIndex: hits.isEmpty ? 0 : index + 1,
            totalResults: hits.length,
            onChanged: search,
            onPrevious: () => setState(() => index = (index - 1) % hits.length),
            onNext: () => setState(() => index = (index + 1) % hits.length),
            onCancel: () => Navigator.pop(context),
          ),
          if (match != null)
            Expanded(
              child: ListView(
                children: [
                  ListTile(
                    title: SelectableText(match.text),
                    subtitle: line == null ? null : Text(OmiDuration.offset(line.start)),
                    trailing: line == null
                        ? null
                        : IconButton(
                            tooltip: widget.canPlay ? context.l10n.play : context.l10n.viewTranscript,
                            icon: Icon(widget.canPlay ? Icons.play_arrow : Icons.notes),
                            onPressed: () => Navigator.pop(context, line),
                          ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
