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
    required this.speed,
    required this.onSpeed,
  });

  final Duration duration;
  final Duration position;
  final bool playing;
  final double speed;
  final ValueChanged<double>? onSpeed;
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
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
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: context.l10n.skipBack10Seconds,
                icon: const Icon(Icons.replay_10_rounded),
                onPressed: canSeek && position > 0
                    ? () => widget.onSeek!(Duration(milliseconds: (position - 10000).clamp(0.0, length).round()))
                    : null,
              ),
              IconButton(
                tooltip: widget.playing ? context.l10n.pause : context.l10n.play,
                icon: Icon(widget.playing ? Icons.pause : Icons.play_arrow),
                onPressed: widget.onToggle,
              ),
              IconButton(
                tooltip: context.l10n.skipForward10Seconds,
                icon: const Icon(Icons.forward_10_rounded),
                onPressed: canSeek && position < length
                    ? () => widget.onSeek!(Duration(milliseconds: (position + 10000).clamp(0.0, length).round()))
                    : null,
              ),
              PopupMenuButton<double>(
                enabled: widget.onSpeed != null,
                initialValue: widget.speed,
                onSelected: widget.onSpeed,
                itemBuilder: (_) => [
                  for (final rate in const [0.75, 1.0, 1.25, 1.5, 2.0])
                    CheckedPopupMenuItem(value: rate, checked: rate == widget.speed, child: Text('$rate×')),
                ],
                child: Padding(padding: const EdgeInsets.all(12), child: Text('${widget.speed}×')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
