import 'package:flutter/material.dart';
import 'package:omi/ui/format/omi_duration.dart';
import 'package:omi/utils/l10n_extensions.dart';

class RecordingPlayerBar extends StatefulWidget {
  const RecordingPlayerBar({
    super.key,
    required this.duration,
    required this.position,
    required this.playing,
    required this.onToggle,
    required this.onSeek,
  });

  final Duration duration;
  final Duration position;
  final bool playing;
  final VoidCallback? onToggle;
  final ValueChanged<Duration>? onSeek;

  @override
  State<RecordingPlayerBar> createState() => _RecordingPlayerBarState();
}

class _RecordingPlayerBarState extends State<RecordingPlayerBar> {
  double? dragging;

  @override
  Widget build(BuildContext context) {
    final length = widget.duration.inMilliseconds.toDouble();
    final position = (dragging ?? widget.position.inMilliseconds.toDouble()).clamp(0.0, length > 0 ? length : 0.0);
    final canSeek = length > 0 && widget.onSeek != null;
    String clock(double milliseconds) => OmiDuration.offset(milliseconds ~/ 1000);
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 12),
      child: Row(
        children: [
          IconButton(
            tooltip: widget.playing ? context.l10n.pause : context.l10n.play,
            icon: Icon(widget.playing ? Icons.pause : Icons.play_arrow),
            onPressed: widget.onToggle,
          ),
          Expanded(
            child: Slider(
              value: position,
              max: length > 0 ? length : 1,
              semanticFormatterCallback: clock,
              onChanged: canSeek ? (value) => setState(() => dragging = value) : null,
              onChangeEnd: canSeek
                  ? (value) {
                      setState(() => dragging = null);
                      widget.onSeek!(Duration(milliseconds: value.round()));
                    }
                  : null,
            ),
          ),
          Text('${clock(position)} / ${clock(length)}'),
        ],
      ),
    );
  }
}
