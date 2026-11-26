import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:omi/utils/audio/conversation_playback_controller.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'paired_library.dart';
import 'offline_recordings.dart';
import 'folder_picker.dart';
import 'local_goals_page.dart';
import 'recording_chat_page.dart';
import 'recording_edit.dart';
import 'recording_export.dart';
import 'conversation_categories.dart';
import 'recording_search.dart';
import 'recording_summary_page.dart';
import 'recording_player_bar.dart';
import 'recording_playback.dart';
import 'settings_labels.dart';
import 'speaker_picker.dart';
import 'task_editor.dart';
import 'task_suggestions_page.dart';

String recordingTitle(BuildContext context, ServerConversation row) => row.externalIntegration?.localRecording != null
    ? context.l10n.recording
    : row.structured.title.trim().isEmpty
    ? context.l10n.untitledConversation
    : row.structured.title;

int recordingDuration(ServerConversation row) {
  final external = row.externalIntegration;
  final pendingDuration = external?.localRecording?['duration_seconds'];
  if (pendingDuration is num && pendingDuration.isFinite && pendingDuration > 0) return pendingDuration.round();
  final start = row.startedAt;
  final end = row.finishedAt;
  if (external?.localTranscript != null && start != null && end != null && !end.isBefore(start)) {
    return (end.difference(start).inMicroseconds / Duration.microsecondsPerSecond).round();
  }
  return row.getDurationInSeconds();
}

String recordingInput(BuildContext context, ServerConversation row) {
  final origin = (row.externalIntegration?.localRecording ?? row.externalIntegration?.localTranscript)?['origin'];
  final model = origin is Map ? origin['phone_model'] : null;
  final platform = origin is Map ? origin['phone_platform'] : null;
  final phone = model is String && model.isNotEmpty
      ? model
      : switch (platform) {
          'ios' => 'iPhone',
          'android' => 'Android',
          _ => '',
        };
  final input = switch (row.source?.name) {
    'omi' => 'CV1',
    'phone' => pairedSettingsLabel(context, 'nextPhoneInput'),
    _ => '',
  };
  return [phone, input].where((s) => s.isNotEmpty).join(' · ');
}

String recordingFailure(BuildContext context, Object? failure) {
  String label(String key) => pairedSettingsLabel(context, key);
  final fields = failure is Map ? failure : const {};
  final stage = switch (fields['stage']) {
    'prepare' => label('nextFailedPreparation'),
    'stt' => context.l10n.transcription,
    'diarization' => label('diarization'),
    'summary' => context.l10n.summary,
    'import' => label('nextFailedImport'),
    _ => label('nextFailedStage'),
  };
  final code = fields['code'];
  final reason = switch (code) {
    'configuration' => label('nextProviderConfiguration'),
    'credential_missing' => label('nextProviderCredentialMissing'),
    'database_preflight_failed' => label('nextDatabasePreflight'),
    'import_failed' => label('nextImportUnavailable'),
    'invalid_audio' => label('nextInvalidAudio'),
    'invalid_checkpoint' => label('nextInvalidCheckpoint'),
    'invalid_diarization' => label('nextInvalidDiarization'),
    'invalid_json' => label('nextInvalidJson'),
    'invalid_provider_response' => label('nextInvalidProviderResponse'),
    'invalid_summary' => label('nextInvalidSummary'),
    'invalid_transcript' => label('nextInvalidTranscript'),
    'output_limit' => label('nextOutputLimit'),
    'response_encoding' => label('nextProviderEncoding'),
    'response_too_large' => label('nextProviderResponseSize'),
    'disk_full' => label('nextServerDiskFull'),
    'storage_access' => label('nextServerStorageAccess'),
    'io_error' => label('nextServerIOError'),
    'summary_model_unavailable' => label('nextSummaryModelUnavailable'),
    'connection' => label('nextProviderConnection'),
    'timeout' => label('nextProviderTimeout'),
    'unknown' => label('nextUnclassifiedFailure'),
    String s when RegExp(r'^http_[1-5][0-9]{2}$').hasMatch(s) => _providerHttpFailure(
      context,
      int.parse(s.substring(5)),
    ),
    _ => label('nextUnknownCause'),
  };
  final attempts = fields['attempts'];
  return [stage, reason, if (attempts is int && attempts > 0) '${label("nextAttempts")}: $attempts'].join(' · ');
}

