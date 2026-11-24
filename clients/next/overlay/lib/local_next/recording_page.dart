import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/pages/conversation_detail/conversation_summary_selection.dart';
import 'package:omi/pages/conversation_detail/widgets/conversation_markdown_widget.dart';
import 'package:omi/pages/conversation_detail/widgets/note_sections_sliver.dart';
import 'package:omi/ui/components/omi_page_states.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/widgets/transcript.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:path_provider/path_provider.dart';

import 'paired_library.dart';
import 'recording_chat_page.dart';
import 'recording_search.dart';
import 'settings_labels.dart';

String recordingTitle(BuildContext context, ServerConversation row) => row.externalIntegration?.localRecording != null
    ? context.l10n.recording
    : row.structured.title.trim().isEmpty
    ? context.l10n.untitledConversation
    : row.structured.title;

String recordingStatus(BuildContext context, ServerConversation row) {
  final local = row.externalIntegration?.localRecording;
  return switch (local == null ? row.status.name : local['status']) {
    'failed' => context.l10n.processingFailed,
    'pending' => context.l10n.statusPending,
    'processing' => context.l10n.statusProcessing,
    'no_speech' => context.l10n.noTranscriptAvailable,
    _ => context.l10n.saved,
  };
}

class RecordingPage extends StatefulWidget {
  const RecordingPage({super.key, required this.library, required this.id, this.initialMatch});
  final PairedLibrary library;
  final String id;
  final TranscriptMatchSnippet? initialMatch;

  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage> with SingleTickerProviderStateMixin {
  late final tabs = TabController(length: 2, vsync: this, initialIndex: widget.initialMatch == null ? 0 : 1);
  late Future<_RecordingDetail> detail = _load();
  String? focusedLine;
  int focusRequest = 0;
  AudioPlayer? player;
  Directory? temp;
  Duration? _initialPosition;
  bool opening = false;
  bool _canPlay(ServerConversation row) =>
      widget.library.audioPlayback &&
      (row.externalIntegration?.localRecording != null || row.externalIntegration?.localTranscript != null);

  Future<_RecordingDetail> _load() async {
    final loaded = _RecordingDetail(await widget.library.detail(widget.id));
    final match = widget.initialMatch;
    if (match != null) {
      _focusMatch(loaded, match);
    }
    return loaded;
  }

  bool _focusMatch(_RecordingDetail loaded, TranscriptMatchSnippet match, {bool verifyExcerpt = false}) {
    bool hasExcerpt(TranscriptSegment line) => !verifyExcerpt || line.text.trim().startsWith(match.text);
    final start = match.start;
    final line =
        loaded.sources.where((line) => line.id == match.segmentId && hasExcerpt(line)).firstOrNull ??
        loaded.lines
            .where((line) => start != null && (line.start - start).abs() < 0.01 && hasExcerpt(line))
            .firstOrNull;
    if (line == null) return false;
    focusedLine = line.id;
    focusRequest++;
    if (line.start.isFinite && line.start >= 0) {
      _initialPosition = Duration(milliseconds: (line.start * 1000).round());
    }
    return true;
  }

  Future<void> _openChat() async {
    if (opening) return;
    final match = await Navigator.of(context).push<TranscriptMatchSnippet>(
      MaterialPageRoute(
        builder: (_) => RecordingChatPage(id: widget.id, library: widget.library),
      ),
    );
    if (!mounted || match == null) return;
    setState(() => opening = true);
    try {
      await player?.pause();
      final loaded = _RecordingDetail(await widget.library.detail(widget.id));
      if (!mounted) return;
      final focused = _focusMatch(loaded, match, verifyExcerpt: true);
      setState(() {
        detail = SynchronousFuture(loaded);
      });
      if (focused) {
        tabs.index = 1;
      } else {
        _chatSourceUnavailable();
      }
    } catch (_) {
      if (mounted) _chatSourceUnavailable();
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  void _chatSourceUnavailable() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(pairedSettingsLabel(context, 'recordingChatSourceUnavailable'))));
  }

  void _openLine(TranscriptSegment line, {required bool canPlay}) {
    if (opening) return;
    setState(() {
      focusedLine = line.id;
      focusRequest++;
    });
    tabs.animateTo(1);
    if (canPlay && line.start.isFinite && line.start >= 0) {
      unawaited(_start(position: Duration(milliseconds: (line.start * 1000).round())));
    }
  }

