import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/person.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/pages/conversation_detail/conversation_summary_selection.dart';
import 'package:omi/pages/conversation_detail/widgets/conversation_markdown_widget.dart';
import 'package:omi/pages/conversation_detail/widgets/note_sections_sliver.dart';
import 'package:omi/ui/components/omi_page_states.dart';
import 'package:omi/ui/format/omi_duration.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/widgets/transcript.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:path_provider/path_provider.dart';

import 'paired_library.dart';
import 'folder_picker.dart';
import 'recording_chat_page.dart';
import 'recording_edit.dart';
import 'recording_search.dart';
import 'recording_summary_page.dart';
import 'settings_labels.dart';
import 'speaker_picker.dart';
import 'task_editor.dart';
import 'task_suggestions_page.dart';

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
  const RecordingPage({
    super.key,
    required this.library,
    required this.id,
    this.initialMatch,
    this.verifyInitialExcerpt = false,
    this.onEdited,
  });
  final PairedLibrary library;
  final String id;
  final TranscriptMatchSnippet? initialMatch;
  final bool verifyInitialExcerpt;
  final ValueChanged<ServerConversation>? onEdited;

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
  bool _editing = false;
  final _people = <String, Person>{};

  @override
  void initState() {
    super.initState();
    if (widget.library.speakerLabelsAvailable) unawaited(_loadPeople());
  }

  Future<void> _loadPeople() async {
    try {
      final people = await widget.library.readLocalPeople();
      if (mounted) {
        setState(() {
          for (final person in people) {
            _people.putIfAbsent(person.id, () => person);
          }
        });
      }
    } catch (_) {
      // A failed directory read leaves the transcript available.
    }
  }

  Future<void> _labelSpeaker(_RecordingDetail loaded, String id) async {
    final line = loaded.sources.where((segment) => segment.id == id).firstOrNull;
    if (line == null) return;
    final group = loaded.lines
        .where((segment) => segment.speakerId == line.speakerId && segment.speakerIdScope == line.speakerIdScope)
        .toList();
    final canGroup =
        line.speakerId >= 0 && group.length > 1 && group.length <= 250 && group.every(loaded.sources.contains);
    final choice = await showModalBottomSheet<SpeakerChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => LocalSpeakerPicker(library: widget.library, canGroup: canGroup),
    );
    if (!mounted || choice == null) return;
    final person = choice.person;
    if (person != null) _people[person.id] = person;
    try {
      await _save(
        RecordingEdit.speaker(
          {
            for (final segment in choice.group ? group : [line])
              segment.id: {'person_id': segment.personId, 'is_user': segment.isUser},
          },
          {'person_id': person?.id, 'is_user': choice.isUser},
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(recordingEditError(context, error))));
      }
    }
  }

  bool _initialExcerptUnavailable = false;
  bool _canPlay(ServerConversation row) =>
      widget.library.audioPlayback &&
      (row.externalIntegration?.localRecording != null || row.externalIntegration?.localTranscript != null);

  bool _canEdit(_RecordingDetail loaded) =>
      widget.library.recordingEdits &&
      !loaded.pending &&
      !loaded.row.isLocked &&
      loaded.row.status == ConversationStatus.completed;

  Future<void> _save(RecordingEdit edit) async {
    if (opening || _editing) throw RecordingEditFailure.unavailable;
    setState(() => _editing = true);
    try {
      final row = await widget.library.editRecording(widget.id, edit);
      if (!mounted) return;
      setState(() {
        detail = SynchronousFuture(_RecordingDetail(row));
      });
      widget.onEdited?.call(row);
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _editText(_RecordingDetail loaded, {TranscriptSegment? line}) {
    final l = context.l10n;
    final initial = line?.text ?? loaded.row.structured.title;
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => RecordingTextEditor(
        label: line == null ? pairedSettingsLabel(context, 'recordingEditTitle') : l.transcript,
        initial: initial,
        maxLength: line == null ? 300 : 10000,
        multiline: line != null,
        onSave: (value) =>
            _save(line == null ? RecordingEdit.title(initial, value) : RecordingEdit.segment(line.id, initial, value)),
      ),
    );
  }

  Future<TranscriptSegment?> _pickLine(_RecordingDetail loaded) => showModalBottomSheet<TranscriptSegment>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.65,
      child: SafeArea(
        child: ListView.builder(
          itemCount: loaded.sources.length,
          itemBuilder: (context, index) {
            final line = loaded.sources[index];
            return ListTile(
              title: Text(line.text, maxLines: 3, overflow: TextOverflow.ellipsis),
              subtitle: Text(OmiDuration.offset(line.start)),
              onTap: () => Navigator.of(context).pop(line),
            );
          },
        ),
      ),
    ),
  );

  Future<void> _chooseLine(_RecordingDetail loaded) async {
    final line = await _pickLine(loaded);
    if (mounted && line != null) await _editText(loaded, line: line);
  }

  Future<void> _addTask(_RecordingDetail loaded, {bool useLine = false}) async {
    final line = useLine ? await _pickLine(loaded) : null;
    if (!mounted || (useLine && line == null)) return;
    final initial = line == null ? '' : String.fromCharCodes(line.text.trim().runes.take(4096));
    final created = await createLocalTask(
      context,
      widget.library,
      conversationId: widget.id,
      segmentId: line?.id,
      initial: initial,
    );
    if (created && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.saved)));
    }
  }

  Future<void> _changeStar(_RecordingDetail loaded) async {
    final before = loaded.row.starred;
    try {
      await _save(RecordingEdit.starred(before, !before));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(recordingEditError(context, error))));
      }
    }
  }

  Future<void> _moveFolder(_RecordingDetail loaded) async {
    final choice = await pickLocalFolder(context, widget.library, moving: true);
    if (!mounted || choice == null) return;
    try {
      await _save(RecordingEdit.folder(loaded.row.folderId, choice.folder?.id));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(recordingEditError(context, error))));
      }
    }
  }

  Future<_RecordingDetail> _load() async {
    final loaded = _RecordingDetail(await widget.library.detail(widget.id));
    final match = widget.initialMatch;
    if (match != null) {
      final found = _focusMatch(loaded, match, verifyExcerpt: widget.verifyInitialExcerpt);
      _initialExcerptUnavailable = widget.verifyInitialExcerpt && !found;
    }
    return loaded;
  }

  Future<void> _regenerateSummary() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RecordingSummaryPage(id: widget.id, library: widget.library),
      ),
    );
    if (!mounted || !widget.library.isSignedIn) return;
    final refreshed = widget.library.detail(widget.id).then(_RecordingDetail.new);
    setState(() {
      detail = refreshed;
    });
    try {
      final loaded = await refreshed;
      if (mounted) widget.onEdited?.call(loaded.row);
    } catch (_) {
      // The detail's FutureBuilder displays the normal retry state.
    }
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
        final canEdit = loaded != null && _canEdit(loaded);
        return Scaffold(
          appBar: AppBar(
            title: Text(row == null ? l.conversations : recordingTitle(context, row)),
            actions: [
              if (canEdit)
                PopupMenuButton<_RecordingEditAction>(
                  enabled: !opening && !_editing,
                  icon: Icon(loaded.row.starred ? Icons.star : Icons.more_horiz),
                  onSelected: (action) => switch (action) {
                    _RecordingEditAction.title => _editText(loaded),
                    _RecordingEditAction.star => _changeStar(loaded),
                    _RecordingEditAction.transcript => _chooseLine(loaded),
                    _RecordingEditAction.folder => _moveFolder(loaded),
                    _RecordingEditAction.task => _addTask(loaded),
                    _RecordingEditAction.taskFromLine => _addTask(loaded, useLine: true),
                    _RecordingEditAction.summary => _regenerateSummary(),
                    _RecordingEditAction.taskSuggestions => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => TaskSuggestionsPage(id: loaded.row.id, library: widget.library),
                      ),
                    ),
                  },
                  itemBuilder: (context) => [
                    if (widget.library.summaryRegenerationAvailable && loaded.lines.isNotEmpty)
                      PopupMenuItem(value: _RecordingEditAction.summary, child: Text(l.regenerateRecap)),
                    if (widget.library.tasksAvailable)
                      PopupMenuItem(value: _RecordingEditAction.task, child: Text(l.addTask)),
                    if (widget.library.tasksAvailable && loaded.sources.isNotEmpty)
                      PopupMenuItem(
                        value: _RecordingEditAction.taskFromLine,
                        child: Text(pairedSettingsLabel(context, 'localTaskFromLine')),
                      ),
                    if (widget.library.tasksAvailable &&
                        widget.library.taskSuggestionsAvailable &&
                        loaded.sources.isNotEmpty)
                      PopupMenuItem(
                        value: _RecordingEditAction.taskSuggestions,
                        child: Text(pairedSettingsLabel(context, 'localTaskSuggest')),
                      ),
                    if (widget.library.foldersAvailable)
                      PopupMenuItem(value: _RecordingEditAction.folder, child: Text(context.l10n.moveToFolder)),
                    PopupMenuItem(
                      value: _RecordingEditAction.title,
                      child: Text(pairedSettingsLabel(context, 'recordingEditTitle')),
                    ),
                    PopupMenuItem(
                      value: _RecordingEditAction.star,
                      child: Text(
                        pairedSettingsLabel(context, loaded.row.starred ? 'recordingUnstar' : 'recordingStar'),
                      ),
                    ),
                    if (loaded.sources.isNotEmpty)
                      PopupMenuItem(
                        value: _RecordingEditAction.transcript,
                        child: Text(pairedSettingsLabel(context, 'recordingEditTranscript')),
                      ),
                  ],
                ),
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
                    if (_initialExcerptUnavailable)
                      ListTile(title: Text(pairedSettingsLabel(context, 'recordingChatSourceUnavailable'))),
                    if (opening || _editing) const LinearProgressIndicator(),
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
                                  localPeople: _people.values.toList(),
                                  editSegment: canEdit && widget.library.speakerLabelsAvailable && !opening && !_editing
                                      ? (id, _) => _labelSpeaker(loaded, id)
                                      : null,
                                  isConversationDetail: true,
                                  bottomMargin: OmiSpacing.md,
                                  onSegmentTap: canPlay && !opening ? (line) => _openLine(line, canPlay: true) : null,
                                  onEditSegmentText: canEdit && !opening && !_editing
                                      ? (index) {
                                          final line = loaded.lines[index];
                                          if (loaded.sources.contains(line)) unawaited(_editText(loaded, line: line));
                                        }
                                      : null,
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

enum _RecordingEditAction { title, star, transcript, folder, task, taskFromLine, taskSuggestions, summary }

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