String _providerHttpFailure(BuildContext context, int status) {
  final hint = switch (status) {
    401 || 403 => 'nextHttpAuthorization',
    404 => 'nextHttpNotFound',
    413 => 'nextHttpInputSize',
    429 => 'nextHttpRateLimit',
    400 || 415 || 422 => 'nextHttpRequest',
    >= 300 && < 400 => 'nextHttpRedirect',
    >= 500 => 'nextHttpServer',
    _ => 'nextHttpGeneric',
  };
  return '${pairedSettingsLabel(context, 'nextProviderHttp')} $status. ${pairedSettingsLabel(context, hint)}';
}

String? recordingDiarization(BuildContext context, ServerConversation row) {
  final stages = row.externalIntegration?.localTranscript?['stages'];
  if (stages is! Map || stages['diarization'] is! Map) return null;
  final stage = stages['diarization'] as Map;
  String label(String key) => pairedSettingsLabel(context, key);
  final speakers = stage['speakers'];
  final outcome = switch (stage['status']) {
    'ready' when speakers is int && speakers >= 0 => label('speakersCount').replaceAll('{count}', '$speakers'),
    'ready' => label('modelReady'),
    'disabled' || 'no_speech' => label('diarizationNotPerformed'),
    'failed' => label('diarizationFailed'),
    'pending' || 'processing' => context.l10n.processing,
    _ => context.l10n.unknown,
  };
  final provider = stage['provider'];
  return [
    label('diarization'),
    if (stage['status'] != 'disabled' && provider is String && provider.trim().isNotEmpty) provider,
    outcome,
  ].join(' · ');
}

String recordingStatus(BuildContext context, ServerConversation row) {
  final local = row.externalIntegration?.localRecording;
  return switch (local == null ? row.status.name : local['status']) {
    'failed' => local == null ? context.l10n.processingFailed : recordingFailure(context, local['failure']),
    'pending' => context.l10n.statusPending,
    'processing' => context.l10n.statusProcessing,
    'waiting_for_parts' => pairedSettingsLabel(context, 'nextWaitingForParts'),
    'receiving' => pairedSettingsLabel(context, 'nextReceivingRecording'),
    'no_speech' => context.l10n.noTranscriptAvailable,
    _ => context.l10n.saved,
  };
}

const _recordingProcessing = {'saved', 'pending', 'processing', 'waiting_for_parts', 'receiving'};

bool canFollowSavedRecording(ServerConversation row) =>
    const {..._recordingProcessing, 'failed', 'published'}.contains(row.externalIntegration?.localRecording?['status']);

