import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:omi/backend/schema/gen/conversation_wire.g.dart';
import 'package:omi/ui/components/omi_page_states.dart';
import 'package:omi/ui/format/omi_duration.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:path_provider/path_provider.dart';

import 'paired_library.dart';
import 'recording_search.dart';

String recordingTitle(BuildContext context, GeneratedConversation row) => row.externalData?['local_recording'] is Map
    ? context.l10n.recording
    : row.structured.title.trim().isEmpty
    ? context.l10n.untitledConversation
    : row.structured.title;

String recordingStatus(BuildContext context, GeneratedConversation row) {
  final local = row.externalData?['local_recording'];
  return switch (local is Map ? local['status'] : row.status) {
    'failed' => context.l10n.processingFailed,
    'pending' => context.l10n.statusPending,
    'processing' => context.l10n.statusProcessing,
    'no_speech' => context.l10n.noTranscriptAvailable,
    _ => context.l10n.saved,
  };
}

class RecordingPage extends StatefulWidget {
  const RecordingPage({super.key, required this.library, required this.id});
  final PairedLibrary library;
  final String id;

  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage> {
  late Future<GeneratedConversation> detail = widget.library.detail(widget.id);
  AudioPlayer? player;
  Directory? temp;
  bool opening = false;
  bool _canPlay(GeneratedConversation row) =>
      widget.library.audioPlayback &&
      (row.externalData?['local_recording'] is Map || row.externalData?['local_transcript'] is Map);

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
          if (temp != folder && await folder.exists()) await folder.delete(recursive: true);
        }
      }
      if (!mounted) return;
      final current = player!;
      if (position != null) {
        await current.seek(position);
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
    final current = player;
    final folder = temp;
    temp = null;
    unawaited(() async {
      try {
        await current?.dispose();
      } finally {
        if (folder != null && await folder.exists()) await folder.delete(recursive: true);
      }
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.transcript),
        actions: [
          FutureBuilder<GeneratedConversation>(
            future: detail,
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const SizedBox.shrink();
              final row = snapshot.requireData;
              return IconButton(
                tooltip: l.search,
                icon: const Icon(Icons.search),
                onPressed: () async {
                  final position = await Navigator.push<Duration>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => RecordingSearch(row: row, canPlay: _canPlay(row)),
                    ),
                  );
                  if (mounted && position != null) await _start(position: position);
                },
              );
            },
          ),
        ],
      ),
      body: FutureBuilder<GeneratedConversation>(
        future: detail,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const OmiLoadingState();
          if (!snapshot.hasData) {
            return OmiErrorState(
              message: snapshot.error == LibraryFailure.key ? l.invalidKey : l.couldNotLoadPage,
              onRetry: () => setState(() => detail = widget.library.detail(widget.id)),
            );
          }
          final row = snapshot.requireData;
          final canPlay = _canPlay(row);
          final current = player;
          return ListView.builder(
            itemCount: 1 + row.transcriptSegments.length,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(recordingTitle(context, row), style: Theme.of(context).textTheme.headlineSmall),
                      if (row.structured.overview.isNotEmpty) SelectableText(row.structured.overview),
                      if (canPlay)
                        StreamBuilder<PlayerState>(
                          stream: current?.playerStateStream,
                          builder: (context, state) {
                            final playing =
                                state.data?.playing == true && state.data?.processingState != ProcessingState.completed;
                            return TextButton.icon(
                              onPressed: opening
                                  ? null
                                  : playing
                                  ? () async {
                                      try {
                                        await current?.pause();
                                      } catch (_) {
                                        _playFailed();
                                      }
                                    }
                                  : _start,
                              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                              label: Text(playing ? l.pause : l.play),
                            );
                          },
                        ),
                      if (opening) const LinearProgressIndicator(),
                      if (row.transcriptSegments.isEmpty)
                        Text(
                          row.externalData?['local_recording'] is Map
                              ? recordingStatus(context, row)
                              : l.noTranscriptAvailable,
                        ),
                    ],
                  ),
                );
              }
              final segment = row.transcriptSegments[i - 1];
              return ListTile(
                leading: Text(OmiDuration.offset(segment.start)),
                title: Text(segment.text),
                onTap: canPlay && !opening
                    ? () => _start(position: Duration(milliseconds: (segment.start * 1000).round()))
                    : null,
              );
            },
          );
        },
      ),
    );
  }
}