  Future<void> _start({Duration? position}) async {
    if (opening) return;
    setState(() => opening = true);
    try {
      if (player == null) {
        final base = await getTemporaryDirectory();
        final folder = await base.createTemp('next-recording-');
        try {
          final file = File('${folder.path}/recording.wav');
          if (!mounted) return;
          await widget.library.downloadAudio(widget.id, file);
          if (!mounted) return;
          final fresh = AudioPlayer();
          try {
            await fresh.setFilePath(file.path);
            if (!mounted) return;
            player = fresh;
            temp = folder;
          } finally {
            if (player != fresh) await fresh.dispose();
          }
        } finally {
          if (temp != folder && await folder.exists()) {
            await folder.delete(recursive: true);
          }
        }
      }
      if (!mounted) return;
      final current = player!;
      final target = position ?? _initialPosition;
      if (target != null) {
        await current.seek(target);
        _initialPosition = null;
      } else if (current.processingState == ProcessingState.completed) {
        await current.seek(Duration.zero);
      }
      if (mounted && !current.playing) {
        // play() completes on stop/end, so the control must be released before then.
        unawaited(current.play().catchError((Object _) => _playFailed()));
      }
    } catch (_) {
      _playFailed();
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  void _playFailed() {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.audioPlaybackUnavailable)));
    }
  }

  @override
  void dispose() {
    tabs.dispose();
    final current = player;
    final folder = temp;
    temp = null;
    unawaited(() async {
      try {
        await current?.dispose();
      } finally {
        if (folder != null && await folder.exists()) {
          await folder.delete(recursive: true);
        }
      }
    }());
    super.dispose();
  }

  Widget _playbackControls() => StreamBuilder<PlayerState>(
    stream: player?.playerStateStream,
    builder: (context, state) {
      final playing = state.data?.playing == true && state.data?.processingState != ProcessingState.completed;
      final l = context.l10n;
      return TextButton.icon(
        onPressed: opening
            ? null
            : playing
            ? () async {
                try {
                  await player?.pause();
                } catch (_) {
                  _playFailed();
                }
              }
            : _start,
        icon: Icon(playing ? Icons.pause : Icons.play_arrow),
        label: Text(playing ? l.pause : l.play),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return FutureBuilder<_RecordingDetail>(
      future: detail,
      builder: (context, snapshot) {
        final loaded = snapshot.data;
        final row = loaded?.row;
        final canPlay = row != null && _canPlay(row);
        return Scaffold(
          appBar: AppBar(
            title: Text(row == null ? l.conversations : recordingTitle(context, row)),
            actions: [
              if (loaded != null && loaded.lines.isNotEmpty)
                IconButton(
                  tooltip: l.askOmi,
                  icon: const Icon(Icons.chat_bubble_outline),
                  onPressed: opening ? null : _openChat,
                ),
              if (loaded != null)
                IconButton(
                  tooltip: l.search,
                  icon: const Icon(Icons.search),
                  onPressed: opening
                      ? null
                      : () async {
                          final line = await Navigator.push<TranscriptSegment>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => RecordingSearch(
                                title: loaded.row.structured.title,
                                summary: loaded.summary.content,
                                lines: loaded.lines,
                                canPlay: canPlay,
                              ),
                            ),
                          );
                          if (mounted && line != null) {
                            _openLine(line, canPlay: canPlay);
                          }
                        },
                ),
            ],
          ),
          body: snapshot.connectionState != ConnectionState.done
              ? const OmiLoadingState()
              : loaded == null
              ? OmiErrorState(
                  message: snapshot.error == LibraryFailure.key ? l.invalidKey : l.couldNotLoadPage,
                  onRetry: () => setState(() {
                    detail = _load();
                  }),
                )
              : Column(
                  children: [
                    TabBar(
                      controller: tabs,
                      tabs: [
                        Tab(text: l.summary),
                        Tab(text: l.transcript),
                      ],
                    ),
                    if (canPlay) _playbackControls(),
                    if (opening) const LinearProgressIndicator(),
                    Expanded(
                      child: TabBarView(
                        controller: tabs,
                        children: [
                          _Summary(
                            detail: loaded,
                            onOpenLine: (line) => _openLine(line, canPlay: canPlay),
                          ),
                          loaded.lines.isEmpty
                              ? Center(
                                  child: Text(
                                    loaded.pending ? recordingStatus(context, loaded.row) : l.noTranscriptAvailable,
                                  ),
                                )
                              : TranscriptWidget(
                                  segments: loaded.lines,
                                  isConversationDetail: true,
                                  bottomMargin: OmiSpacing.md,
                                  onSegmentTap: canPlay && !opening ? (line) => _openLine(line, canPlay: true) : null,
                                  currentSegmentId: focusedLine,
                                  followTargetSegmentId: focusedLine,
                                  playbackFollowRequest: focusRequest,
                                  followCurrentSegment: true,
                                ),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _RecordingDetail {
  _RecordingDetail(this.row) : lines = row.transcriptSegments {
    // Some older recordings carry no segment ID or repeat one. Give those rows
    // distinct keys for the transcript viewport without changing valid citations.
    final reserved = <String, int>{};
    for (final line in lines) {
      reserved.update(line.id, (count) => count + 1, ifAbsent: () => 1);
    }
    final ids = <String>{};
    for (final (index, line) in lines.indexed) {
      if (line.id.isNotEmpty && ids.add(line.id)) {
        if (reserved[line.id] == 1) sources.add(line);
        continue;
      }
      var id = 'local-next-$index';
      while (reserved.containsKey(id)) {
        id = ':$id';
      }
      line.id = id;
    }
  }

  final ServerConversation row;
  final List<TranscriptSegment> lines;
  final sources = <TranscriptSegment>[];
  late final summary = ConversationSummarySelection.firstParty(
    ServerConversation(id: row.id, createdAt: row.createdAt, structured: row.structured, transcriptSegments: sources),
  );
  bool get pending => row.externalIntegration?.localRecording != null;
}

class _Summary extends StatelessWidget {
  const _Summary({required this.detail, required this.onOpenLine});
  final _RecordingDetail detail;
  final ValueChanged<TranscriptSegment> onOpenLine;

  @override
  Widget build(BuildContext context) {
    final summary = detail.summary;
    return SelectionArea(
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(OmiSpacing.md),
            sliver: summary.sections.isNotEmpty
                ? NoteSectionsSliver(
                    sections: summary.sections,
                    transcriptSegments: detail.sources,
                    onOpenSource: (id) => onOpenLine(detail.sources.firstWhere((line) => line.id == id)),
                  )
                : summary.content.isNotEmpty
                ? ConversationMarkdownSliver(content: summary.content)
                : SliverToBoxAdapter(
                    child: Text(
                      detail.pending ? recordingStatus(context, detail.row) : context.l10n.noSummaryAvailable,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