class RecordingPage extends StatefulWidget {
  const RecordingPage({
    super.key,
    required this.library,
    required this.id,
    this.initialMatch,
    this.verifyInitialExcerpt = false,
    this.onEdited,
    this.fromSavedRecording = false,
    this.onPublished,
    this.resultsParentId,
    this.currentResultId,
    this.offlineOnly = false,
  });
  final PairedLibrary library;
  final String id;
  final TranscriptMatchSnippet? initialMatch;
  final bool verifyInitialExcerpt;
  final ValueChanged<ServerConversation>? onEdited;
  final bool fromSavedRecording;
  final void Function(String previousId, List<ServerConversation> rows)? onPublished;
  final String? resultsParentId;
  final String? currentResultId;
  final bool offlineOnly;

  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage> with SingleTickerProviderStateMixin {
  late final TabController tabs;
  late String _id = widget.id;
  late bool _followSavedRecording = widget.fromSavedRecording;
  String? _resultsParent;
  OfflineRecording? _offlineCopy;
  bool _downloaded = false;
  bool _downloading = false;
  bool get _readingOffline => _offlineCopy != null;
  late Future<_RecordingDetail> detail = _load();
  Timer? _processingPoll;
  final playback = ConversationPlaybackController();
  StreamSubscription<Duration>? positionUpdates;
  StreamSubscription<PlaybackEvent>? playbackEvents;

  _RecordingDetail _readDetail(ServerConversation row) {
    final loaded = _RecordingDetail(row);
    if (mounted) playback.updateSegments(loaded.lines);
    return loaded;
  }

  String? focusedLine;
  int focusRequest = 0;
  AudioPlayer? player;
  double speed = 1;
  RecordingPlayback? _audioSource;
  Duration? _initialPosition;
  bool opening = false;
  bool _editing = false;
  final _people = <String, Person>{};

  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 2, vsync: this, initialIndex: widget.initialMatch == null ? 0 : 1);
    if (!widget.offlineOnly && widget.library.speakerLabelsAvailable) {
      unawaited(_loadPeople());
    }
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
      _readingOffline ||
      (widget.library.audioPlayback &&
          row.externalIntegration?.localRecording?['group'] != true &&
          row.externalIntegration?.localRecording?['results'] == null &&
          row.externalIntegration?.localRecording?['status'] != 'waiting_for_parts' &&
          (row.externalIntegration?.localRecording != null || row.externalIntegration?.localTranscript != null));

  bool _canEdit(_RecordingDetail loaded) =>
      !_readingOffline &&
      widget.library.recordingEdits &&
      !loaded.pending &&
      !loaded.row.isLocked &&
      loaded.row.status == ConversationStatus.completed;

  Future<void> _save(RecordingEdit edit) async {
    if (opening || _editing) throw RecordingEditFailure.unavailable;
    setState(() => _editing = true);
    try {
      final row = await widget.library.editRecording(_id, edit);
      if (!mounted) return;
      setState(() {
        detail = SynchronousFuture(_readDetail(row));
      });
      widget.onEdited?.call(row);
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _changeCategory(_RecordingDetail loaded) async {
    final current = conversationCategoryKey(loaded.row.structured.category);
    final choice = await pickConversationCategory(context, current: current);
    if (!mounted || choice == null || choice == current) return;
    try {
      await _save(RecordingEdit.category(current, choice));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(recordingEditError(context, error))));
      }
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
      conversationId: _id,
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
    final library = widget.library;
    final ServerConversation row;
    if (widget.offlineOnly) {
      if (!library.canOpenOffline) throw LibraryFailure.key;
      final copy = await library.offlineRecordings.read(_id);
      if (copy == null) throw OfflineRecordingFailure.unavailable;
      row = await copy.readDetail();
      if (!library.canOpenOffline) throw LibraryFailure.key;
      if (mounted) _offlineCopy = copy;
    } else {
      row = await (_followSavedRecording ? library.refreshSavedRecording(_id) : library.detail(_id));
    }
    final loaded = _acceptRead(row);
    if (!mounted) return loaded;
    final match = widget.initialMatch;
    if (match != null) {
      final found = _focusMatch(loaded, match, verifyExcerpt: widget.verifyInitialExcerpt);
      _initialExcerptUnavailable = widget.verifyInitialExcerpt && !found;
    }
    return loaded;
  }

  _RecordingDetail _acceptRead(ServerConversation row) {
    final loaded = _readDetail(row);
    if (!mounted) return loaded;
    final before = _id;
    _id = row.id;
    final parent = row.externalIntegration?.localTranscript?['recording_results_id'];
    _resultsParent = parent is String && parent != row.id && parent != widget.resultsParentId ? parent : null;
    _followSavedRecording = canFollowSavedRecording(row);
    _processingPoll?.cancel();
    if (_recordingProcessing.contains(loaded.localState)) {
      _scheduleProcessingPoll();
    } else if (loaded.results case final results?) {
      widget.onPublished?.call(before, results);
    }
    if (before != row.id) widget.onPublished?.call(before, [row]);
    if (!_readingOffline &&
        widget.library.audioPlayback &&
        row.status == ConversationStatus.completed &&
        row.externalIntegration?.localTranscript != null) {
      unawaited(_checkDownloaded(row.id));
    }
    return loaded;
  }

