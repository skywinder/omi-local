import 'package:flutter/material.dart';
import 'package:omi/backend/schema/gen/conversation_wire.g.dart';
import 'package:omi/pages/conversation_detail/widgets/detail_search_bar.dart';
import 'package:omi/ui/format/omi_duration.dart';
import 'package:omi/utils/l10n_extensions.dart';

/// Returns the timestamp of a selected transcript match for playback in detail.
class RecordingSearch extends StatefulWidget {
  const RecordingSearch({super.key, required this.row, required this.canPlay});

  final GeneratedConversation row;
  final bool canPlay;

  @override
  State<RecordingSearch> createState() => _RecordingSearchState();
}

class _RecordingSearchState extends State<RecordingSearch> {
  final controller = TextEditingController();
  final focus = FocusNode();
  List<({String text, double? seconds})> hits = [];
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
    final row = widget.row;
    setState(() {
      index = 0;
      hits = query.isEmpty
          ? []
          : [
              for (final value in [row.structured.title, row.structured.overview])
                if (value.toLowerCase().contains(query)) (text: value, seconds: null),
              for (final segment in row.transcriptSegments)
                if (segment.text.toLowerCase().contains(query)) (text: segment.text, seconds: segment.start),
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
    final seconds = match?.seconds;
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
                    subtitle: seconds == null ? null : Text(OmiDuration.offset(seconds)),
                    trailing: seconds == null || !widget.canPlay
                        ? null
                        : IconButton(
                            tooltip: context.l10n.play,
                            icon: const Icon(Icons.play_arrow),
                            onPressed: () => Navigator.pop(context, Duration(milliseconds: (seconds * 1000).round())),
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