  Future<void> _checkDownloaded(String id) async {
    try {
      final saved = await widget.library.offlineRecordings.read(id);
      if (mounted && _id == id) setState(() => _downloaded = saved != null);
    } on Exception {
      // A storage lookup should not prevent viewing an online conversation.
    }
  }

  Future<void> _download() async {
    if (opening || _downloading) return;
    setState(() => _downloading = true);
    try {
      await widget.library.saveOfflineRecording(_id);
      if (mounted) setState(() => _downloaded = true);
    } catch (error) {
      if (mounted) {
        final key = error == OfflineRecordingFailure.limit ? 'nextOfflineLimit' : 'nextOfflineDownloadFailed';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(pairedSettingsLabel(context, key))));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Widget _recordingResults(_RecordingDetail loaded, List<ServerConversation> rows) => ListView(
    children: [
      if (loaded.localState != 'published') ListTile(title: Text(recordingStatus(context, loaded.row))),
      for (final row in rows)
        ListTile(
          key: ValueKey(row.id),
          title: Text(recordingTitle(context, row)),
          subtitle: Text(
            [
              if (row.startedAt case final started?)
                MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(started.toLocal())),
              if (_recordingMetadata(context, row) case final meta?) meta,
              if (row.externalIntegration?.localTranscript?['model'] case final String model) model,
              if (row.externalIntegration?.localRecording != null) recordingStatus(context, row),
            ].join(' · '),
          ),
          trailing: Icon(row.id == widget.currentResultId ? Icons.check : Icons.chevron_right),
          onTap: () => _openRecordingResult(row),
        ),
    ],
  );

  Future<void> _openRecordingResult(ServerConversation row) async {
    if (row.id == widget.currentResultId) {
      Navigator.of(context).pop();
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RecordingPage(
          library: widget.library,
          id: row.id,
          fromSavedRecording: canFollowSavedRecording(row),
          resultsParentId: _id,
          onEdited: widget.onEdited,
          onPublished: widget.onPublished,
        ),
      ),
    );
    if (mounted && widget.library.isSignedIn) {
      setState(() {
        detail = _load();
      });
    }
  }

  Future<void> _openResultsParent() async {
    final parent = _resultsParent;
    if (parent == null) return;
    try {
      await player?.pause();
    } catch (_) {
      _playFailed();
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RecordingPage(
          library: widget.library,
          id: parent,
          fromSavedRecording: true,
          currentResultId: _id,
          onEdited: widget.onEdited,
          onPublished: widget.onPublished,
        ),
      ),
    );
  }

  void _scheduleProcessingPoll() {
    _processingPoll = Timer(const Duration(seconds: 5), _refreshProcessingDetail);
  }

  bool get _canPoll =>
      ModalRoute.isCurrentOf(context) == true &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      !_editing &&
      !opening;

  Future<void> _refreshProcessingDetail() async {
    if (!mounted || !widget.library.isSignedIn) return;
    if (_canPoll) {
      ServerConversation? row;
      try {
        row = await widget.library.refreshSavedRecording(_id);
      } catch (_) {
        // A temporary server failure leaves the last confirmed recording visible.
      }
      if (!mounted || !widget.library.isSignedIn) return;
      if (row != null && _canPoll) {
        final loaded = _acceptRead(row);
        setState(() {
          detail = SynchronousFuture(loaded);
        });
        return;
      }
    }
    if (mounted && widget.library.isSignedIn) _scheduleProcessingPoll();
  }

  final _menu = GlobalKey();

  Rect? get _shareOrigin {
    final box = _menu.currentContext?.findRenderObject() as RenderBox?;
    return box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _copy(String text, String message) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } on PlatformException {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.somethingWentWrong)));
    }
  }

  Future<void> _shareAudio() async {
    if (opening) return;
    setState(() => opening = true);
    Directory? scratch;
    try {
      var audio = _offlineCopy?.audio;
      if (audio == null) {
        scratch = await (await getTemporaryDirectory()).createTemp('next-share-');
        audio = File('${scratch.path}/recording.wav');
        await widget.library.downloadAudio(_id, audio);
      } else if (!widget.library.canOpenOffline) {
        throw LibraryFailure.key;
      }
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(audio.path, mimeType: 'audio/wav')],
          sharePositionOrigin: _shareOrigin,
        ),
      );
    } catch (_) {
      _playFailed();
    } finally {
      if (scratch != null && await scratch.exists()) await scratch.delete(recursive: true);
      if (mounted) setState(() => opening = false);
    }
  }

  Future<void> _export(ServerConversation row) async {
    try {
      await shareLocalConversation(
        row,
        summaryLabel: context.l10n.summary,
        transcriptLabel: context.l10n.transcriptTab,
        origin: _shareOrigin,
      );
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.somethingWentWrong)));
    }
  }

  Future<void> _retryProcessing() async {
    if (_editing) return;
    setState(() => _editing = true);
    try {
      await widget.library.retryProcessing(_id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(pairedSettingsLabel(context, 'nextRetryQueued'))));
      setState(() {
        detail = _load();
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(recordingEditError(context, error))));
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _regenerateSummary() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RecordingSummaryPage(id: _id, library: widget.library),
      ),
    );
    if (!mounted || !widget.library.isSignedIn) return;
    final refreshed = widget.library.detail(_id).then(_acceptRead);
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
        builder: (_) => RecordingChatPage(id: _id, library: widget.library),
      ),
    );
    if (!mounted || match == null) return;
    setState(() => opening = true);
    try {
      await player?.pause();
      final loaded = _readDetail(await widget.library.detail(_id));
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
    playback.backToCurrent();
    if (canPlay && line.start.isFinite && line.start >= 0) {
      unawaited(_start(position: Duration(milliseconds: (line.start * 1000).round())));
    }
  }

  Future<void> _start({Duration? position}) async {
    if (opening) return;
    setState(() => opening = true);
    try {
      final target = position ?? _initialPosition;
      if (player == null) {
        final savedAudio = _offlineCopy?.audio;
        if (savedAudio != null && !widget.library.canOpenOffline) throw LibraryFailure.key;
        final source = savedAudio == null ? await RecordingPlayback.open(widget.library, _id) : null;
        if (!mounted) {
          await source?.close();
          return;
        }
        _audioSource = source;
        final fresh = AudioPlayer();
        try {
          if (savedAudio != null) {
            await fresh.setFilePath(savedAudio.path, initialPosition: target);
          } else {
            await fresh.setUrl(source!.uri.toString(), initialPosition: target);
          }
          await fresh.setSpeed(speed);
          if (!mounted) return;
          player = fresh;
          positionUpdates = fresh.positionStream.listen((position) {
            if (mounted) _reportPosition(position);
          });
          playbackEvents = fresh.playbackEventStream.listen((_) {}, onError: (Object _) => _resetPlayback(fresh));
        } finally {
          if (player != fresh) {
            if (identical(_audioSource, source)) _audioSource = null;
            await source?.close();
            await fresh.dispose();
          }
        }
      } else if (target != null) {
        await player!.seek(target);
      } else if (player!.processingState == ProcessingState.completed) {
        await player!.seek(Duration.zero);
      }
      final current = player;
      if (!mounted || current == null) return;
      _initialPosition = null;
      focusedLine = null;
      _reportPosition(current.position);
      if (!current.playing) {
        // play() completes on stop/end, so the control must be released before then.
        unawaited(current.play().catchError((Object _) => _resetPlayback(current)));
      }
    } catch (_) {
      if (mounted && position != null) _initialPosition = position;
      _playFailed();
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  void _resetPlayback(AudioPlayer failed) {
    if (!mounted || !identical(player, failed)) return;
    setState(() {
      _initialPosition = failed.position;
      _releasePlayback();
    });
    _playFailed();
  }

  void _releasePlayback() {
    unawaited(positionUpdates?.cancel());
    unawaited(playbackEvents?.cancel());
    unawaited(_audioSource?.close());
    unawaited(player?.dispose());
    _audioSource = null;
    player = null;
  }

  bool get _hasPlayhead => player != null || _initialPosition != null;

  void _reportPosition(Duration position) {
    playback.reportPlayback(
      wallSeconds: position.inMilliseconds / 1000,
      playing: player?.playing == true,
      loaded: player != null,
    );
  }

  Future<void> _scrub(Duration target) async {
    if (opening) return;
    focusedLine = null;
    playback.backToCurrent();
    final current = player;
    if (current == null) {
      setState(() => _initialPosition = target);
      _reportPosition(target);
      return;
    }
    try {
      await current.seek(target);
      if (mounted) {
        setState(() => _initialPosition = null);
        _reportPosition(current.position);
      }
    } catch (_) {
      _playFailed();
    }
  }

  Future<void> _setSpeed(double value) async {
    try {
      await player?.setSpeed(value);
      if (mounted) setState(() => speed = value);
    } catch (_) {
      _playFailed();
    }
  }

  void _playFailed() {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.audioPlaybackUnavailable)));
    }
  }

  @override
  void dispose() {
    _processingPoll?.cancel();
    _releasePlayback();
    playback.dispose();
    tabs.dispose();
    super.dispose();
  }

  Widget _playbackControls(Duration estimatedDuration) => StreamBuilder<PlayerState>(
    stream: player?.playerStateStream,
    builder: (context, state) {
      final playing = state.data?.playing == true && state.data?.processingState != ProcessingState.completed;
      return ValueListenableBuilder<double>(
        valueListenable: playback.wallPosition,
        builder: (context, seconds, _) => RecordingPlayerBar(
          duration: player?.duration ?? estimatedDuration,
          position: _initialPosition ?? Duration(milliseconds: (seconds * 1000).round()),
          playing: playing,
          speed: speed,
          onSpeed: opening ? null : _setSpeed,
          onToggle: opening
              ? null
              : () async {
                  if (!playing) return _start();
                  try {
                    await player?.pause();
                  } catch (_) {
                    _playFailed();
                  }
                },
          onSeek: opening ? null : _scrub,
        ),
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
        final diarization = row == null ? null : recordingDiarization(context, row);
        return Scaffold(
          appBar: AppBar(
            title: Text(
              loaded?.results != null
                  ? pairedSettingsLabel(context, 'nextRecordingResults')
                  : row == null
                  ? l.conversations
                  : recordingTitle(context, row),
            ),
            actions: [
              if (loaded != null && loaded.results == null)
                PopupMenuButton<_RecordingEditAction>(
                  key: _menu,
                  enabled: !opening && !_editing,
                  icon: Icon(loaded.row.starred ? Icons.star : Icons.more_horiz),
                  onSelected: (action) => switch (action) {
                    _RecordingEditAction.export => _export(loaded.row),
                    _RecordingEditAction.copySummary => _copy(loaded.summary.content, l.summaryCopiedToClipboard),
                    _RecordingEditAction.copyTranscript => _copy(
                      loaded.row.getTranscript(generate: true),
                      l.transcriptCopiedToClipboard,
                    ),
                    _RecordingEditAction.copyId => _copy(loaded.row.id, l.conversationIdCopied),
                    _RecordingEditAction.recordingResults => _openResultsParent(),
                    _RecordingEditAction.audio => _shareAudio(),
                    _RecordingEditAction.offline => _download(),
                    _RecordingEditAction.title => _editText(loaded),
                    _RecordingEditAction.star => _changeStar(loaded),
                    _RecordingEditAction.transcript => _chooseLine(loaded),
                    _RecordingEditAction.folder => _moveFolder(loaded),
                    _RecordingEditAction.category => _changeCategory(loaded),
                    _RecordingEditAction.task => _addTask(loaded),
                    _RecordingEditAction.taskFromLine => _addTask(loaded, useLine: true),
                    _RecordingEditAction.goalProgress => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => LocalGoalsPage(library: widget.library, conversationId: loaded.row.id),
                      ),
                    ),
                    _RecordingEditAction.summary => _regenerateSummary(),
                    _RecordingEditAction.taskSuggestions => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => TaskSuggestionsPage(id: loaded.row.id, library: widget.library),
                      ),
                    ),
                  },
                  itemBuilder: (context) => [
                    if (!_readingOffline &&
                        canPlay &&
                        loaded.row.status == ConversationStatus.completed &&
                        loaded.row.externalIntegration?.localTranscript != null)
                      PopupMenuItem(
                        value: _RecordingEditAction.offline,
                        enabled: !_downloaded && !_downloading,
                        child: Text(
                          pairedSettingsLabel(context, _downloaded ? 'nextOfflineDownloaded' : 'nextOfflineDownload'),
                        ),
                      ),
                    if (_resultsParent != null)
                      PopupMenuItem(
                        value: _RecordingEditAction.recordingResults,
                        child: Text(pairedSettingsLabel(context, 'nextOpenRecordingResults')),
                      ),
                    if (!loaded.pending)
                      PopupMenuItem(value: _RecordingEditAction.export, child: Text('${l.share} · TXT')),
                    if (loaded.summary.content.isNotEmpty)
                      PopupMenuItem(value: _RecordingEditAction.copySummary, child: Text(l.copySummary)),
                    if (loaded.lines.isNotEmpty)
                      PopupMenuItem(value: _RecordingEditAction.copyTranscript, child: Text(l.copyTranscript)),
                    if (canPlay) PopupMenuItem(value: _RecordingEditAction.audio, child: Text(l.shareAudio)),
                    PopupMenuItem(value: _RecordingEditAction.copyId, child: Text(l.copyConversationId)),
                    if (canEdit) ...[
                      if (widget.library.goalsAvailable)
                        PopupMenuItem(
                          value: _RecordingEditAction.goalProgress,
                          child: Text(pairedSettingsLabel(context, 'localGoalLog')),
                        ),
                      if ((widget.library.summaryRegenerationAvailable || widget.library.summaryJobsAvailable) &&
                          loaded.lines.isNotEmpty)
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
                      if (widget.library.recordingCategories)
                        PopupMenuItem(
                          value: _RecordingEditAction.category,
                          child: Text(pairedSettingsLabel(context, 'recordingEditCategory')),
                        ),
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
                  ],
                ),
              if (!_readingOffline && loaded != null && loaded.lines.isNotEmpty)
                IconButton(
                  tooltip: l.askOmi,
                  icon: const Icon(Icons.chat_bubble_outline),
                  onPressed: opening ? null : _openChat,
                ),
              if (loaded != null && loaded.results == null)
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
              : loaded.results != null
              ? _recordingResults(loaded, loaded.results!)
              : Column(
                  children: [
                    if (widget.library.processingRetryAvailable && loaded.failed)
                      TextButton.icon(
                        icon: const Icon(Icons.refresh),
                        onPressed: _editing ? null : _retryProcessing,
                        label: Text(pairedSettingsLabel(context, 'nextRetryProcessing')),
                      ),
                    if (_recordingMetadata(context, loaded.row) case final metadata?) Text(metadata),
                    if (_readingOffline) Text(pairedSettingsLabel(context, 'nextOfflineCopy')),
                    if (!loaded.pending && loaded.row.status == ConversationStatus.completed)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(conversationCategoryLabel(context, loaded.row.structured.category)),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: OmiSpacing.md),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: OmiColors.border)),
                        ),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TabBar(
                            controller: tabs,
                            isScrollable: true,
                            padding: EdgeInsets.zero,
                            tabAlignment: TabAlignment.start,
                            labelPadding: const EdgeInsetsDirectional.only(end: 22),
                            labelStyle: OmiType.subhead.copyWith(fontWeight: FontWeight.w600),
                            labelColor: OmiColors.textPrimary,
                            unselectedLabelColor: OmiColors.textTertiary,
                            indicator: UnderlineTabIndicator(borderSide: BorderSide(color: OmiColors.accent, width: 2)),
                            indicatorSize: TabBarIndicatorSize.label,
                            tabs: [
                              Tab(text: l.summary),
                              Tab(text: l.transcript),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (canPlay) _playbackControls(Duration(seconds: recordingDuration(loaded.row))),
                    if (loaded.failed)
                      Padding(
                        padding: const EdgeInsets.all(OmiSpacing.md),
                        child: SelectableText(recordingStatus(context, loaded.row)),
                      ),
                    if (_initialExcerptUnavailable)
                      ListTile(title: Text(pairedSettingsLabel(context, 'recordingChatSourceUnavailable'))),
                    if (opening || _editing || _downloading) const LinearProgressIndicator(),
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
                                    loaded.pending
                                        ? (loaded.failed
                                              ? l.noTranscriptAvailable
                                              : recordingStatus(context, loaded.row))
                                        : [l.noTranscriptAvailable, if (diarization != null) diarization].join('\n'),
                                  ),
                                )
                              : ListenableBuilder(
                                  listenable: playback,
                                  builder: (context, _) => TranscriptWidget(
                                    segments: loaded.lines,
                                    leadingItemIds: [if (diarization != null) 'local-diarization'],
                                    leadingItems: [
                                      if (diarization != null)
                                        ListTile(leading: const Icon(Icons.people_outline), title: Text(diarization)),
                                    ],
                                    localPeople: _people.values.toList(),
                                    editSegment:
                                        canEdit && widget.library.speakerLabelsAvailable && !opening && !_editing
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
                                    currentSegmentId: focusedLine ?? (_hasPlayhead ? playback.currentSegmentId : null),
                                    followTargetSegmentId:
                                        focusedLine ?? (_hasPlayhead ? playback.followTargetSegmentId : null),
                                    playbackFollowRequest: focusRequest + playback.followRequest,
                                    followCurrentSegment: playback.isFollowing,
                                    onUserScroll: playback.suspendFollowing,
                                  ),
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

enum _RecordingEditAction {
  offline,
  recordingResults,
  export,
  audio,
  copySummary,
  copyTranscript,
  copyId,
  title,
  star,
  transcript,
  folder,
  category,
  task,
  taskFromLine,
  taskSuggestions,
  summary,
  goalProgress,
}

String? _recordingMetadata(BuildContext context, ServerConversation row) {
  final duration = recordingDuration(row);
  final input = recordingInput(context, row);
  final labels = [if (input.isNotEmpty) input, if (duration > 0) OmiDuration.compact(duration, context.l10n)];
  return labels.isEmpty ? null : labels.join(' · ');
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
  Object? get localState => row.externalIntegration?.localRecording?['status'];
  bool get failed => localState == 'failed';
  late final List<ServerConversation>? results = _readResults();

  List<ServerConversation>? _readResults() {
    final raw = row.externalIntegration?.localRecording?['results'];
    if (raw is! List) return null;
    final ids = <String>{row.id};
    final results = <ServerConversation>[];
    for (final entry in raw.whereType<Map<String, dynamic>>()) {
      try {
        final result = ServerConversation.fromJson(entry);
        if (ids.add(result.id)) results.add(result);
      } on TypeError {
        continue;
      } on FormatException {
        continue;
      }
    }
    return results;
  }
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
                : detail.failed
                ? const SliverToBoxAdapter()
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
