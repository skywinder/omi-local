import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:intl/intl.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/capture/local_audio_journal.dart';
import 'package:omi/services/devices/ring_protocol.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'accents.dart';
import 'capture.dart';
import 'cv1_capture.dart';
import 'cv1_archive.dart';
import 'cv1_resume.dart';
import 'cv1_sync_progress.dart';
import 'cv1_transport.dart';
import 'device_diagnostics_page.dart';
import 'live_preview.dart';
import 'live_view.dart';
import 'live_tuning.dart';
import 'paired_library.dart';
import 'processing_page.dart';
import 'server_status_page.dart';
import 'settings_labels.dart';

String _storageSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1 << 20) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1 << 20)).toStringAsFixed(1)} MiB';
}

class LocalNextCapturePanel extends StatefulWidget {
  const LocalNextCapturePanel({
    required this.library,
    required this.serverName,
    this.onDelivered,
    this.onInputsReady,
    this.openServers,
    super.key,
  });
  final PairedLibrary library;
  final String serverName;
  final VoidCallback? onDelivered;
  final ValueChanged<NextCaptureInputs>? onInputsReady;
  final VoidCallback? openServers;

  @override
  State<LocalNextCapturePanel> createState() => NextCapturePanelState();
}

class NextCapturePanelState extends State<LocalNextCapturePanel> with WidgetsBindingObserver {
  // Release the previous owner's microphone and journal before recovering files.
  static Future<void> _previousRelease = Future.value();
  late final Future<void> _setup;
  bool _initialized = false;
  bool _captureBusy() => !_initialized || _inputs?.hasCaptureInProgress == true;
  LocalAudioJournal? _journal;
  int _deliveryRevision = 0;
  NextCaptureInputs? _inputs;
  final _hasCv1 = {TargetPlatform.iOS, TargetPlatform.android}.contains(defaultTargetPlatform);
  bool _storageFailed = false;
  bool _closed = false;
  final _groupSilence = ValueNotifier<int?>(null);
  final _keepListening = ValueNotifier(false);
  Cv1DoubleTapAction _doubleTap = Cv1DoubleTapAction.checkpoint;
  static const _doubleTapKey = 'next.cv1.doubleTap';
  SharedPreferences? _groupPrefs;
  Timer? _diagnosticPoll;
  String get _groupPrefKey => 'next.capture.groupSilence.${widget.library.audioOwnerId}';
  String get _keepListeningKey => 'next.capture.keepListeningAfterSilence.${widget.library.audioOwnerId}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.library.ownerChange.attachCapture(_captureBusy);
    _setup = _initialize(widget.library, _previousRelease).whenComplete(() {
      _initialized = true;
    });
  }

  Future<void> _initialize(PairedLibrary library, Future<void> previous) async {
    try {
      await previous;
      if (_closed || !library.audioDelivery) return;
      final documents = await getApplicationDocumentsDirectory();
      try {
        _groupPrefs = await SharedPreferences.getInstance();
        final value = _groupPrefs?.getInt(_groupPrefKey);
        if (LocalAudioJournal.groupSilenceChoices.contains(value)) _groupSilence.value = value;
        _keepListening.value = _groupPrefs?.getBool(_keepListeningKey) ?? false;
        final gesture = _groupPrefs?.getString(_doubleTapKey);
        _doubleTap =
            Cv1DoubleTapAction.values.where((action) => action.name == gesture).firstOrNull ??
            Cv1DoubleTapAction.checkpoint;
      } catch (_) {
        // Audio capture remains available with the default part settings.
      }
      if (_closed) return;
      late final NextLivePreview preview;
      final journal = _journal = LocalAudioJournal(
        directory: Directory('${documents.path}/outbox/${library.audioOwnerId}'),
        groupSilence: () => library.conversationGroups ? _groupSilence.value : null,
        onConversationBoundary: (id, sample) {
          if (!_closed) preview.confirmConversationBoundary(id, sample);
        },
        upload: (body, id) async {
          if (_closed) throw LocalDeliveryIssue.pairing;
          try {
            return await library.uploadPart(body, id);
          } on LibraryFailure catch (error) {
            throw switch (error) {
              LibraryFailure.address || LibraryFailure.key => LocalDeliveryIssue.pairing,
              LibraryFailure.malformed => LocalDeliveryIssue.receipt,
              LibraryFailure.unavailable || LibraryFailure.storage => LocalDeliveryIssue.server,
            };
          }
        },
      );
      preview = NextLivePreview(
        library.audioOwnerId,
        library.connectPreview,
        onReconnect: () {
          if (!_closed) unawaited(journal.recoverConnection());
        },
      );
      bool retainedArchive;
      try {
        await journal.initialize();
        retainedArchive = !await Cv1Archive(journal, library.audioOwnerId).recover();
      } catch (_) {
        preview.dispose();
        rethrow;
      }
      if (_closed) {
        preview.dispose();
        return;
      }
      journal.addListener(_deliveryChanged);
      WidgetsBinding.instance.addObserver(journal);
      _inputs = NextCaptureInputs(
        NextPhoneCapture(
          journal,
          library.audioOwnerId,
          FlutterPhoneMicrophone(),
          preview: preview,
          keepListeningAfterSilence: () => !_closed && _keepListening.value,
        ),
        _hasCv1 ? ChannelCv1Transport() : const UnavailableCv1Transport(),
        ownerChange: library.ownerChange,
        doubleTapAction: () => _doubleTap,
        resumeSettings: _groupPrefs == null ? null : Cv1ResumeSettings(_groupPrefs!, library.audioOwnerId),
        diagnosticsHistory: Cv1History(preferences: _groupPrefs),
      );
      if (retainedArchive) _inputs!.archiveMessage = 'nextImportRetained';
      widget.onInputsReady?.call(_inputs!);
      if (_hasCv1) _diagnosticPoll = Timer.periodic(const Duration(minutes: 1), (_) => _sampleIdleLink());
      journal.retry();
    } catch (_) {
      _storageFailed = true;
    }
    if (!_closed) setState(() {});
  }

  void _deliveryChanged() {
    final revision = _journal!.deliveryRevision;
    if (_closed || revision == _deliveryRevision) return;
    _deliveryRevision = revision;
    widget.onDelivered?.call();
  }

  void _sampleIdleLink() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final inputs = _inputs;
    if (_closed || inputs == null || (lifecycle != null && lifecycle != AppLifecycleState.resumed)) return;
    unawaited(inputs.connection.sampleSignal());
    if (!inputs.hasCaptureInProgress) unawaited(inputs.connection.sampleDiagnostics());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _inputs?.phone.rearmWatchdog();
      _inputs?.cv1.rearmSilenceDeadline();
      _sampleIdleLink();
    } else {
      unawaited(_inputs?.connection.history.flush());
    }
  }

  @override
  void dispose() {
    _closed = true;
    _diagnosticPoll?.cancel();
    _groupSilence.dispose();
    _keepListening.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.library.ownerChange.detachCapture(_captureBusy);
    _previousRelease = _release();
    PairedLibrary.trackAudioRelease(widget.library.audioOwnerId, _previousRelease);
    super.dispose();
  }

  Future<void> _release() async {
    await _setup;
    final journal = _journal;
    if (journal == null) return;
    journal.removeListener(_deliveryChanged);
    WidgetsBinding.instance.removeObserver(journal);
    try {
      await _inputs?.close();
      await journal.drain();
    } finally {
      _inputs?.dispose();
      journal.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.library.audioDelivery) return const SizedBox.shrink();
    final l = context.l10n;
    final inputs = _inputs;
    if (inputs == null) {
      return _storageFailed ? Text(l.couldNotStartRecording) : const SizedBox.shrink();
    }
    return _controls(inputs);
  }

  void openSettings() {
    final inputs = _inputs;
    if (inputs != null) _controls(inputs).openSettings(context, widget.library);
  }

  LocalNextCaptureControls _controls(NextCaptureInputs inputs) => LocalNextCaptureControls(
    inputs: inputs,
    serverLabel: widget.serverName,
    hasCv1: _hasCv1,
    openServers: widget.openServers,
    library: widget.library,
    groupSilence: _groupSilence,
    onGroupSilence: _groupPrefs == null ? null : _setGroupSilence,
    keepListening: _keepListening,
    onKeepListening: _groupPrefs == null ? null : _setKeepListening,
    doubleTap: _doubleTap,
    onDoubleTap: _groupPrefs == null ? null : _setDoubleTap,
  );

  Future<bool> _setDoubleTap(Cv1DoubleTapAction action) async {
    final prefs = _groupPrefs;
    if (prefs == null || _captureBusy()) return false;
    try {
      if (await prefs.setString(_doubleTapKey, action.name) && mounted) {
        setState(() => _doubleTap = action);
        return true;
      }
    } catch (_) {
      // Keep the last confirmed gesture if the preference cannot be saved.
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.failedToSaveCheckConnection)));
    }
    return false;
  }

  Future<bool> _setGroupSilence(int? seconds) async {
    final prefs = _groupPrefs;
    if (prefs == null || _closed || !widget.library.ownerChange.permitsCapture) return false;
    try {
      final saved = seconds == null ? await prefs.remove(_groupPrefKey) : await prefs.setInt(_groupPrefKey, seconds);
      if (saved && mounted) {
        _groupSilence.value = seconds;
        return true;
      }
    } catch (_) {
      // Report failure without changing the setting for the next recording.
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.couldNotLoadPage)));
    }
    return false;
  }

  Future<void> _setKeepListening(bool value) async {
    final prefs = _groupPrefs;
    if (prefs == null || _closed || !widget.library.ownerChange.permitsCapture) return;
    try {
      if (await prefs.setBool(_keepListeningKey, value) && mounted) {
        _keepListening.value = value;
        return;
      }
    } catch (_) {
      // Keep the last confirmed value if the preference cannot be saved.
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.failedToSaveCheckConnection)));
    }
  }
}

/// Both inputs share one journal. Only an explicit Start can take it from the other source.
class NextCaptureInputs extends ChangeNotifier {
  NextCaptureInputs(
    this.phone,
    Cv1Transport transport, {
    this.ownerChange,
    Cv1DoubleTapAction Function()? doubleTapAction,
    Cv1ResumeSettings? resumeSettings,
    Cv1History? diagnosticsHistory,
  }) {
    cv1 = NextCv1Capture(
      phone.journal,
      phone.owner,
      canStart: () => permitsNewRecording && !switching && !_phoneOwns && !phone.active && !phone.busy,
      permitsStartRequest: () => permitsNewRecording,
      onStartRequested: _claimCv1,
      doubleTapAction: doubleTapAction,
      resumeSettings: resumeSettings,
      preview: phone.preview,
      keepListeningAfterSilence: phone.keepListeningAfterSilence,
    );
    connection = Cv1Connection(transport, cv1, history: diagnosticsHistory);
  }

  final NextPhoneCapture phone;
  final NextOwnerChangeGate? ownerChange;
  late final NextCv1Capture cv1;
  late final Cv1Connection connection;
  bool _phoneOwns = false;
  bool _closed = false;
  Future<void>? _transition;
  bool get switching => _transition != null;
  bool get isRecording => phone.active || phone.busy || cv1.active;
  bool get hasCaptureInProgress => switching || isRecording || cv1.sealing || connection.calibrating;
  bool get permitsNewRecording => !_closed && !connection.calibrating && (ownerChange?.permitsCapture ?? true);
  NextLivePreview? get preview => phone.preview;

  Future<void> _change(Future<void> Function() operation) {
    if (_closed || switching) return Future.value();
    final pending = _transition = Future<void>.microtask(operation).whenComplete(() {
      _transition = null;
      if (!_closed) notifyListeners();
    });
    notifyListeners();
    return pending;
  }

  String? archiveMessage;
  Duration? importedAudio;
  ({DateTime first, DateTime last})? importedTimes;
  final _importClock = Stopwatch();
  Cv1SyncProgress? _syncProgress;

  bool get finishingImport => _syncProgress?.remainingRecords == 0;
  ({double bytesPerSecond, Duration remaining})? get transferEstimate => _syncProgress?.estimate(_importClock.elapsed);
  bool get hasRetainedArchive => archiveMessage == 'nextImportRetained';

  Future<void> retryStagedArchive() async {
    if (hasCaptureInProgress || !permitsNewRecording) return;
    await _change(() async {
      importedTimes = null;
      importedAudio = null;
      final saved = await Cv1Archive(phone.journal, phone.owner).recover();
      archiveMessage = saved ? 'nextImportSaved' : 'nextImportRetained';
    });
  }

  int importWindows = 0;
  int importedRecords = 0;
  int importMissingRecords = 0;
  bool stoppingImport = false;

  void stopImport() {
    if (importWindows == 0 || stoppingImport) return;
    stoppingImport = true;
    notifyListeners();
  }

  Future<void> importOldest(Cv1StorageTarget target, {required int? windows}) async {
    if (hasCaptureInProgress || !permitsNewRecording || connection.importTarget != target) return;
    final codec = connection.codec!;
    final journal = phone.journal;
    final storage = connection.diagnostics!.storageInfo!;
    final unread = storage.unreadPackets;
    final possibleWindows = (unread / Cv1Archive.maxRecords).ceil().clamp(1, Cv1Archive.maxWindows);
    final limit = windows?.clamp(1, possibleWindows);
    final chunkWindows = limit ?? Cv1Archive.maxWindows;
    await _change(() async {
      importedTimes = null;
      importedAudio = null;
      importMissingRecords = 0;
      final archive = Cv1Archive(journal, phone.owner);
      if (archive.staged.isNotEmpty) {
        archiveMessage = 'nextImportRetained';
        return;
      }
      // Reserve space for one bounded raw chunk and its outbox envelope.
      bool hasSpace(int count) => journal.pendingBytes + count * 65536 <= journal.maxStorageBytes;
      if (!hasSpace(limit ?? 1)) {
        archiveMessage = 'nextImportCapacity';
        return;
      }
      archiveMessage = 'nextImportProgress';
      importWindows = chunkWindows;
      final importingAll = limit == null;
      _importClock
        ..reset()
        ..start();
      importedRecords = 0;
      var verifiedEnd = storage.oldest;
      var windowsInChunk = 0;
      stoppingImport = false;
      if (!_closed) notifyListeners();
      final refresh = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_closed) notifyListeners();
      });
      try {
        await connection.readArchive(
          target,
          windows: limit,
          shouldStop: () => stoppingImport || _closed,
          onRange: (start, end) {
            verifiedEnd = start;
            _syncProgress = Cv1SyncProgress(start: start, end: end, elapsed: _importClock.elapsed);
          },
          beforeRead: () {
            if (importingAll && !hasSpace(windowsInChunk + 1)) {
              throw PlatformException(code: 'phone_full');
            }
          },
          onReconnectWait: () async {
            await archive.finish();
            windowsInChunk = 0;
            archiveMessage = 'nextImportReconnecting';
            if (!_closed) notifyListeners();
          },
          onReconnect: (missing) {
            importMissingRecords += missing;
            verifiedEnd += missing;
            _syncProgress?.resume(missing, _importClock.elapsed);
            archiveMessage = 'nextImportProgress';
            if (!_closed) notifyListeners();
          },
          persist: (batch) async {
            if (batch.bytes.isNotEmpty) {
              final previousRecords = archive.records;
              final micros = await archive.append(
                batch.bytes,
                target.deviceId,
                batch.start,
                codec,
                verifyThrough: verifiedEnd,
              );
              final end = batch.start + batch.bytes.length ~/ RingProtocol.recordSize;
              if (end > verifiedEnd) verifiedEnd = end;
              importedRecords += archive.records - previousRecords;
              importedAudio = (importedAudio ?? Duration.zero) + Duration(microseconds: micros);
              importedTimes = archive.savedTimes;
              _syncProgress?.savedThrough(verifiedEnd, _importClock.elapsed);
              if (batch.complete) windowsInChunk++;
              if (importingAll && windowsInChunk == chunkWindows) {
                await archive.finish();
                windowsInChunk = 0;
              }
              if (!_closed) notifyListeners();
            }
            if (!importingAll && (!batch.complete || batch.bytes.isEmpty)) {
              archiveMessage = importedRecords > 0 ? 'nextImportPartial' : 'nextImportInterrupted';
            }
          },
        );
        if (archiveMessage == 'nextImportProgress' || archiveMessage == 'nextImportReconnecting') {
          if (stoppingImport) {
            archiveMessage = 'nextImportStopped';
          } else {
            archiveMessage = importedRecords == 0
                ? 'nextImportAlreadySaved'
                : importingAll
                ? 'nextImportAllSaved'
                : 'nextImportSaved';
          }
        }
      } on PlatformException catch (error) {
        archiveMessage = switch (error.code) {
          'cursor_changed' => 'nextImportMoved',
          'storage_busy' => 'nextImportBusy',
          'phone_full' => 'nextImportCapacity',
          _ => importedRecords > 0 ? 'nextImportPartial' : 'nextImportInterrupted',
        };
      } catch (_) {
        archiveMessage = 'nextImportFailed';
      } finally {
        try {
          if (archive.records > 0) await archive.finish();
        } catch (_) {
          archiveMessage = 'nextImportFailed';
        }
        if (archive.staged.isNotEmpty) archiveMessage = 'nextImportRetained';
        refresh.cancel();
        _importClock.stop();
        _syncProgress = null;
        importWindows = 0;
        stoppingImport = false;
      }
    });
  }

  Future<void> _claimCv1() {
    if (!permitsNewRecording) return Future<void>.value();
    return _change(() async {
      if (!cv1.linked || !cv1.codecSupported) return;
      final needsSeal = phone.active || phone.busy;
      if (needsSeal) await phone.stop();
      if (_closed || (needsSeal && phone.problem == CaptureProblem.storage)) return;
      _phoneOwns = false;
    });
  }

  Future<void> startCv1() async {
    if (!permitsNewRecording || switching || !cv1.linked || !cv1.codecSupported) return;
    final generation = cv1.generation;
    await _claimCv1();
    if (!_closed && !_phoneOwns && cv1.generation == generation && cv1.codecSupported) cv1.start();
  }

  Future<void> togglePhone() {
    if (!phone.active && !permitsNewRecording) return Future<void>.value();
    return _change(() async {
      _phoneOwns = true;
      if (phone.active) {
        await phone.stop();
        return;
      }
      final needsSeal = cv1.active;
      await cv1.stop();
      if (!permitsNewRecording || (needsSeal && cv1.problem == Cv1CaptureProblem.storage)) return;
      await phone.start();
    });
  }

  Future<void> stopRecording() async {
    await _transition;
    await _change(() async {
      if (phone.active || phone.busy) {
        await phone.stop();
      } else {
        await cv1.stop();
      }
    });
  }

  Future<void> close() async {
    _closed = true;
    try {
      await _transition;
    } finally {
      // Fence BLE delivery and both capture paths immediately, then wait for every seal.
      await Future.wait([connection.close(), cv1.close(), phone.stop()]);
    }
  }

  @override
  void dispose() {
    connection.dispose();
    cv1.dispose();
    phone.dispose();
    preview?.dispose();
    super.dispose();
  }
}

enum _Cv1ImportScope { fragment, series, all }

class LocalNextCaptureControls extends StatelessWidget {
  const LocalNextCaptureControls({
    required this.inputs,
    this.serverLabel = '',
    this.hasCv1 = true,
    this.library,
    this.groupSilence,
    this.onGroupSilence,
    this.keepListening,
    this.onKeepListening,
    this.doubleTap = Cv1DoubleTapAction.checkpoint,
    this.onDoubleTap,
    this.openServers,
    super.key,
  });
  final NextCaptureInputs inputs;
  final String serverLabel;
  final bool hasCv1;
  final PairedLibrary? library;
  final ValueListenable<int?>? groupSilence;
  final Future<bool> Function(int?)? onGroupSilence;
  final ValueListenable<bool>? keepListening;
  final Future<void> Function(bool)? onKeepListening;
  final Cv1DoubleTapAction doubleTap;
  final Future<bool> Function(Cv1DoubleTapAction)? onDoubleTap;
  final VoidCallback? openServers;

  Widget _boundaries(PairedLibrary paired) => _ConversationBoundaryTile(
    seconds: groupSilence!,
    paired: paired,
    save: onGroupSilence!,
    keepListening: keepListening,
    saveKeepListening: onKeepListening,
  );

  Widget? _time(BuildContext context) {
    final phone = inputs.phone;
    final started = phone.active ? phone.startedAt : inputs.cv1.startedAt;
    if (started == null) return null;
    return _ActiveRecordingTime(
      started: started,
      input: phone.active ? context.l10n.phone : 'CV1',
      clock: phone.journal.clock,
    );
  }

  Widget _finish(BuildContext context) => TextButton.icon(
    key: const ValueKey('next-cv1-finish'),
    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
    icon: const Icon(Icons.skip_next),
    label: Text(pairedSettingsLabel(context, 'nextFinishShort'), maxLines: 1, overflow: TextOverflow.ellipsis),
    onPressed: inputs.switching || !inputs.cv1.canFinish ? null : inputs.cv1.finishConversation,
  );

  Widget _mute(BuildContext context) {
    final muted = inputs.cv1.intent == Cv1CaptureIntent.muted;
    final l = context.l10n;
    return IconButton(
      tooltip: muted ? l.unmute : l.mute,
      icon: Icon(muted ? Icons.mic_off : Icons.mic),
      onPressed: inputs.switching ? null : inputs.cv1.toggleMute,
    );
  }

  String? _inputNotice(BuildContext context) {
    if (inputs.phone.active) return phoneMicNotice(context, inputs.phone);
    final cv1 = inputs.cv1;
    if (!cv1.wantsAudio || cv1.problem != null || inputs.connection.audioFailed) return null;
    if (!cv1.hasPersistedAudio) return pairedSettingsLabel(context, 'nextCv1WaitingForAudio');
    if (cv1.audioPaused) return pairedSettingsLabel(context, 'nextCv1AudioGap');
    return null;
  }

  Widget _liveControls(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      Flexible(
        child: Tooltip(message: pairedSettingsLabel(context, 'nextFinishContinue'), child: _finish(context)),
      ),
      _mute(context),
    ],
  );

  Future<void> _importPendant(BuildContext context, Cv1Connection link) async {
    final target = link.importTarget;
    if (target == null) return;
    String label(String key) => pairedSettingsLabel(context, key);
    final scope = await showDialog<_Cv1ImportScope>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(label('nextImportAction')),
        content: Text('CV1 · ${_shortCv1Id(target.deviceId)}\n\n${label('nextImportHint')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: Text(context.l10n.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(dialog, _Cv1ImportScope.fragment),
            child: Text(label('nextImportConfirm')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, _Cv1ImportScope.series),
            child: Text(label('nextImportSeries')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, _Cv1ImportScope.all),
            child: Text(label('nextImportAll')),
          ),
        ],
      ),
    );
    if (scope == null || !context.mounted) return;
    await inputs.importOldest(
      target,
      windows: switch (scope) {
        _Cv1ImportScope.fragment => 1,
        _Cv1ImportScope.series => Cv1Archive.maxWindows,
        _Cv1ImportScope.all => null,
      },
    );
  }

  Future<void> _clearPendant(BuildContext context, Cv1Connection link) async {
    final target = link.storageTarget;
    final bytes = link.diagnostics?.storage?.unreadBytes;
    if (target == null || bytes == null || inputs.hasCaptureInProgress) return;
    String label(String key) => pairedSettingsLabel(context, key);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(label('nextPendantClearTitle')),
        content: Text(
          'CV1 · ${_shortCv1Id(target.deviceId)} · ${_storageSize(bytes)}\n\n${label('nextPendantClearHint')}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.cancel)),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(dialog).colorScheme.error),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(label('nextPendantClearConfirm')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final outcome = inputs.hasCaptureInProgress ? Cv1ClearResult.unavailable : await link.clearStorage(target);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          label(switch (outcome) {
            Cv1ClearResult.empty => 'nextPendantCleared',
            Cv1ClearResult.unavailable => 'nextPendantClearUnavailable',
            Cv1ClearResult.unconfirmed => 'nextPendantClearUnknown',
          }),
        ),
      ),
    );
  }

  void openSettings(BuildContext context, PairedLibrary library) {
    if (!inputs.hasCaptureInProgress) unawaited(inputs.connection.sampleDiagnostics());
    final capture = Listenable.merge([inputs, inputs.phone, inputs.cv1, inputs.ownerChange]);
    var gesture = doubleTap;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) {
          final l = context.l10n;
          final journal = inputs.phone.journal;
          final link = inputs.connection;
          String gestureLabel(Cv1DoubleTapAction value) => switch (value) {
            Cv1DoubleTapAction.checkpoint => pairedSettingsLabel(context, 'nextCheckpoint'),
            Cv1DoubleTapAction.stop => l.endAndProcess,
            Cv1DoubleTapAction.mute => l.deviceOnboardingMuteUnmute,
            Cv1DoubleTapAction.off => l.off,
          };
          void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
          return Scaffold(
            appBar: AppBar(title: Text(pairedSettingsLabel(context, 'nextMobileSettings'))),
            body: StatefulBuilder(
              builder: (context, refresh) => ListenableBuilder(
                listenable: Listenable.merge([capture, link, journal]),
                builder: (context, _) => ListView(
                  children: [
                    if (hasCv1) ...[
                      ListTile(
                        leading: cv1DeviceIcon(link),
                        title: const Text('Omi CV1'),
                        subtitle: Text(cv1DeviceStatus(context, link)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: link.importingStorage
                            ? null
                            : () {
                                unawaited(showNextDevices(context, inputs, library: library));
                              },
                      ),
                      ListTile(
                        leading: Icon(Icons.monitor_heart_outlined, color: NextAccent.teal.of(context)),
                        title: Text(l.deviceDiagnostics),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openDiagnostics(context, inputs, library: library),
                      ),
                      if (inputs.cv1.resumeSettings case final resume?)
                        SwitchListTile(
                          title: Text(pairedSettingsLabel(context, 'nextAutoListen')),
                          subtitle: Text(pairedSettingsLabel(context, 'nextAutoListenHint')),
                          value: resume.enabled,
                          onChanged: inputs.hasCaptureInProgress
                              ? null
                              : (value) async {
                                  final saved = await resume.save(value ? Cv1ResumeMode.armed : Cv1ResumeMode.off);
                                  if (!context.mounted) return;
                                  refresh(() {});
                                  if (!saved) {
                                    ScaffoldMessenger.of(
                                      context,
                                    ).showSnackBar(SnackBar(content: Text(l.failedToSaveCheckConnection)));
                                  }
                                },
                        ),
                      if (onDoubleTap != null)
                        ListTile(
                          leading: Icon(Icons.touch_app_outlined, color: NextAccent.teal.of(context)),
                          title: Text(l.doubleTap),
                          subtitle: Text(gestureLabel(gesture)),
                          trailing: PopupMenuButton<Cv1DoubleTapAction>(
                            tooltip: l.edit,
                            enabled: !inputs.hasCaptureInProgress,
                            initialValue: gesture,
                            onSelected: (action) async {
                              final saved = await onDoubleTap!(action);
                              if (saved && context.mounted) refresh(() => gesture = action);
                            },
                            itemBuilder: (context) => [
                              for (final action in Cv1DoubleTapAction.values)
                                PopupMenuItem(value: action, child: Text(gestureLabel(action))),
                            ],
                          ),
                        ),
                    ],
                    ListTile(
                      leading: Icon(Icons.mic_none, color: NextAccent.blue.of(context)),
                      title: Text(l.recording),
                      subtitle: Text(
                        inputs.phone.active
                            ? l.phone
                            : inputs.cv1.active
                            ? 'Omi CV1'
                            : l.off,
                      ),
                    ),
                    if (hasCv1)
                      _PendantStorageTile(
                        diagnostics: link.diagnostics,
                        onRefresh:
                            link.phase == Cv1LinkPhase.ready && !inputs.hasCaptureInProgress && !link.clearingStorage
                            ? link.sampleDiagnostics
                            : null,
                      ),
                    if (hasCv1)
                      ListTile(
                        leading: Icon(Icons.download_outlined, color: NextAccent.teal.of(context)),
                        title: Text(
                          pairedSettingsLabel(
                            context,
                            inputs.hasRetainedArchive ? 'nextImportRetry' : 'nextImportAction',
                          ),
                        ),
                        subtitle: _cv1ImportSubtitle(context, inputs),
                        trailing: inputs.importWindows > 1
                            ? TextButton(
                                onPressed: inputs.stoppingImport ? null : inputs.stopImport,
                                child: Text(
                                  pairedSettingsLabel(
                                    context,
                                    inputs.stoppingImport ? 'nextImportStopping' : 'nextImportStop',
                                  ),
                                ),
                              )
                            : null,
                        enabled:
                            inputs.importWindows > 1 ||
                            (!inputs.hasCaptureInProgress && (inputs.hasRetainedArchive || link.importTarget != null)),
                        onTap: inputs.importWindows > 0
                            ? null
                            : inputs.hasRetainedArchive
                            ? inputs.retryStagedArchive
                            : () => _importPendant(context, link),
                      ),
                    if (hasCv1)
                      ListTile(
                        leading: const Icon(Icons.delete_outline),
                        title: Text(pairedSettingsLabel(context, 'nextPendantClearAction')),
                        enabled: !inputs.hasCaptureInProgress && link.storageTarget != null && !link.clearingStorage,
                        trailing: link.clearingStorage
                            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : null,
                        onTap: () => _clearPendant(context, link),
                      ),
                    ListTile(
                      leading: Icon(Icons.cloud_upload_outlined, color: NextAccent.amber.of(context)),
                      title: Text(pairedSettingsLabel(context, 'nextPhoneOutbox')),
                      subtitle: Text(
                        [
                          if (journal.pendingParts > 0)
                            "${pairedSettingsLabel(context, 'nextAudioOnPhone')} · ${journal.pendingParts} · ${_storageSize(journal.pendingBytes)}"
                          else if (!journal.deliveryFailed)
                            pairedSettingsLabel(context, 'nextOutboxHealthy'),
                          ..._deliveryReasons(context, journal),
                        ].join('\n'),
                      ),
                      trailing: journal.deliveryFailed
                          ? TextButton(onPressed: journal.retry, child: Text(l.retry))
                          : null,
                    ),
                    if (library.conversationGroups && groupSilence != null && onGroupSilence != null)
                      _boundaries(library),
                    const Divider(),
                    ListTile(
                      leading: Icon(Icons.dns_outlined, color: NextAccent.slate.of(context)),
                      title: Text(pairedSettingsLabel(context, 'localMacServers')),
                      subtitle: Text(serverLabel),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: openServers,
                    ),
                    ListTile(
                      leading: Icon(Icons.health_and_safety_outlined, color: NextAccent.teal.of(context)),
                      title: Text(pairedSettingsLabel(context, 'serverStatus')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => open(NextServerStatusPage(library: library, serverName: serverLabel)),
                    ),
                    ListTile(
                      leading: const Icon(Icons.tune),
                      title: Text(l.processing),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => open(
                        LocalNextProcessingPage(
                          client: library.processingClient(
                            permitsActivation: () => !inputs.hasCaptureInProgress && library.ownerChange.permitsCapture,
                          ),
                          serverLabel: serverLabel,
                          capture: capture,
                          isRecording: () => inputs.hasCaptureInProgress,
                        ),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.groups_outlined),
                      title: Text(pairedSettingsLabel(context, 'liveSpeakerLimit')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => showModalBottomSheet<void>(
                        context: context,
                        builder: (_) => NextLiveTuningSheet(library: library),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _recordingActions(BuildContext context) {
    final l = context.l10n;
    final capture = inputs.phone;
    final cv1 = inputs.cv1;
    ButtonStyle sourceStyle(NextAccent accent) => OutlinedButton.styleFrom(
      foregroundColor: accent.of(context),
      backgroundColor: accent.tint(context),
      disabledBackgroundColor: Colors.transparent,
      side: WidgetStateBorderSide.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.disabled)
              ? Theme.of(context).disabledColor
              : accent.of(context).withValues(alpha: .52),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      minimumSize: const Size(48, 38),
    );
    final buttons = [
      OutlinedButton.icon(
        key: const ValueKey('next-phone-capture'),
        style: sourceStyle(capture.active ? NextAccent.red : NextAccent.blue),
        onPressed: inputs.switching || capture.busy || (!capture.active && !inputs.permitsNewRecording)
            ? null
            : inputs.togglePhone,
        icon: Icon(capture.active ? Icons.stop : Icons.mic, size: 18),
        label: Text(
          capture.active ? '${l.stop} · ${l.phone}' : pairedSettingsLabel(context, 'nextRecordPhone'),
          textAlign: TextAlign.center,
        ),
      ),
      if (cv1.linked || cv1.active)
        OutlinedButton.icon(
          key: const ValueKey('next-cv1-capture'),
          style: sourceStyle(cv1.active ? NextAccent.red : NextAccent.teal),
          onPressed: inputs.switching || (!cv1.active && (!cv1.codecSupported || !inputs.permitsNewRecording))
              ? null
              : cv1.active
              ? cv1.stop
              : inputs.startCv1,
          icon: Icon(cv1.active ? Icons.stop : Icons.fiber_manual_record, size: 18),
          label: Text(cv1.active ? '${l.stop} · CV1' : '${l.recordWith} CV1', textAlign: TextAlign.center),
        ),
    ];
    final journal = capture.journal;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        spacing: 8,
        children: [
          for (final button in buttons) Expanded(child: button),
          if (journal.deliveryFailed)
            IconButton(
              key: const ValueKey('next-delivery-warning'),
              tooltip: pairedSettingsLabel(context, 'nextDeliveryProblem'),
              icon: Icon(Icons.sync_problem_outlined, color: NextAccent.red.of(context)),
              onPressed: () => _showDeliveryIssue(context, journal),
            ),
        ],
      ),
    );
  }

  Iterable<String> _deliveryReasons(BuildContext context, LocalAudioJournal journal) =>
      journal.deliveryIssues.map((issue) => pairedSettingsLabel(context, 'nextDelivery_${issue.name}'));

  Future<void> _showDeliveryIssue(BuildContext context, LocalAudioJournal journal) => showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: journal,
      builder: (context, _) => AlertDialog(
        title: Text(pairedSettingsLabel(context, 'nextPhoneOutbox')),
        scrollable: true,
        content: Text(
          [
            if (journal.pendingParts > 0)
              "${pairedSettingsLabel(context, 'nextAudioOnPhone')} · ${journal.pendingParts}",
            ..._deliveryReasons(context, journal),
            pairedSettingsLabel(context, 'nextAudioOnPhoneHint'),
          ].join('\n\n'),
        ),
        actions: [
          if (journal.deliveryFailed) TextButton(onPressed: journal.retry, child: Text(context.l10n.retry)),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l10n.ok)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final capture = inputs.phone;
    final cv1 = inputs.cv1;
    final link = inputs.connection;
    final captureState = Listenable.merge([inputs, capture, cv1, link, inputs.ownerChange]);
    final journal = capture.journal;
    final l = context.l10n;
    return ListenableBuilder(
      listenable: Listenable.merge([captureState, journal]),
      builder: (context, _) => Column(
        children: [
          _recordingActions(context),
          if (cv1.problem != null)
            Text(switch (cv1.problem!) {
              Cv1CaptureProblem.unsupportedCodec => l.captureRecordingError(l.audioFormatLabel),
              Cv1CaptureProblem.storage => l.captureRecordingError(l.capturePhoneStorageFull),
              Cv1CaptureProblem.sourceSwitch => l.couldNotStartRecording,
              Cv1CaptureProblem.preference => l.failedToSaveCheckConnection,
            })
          else if (link.audioFailed)
            Text(l.captureRecordingError(l.bluetooth)),
          if (capture.problem != null)
            Text(switch (capture.problem!) {
              CaptureProblem.permission => l.onboardingMicrophoneRequired,
              CaptureProblem.microphone => l.captureRecordingError(l.microphone),
              CaptureProblem.storage => l.captureRecordingError(l.capturePhoneStorageFull),
              CaptureProblem.empty => l.onboardingActNoAudioPhone,
              CaptureProblem.micStalled => pairedSettingsLabel(context, 'nextMicStalled'),
            }),
          if (inputs.preview case final preview?)
            LocalNextLiveButton(
              preview: preview,
              capture: captureState,
              cv1: link,
              isRecording: () => inputs.isRecording,
              isMuted: () => cv1.active && cv1.intent == Cv1CaptureIntent.muted,
              onStop: inputs.stopRecording,
              inputNotice: _inputNotice,
              recordingTime: _time,
              hasCaptureControls: () => cv1.active,
              captureControls: _liveControls,
              captureSettings: library?.conversationGroups == true && groupSilence != null && onGroupSilence != null
                  ? (_) => _boundaries(library!)
                  : null,
              silenceThreshold: library?.conversationGroups == true && groupSilence != null
                  ? () => capture.active
                        ? capture.silenceSeconds
                        : cv1.canFinish
                        ? cv1.silenceSeconds
                        : groupSilence!.value
                  : null,
              silencePreference: groupSilence,
              serverLabel: serverLabel,
              library: library,
            )
          else ...[
            if (_time(context) case final time?) time,
            if (_inputNotice(context) case final notice?) Text(notice),
            if (cv1.active) _liveControls(context),
          ],
        ],
      ),
    );
  }
}

class _ConversationBoundaryTile extends StatefulWidget {
  const _ConversationBoundaryTile({
    required this.seconds,
    required this.paired,
    required this.save,
    this.keepListening,
    this.saveKeepListening,
  });

  final ValueListenable<int?> seconds;
  final PairedLibrary paired;
  final Future<bool> Function(int?) save;
  final ValueListenable<bool>? keepListening;
  final Future<void> Function(bool)? saveKeepListening;

  @override
  State<_ConversationBoundaryTile> createState() => _ConversationBoundaryTileState();
}

class _ConversationBoundaryTileState extends State<_ConversationBoundaryTile> {
  bool _saving = false;

  String _label(int? seconds) => switch (seconds) {
    null => pairedSettingsLabel(context, 'groupCaptureLegacy'),
    0 => pairedSettingsLabel(context, 'groupCaptureSingle'),
    _ => '${seconds}s',
  };

  Future<void> _save(int value) async {
    if (_saving || !widget.paired.ownerChange.permitsCapture) return;
    setState(() => _saving = true);
    final selected = value == -1 ? null : value;
    try {
      await widget.save(selected);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.paired.ownerChange, widget.seconds, widget.keepListening]),
    builder: (context, _) => Column(
      children: [
        PopupMenuButton<int>(
          key: const ValueKey('next-recording-boundaries'),
          tooltip: pairedSettingsLabel(context, 'groupCaptureLabel'),
          enabled: !_saving && widget.paired.ownerChange.permitsCapture,
          initialValue: widget.seconds.value ?? -1,
          onSelected: _save,
          itemBuilder: (context) => [
            for (final value in [-1, ...LocalAudioJournal.groupSilenceChoices])
              PopupMenuItem(value: value, child: Text(_label(value == -1 ? null : value))),
          ],
          child: ListTile(
            leading: Icon(Icons.call_split, color: NextAccent.coral.of(context)),
            title: Text(pairedSettingsLabel(context, 'groupCaptureLabel')),
            subtitle: Text(
              '${_label(widget.seconds.value)}\n${pairedSettingsLabel(context, 'nextBoundaryAppliesLater')}',
            ),
            trailing: const Icon(Icons.arrow_drop_down),
          ),
        ),
        if ((widget.seconds.value ?? 0) > 0 && widget.keepListening != null && widget.saveKeepListening != null)
          SwitchListTile(
            title: Text(pairedSettingsLabel(context, 'nextKeepListeningAfterSilence')),
            value: widget.keepListening!.value,
            onChanged: _saving || !widget.paired.ownerChange.permitsCapture
                ? null
                : (value) async {
                    setState(() => _saving = true);
                    try {
                      await widget.saveKeepListening!(value);
                    } finally {
                      if (mounted) setState(() => _saving = false);
                    }
                  },
          ),
      ],
    ),
  );
}

Widget? _cv1ImportSubtitle(BuildContext context, NextCaptureInputs inputs) {
  final message = inputs.archiveMessage;
  if (message == null) return null;
  String label(String key) => pairedSettingsLabel(context, key);

  String status = label(message);
  if (inputs.stoppingImport) {
    status = label('nextImportStopping');
  } else if (message == 'nextImportProgress') {
    if (inputs.finishingImport) {
      status = label('nextImportFinalizing');
    } else if (inputs.transferEstimate case final estimate?) {
      final seconds = estimate.remaining.inSeconds;
      final l = context.l10n;
      final time = seconds < 60
          ? l.timeCompactSecs(seconds)
          : seconds < 3600
          ? l.timeCompactMinsAndSecs(seconds ~/ 60, seconds % 60)
          : l.timeCompactHoursAndMins(seconds ~/ 3600, seconds ~/ 60 % 60);
      status = '${_storageSize(estimate.bytesPerSecond.round())}/s · ${l.estimatedTimeRemaining(time)}';
    }
  }

  String? savedPeriod;
  if (inputs.importedTimes case final times?) {
    final start = times.first.toLocal();
    final end = times.last.toLocal();
    final locale = Localizations.localeOf(context).toString();
    final full = DateFormat.yMMMd(locale).add_jms();
    final endFormat = DateUtils.isSameDay(start, end) ? DateFormat.jms(locale) : full;
    final range = start == end ? full.format(start) : '${full.format(start)} – ${endFormat.format(end)}';
    savedPeriod = "${label('nextImportSavedPeriod')} · $range";
  }

  return Text(
    [
      status,
      if (savedPeriod != null) savedPeriod,
      if (inputs.importWindows == 0)
        if (inputs.importedAudio case final duration?)
          '${context.l10n.durationLabel} · ${(duration.inMilliseconds / 1000).toStringAsFixed(2)} s',
      if (inputs.importMissingRecords > 0) '${label('nextImportMissingRecords')} ${inputs.importMissingRecords}',
    ].join('\n'),
  );
}

String? phoneMicNotice(BuildContext context, NextPhoneCapture capture) => switch (capture.micStatus) {
  PhoneMicStatus.waiting => context.l10n.waitingForData,
  PhoneMicStatus.interrupted => pairedSettingsLabel(context, 'nextMicInterrupted'),
  PhoneMicStatus.recovering => pairedSettingsLabel(context, 'nextMicRecovering'),
  _ => capture.problem == CaptureProblem.micStalled ? pairedSettingsLabel(context, 'nextMicStalled') : null,
};

class _ActiveRecordingTime extends StatefulWidget {
  const _ActiveRecordingTime({required this.started, required this.input, required this.clock});
  final DateTime started;
  final String input;
  final DateTime Function() clock;

  @override
  State<_ActiveRecordingTime> createState() => _ActiveRecordingTimeState();
}

class _ActiveRecordingTimeState extends State<_ActiveRecordingTime> {
  late final Timer _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = widget.clock().difference(widget.started);
    final seconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
    final time = [
      if (seconds >= 3600) seconds ~/ 3600,
      seconds ~/ 60 % 60,
      seconds % 60,
    ].map((v) => v.toString().padLeft(2, '0')).join(':');
    return Text(
      '${widget.input} · $time',
      key: const ValueKey('next-recording-time'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.end,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: OmiColors.textPrimary,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

String _shortCv1Id(String id) {
  // Android MAC addresses commonly share a vendor prefix. Use the last
  // three octets for these, and Omi's short ID for iOS peripheral UUIDs.
  final octets = id.split(':');
  return BtDevice.shortId(octets.length == 6 ? octets.skip(3).join() : id) as String;
}

class _PendantStorageTile extends StatelessWidget {
  const _PendantStorageTile({required this.diagnostics, required this.onRefresh});

  final Cv1Diagnostics? diagnostics;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    String label(String key) => pairedSettingsLabel(context, key);
    final status = diagnostics?.storage;
    final info = diagnostics?.storageInfo;
    final warning = status != null && (status.almostFull || !status.clockValid);
    final unread = status == null ? '—' : _storageSize(status.unreadBytes);
    return ListTile(
      dense: true,
      leading: Icon(
        warning ? Icons.warning_amber_rounded : Icons.sd_storage_outlined,
        semanticLabel: warning ? label(status.almostFull ? 'nextPendantFull' : 'nextClockUnset') : null,
        color: (warning ? NextAccent.amber : NextAccent.teal).of(context),
      ),
      title: Text(label('nextPendantOutbox')),
      subtitle: Text("${label('nextPendantUnread')}: $unread", maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(tooltip: context.l10n.refresh, icon: const Icon(Icons.refresh), onPressed: onRefresh),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label('nextPendantOutbox'), style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                if (status == null)
                  Text(label('nextPendantUnreadUnknown'))
                else ...[
                  Text("${label('nextPendantUnread')}: $unread"),
                  Text("${label('nextPendantFree')}: ${_storageSize(status.freeBytes)}"),
                  if (status.almostFull)
                    Text(label('nextPendantFull'), style: TextStyle(color: NextAccent.amber.of(context))),
                  const Divider(height: 24),
                  Text(label(status.clockValid ? 'nextClockSet' : 'nextClockUnset')),
                  if (info != null) ...[
                    Text("${label('nextPendantDropped')}: ${info.overwrittenPackets}"),
                    Text(
                      label(switch (info.protocol) {
                        Cv1StorageProtocol.legacy => 'nextPendantLegacy',
                        Cv1StorageProtocol.receiverAcknowledgement => 'nextPendantAck',
                        Cv1StorageProtocol.unconfirmed => 'nextPendantUnconfirmed',
                      }),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(label('nextPendantLastRead'), style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _openDiagnostics(BuildContext context, NextCaptureInputs inputs, {PairedLibrary? library}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => NextDeviceDiagnosticsPage(
        link: inputs.connection,
        capture: Listenable.merge([inputs, inputs.phone, inputs.cv1, inputs.ownerChange]),
        captureBusy: () => inputs.hasCaptureInProgress,
        library: library,
      ),
    ),
  );
}

Future<void> showNextDevices(BuildContext context, NextCaptureInputs inputs, {PairedLibrary? library}) async {
  final connection = inputs.connection;
  if (connection.phase == Cv1LinkPhase.idle) unawaited(connection.scan());
  BuildContext? picker;
  var pairing = false;
  void closeWhenReady() {
    final sheet = picker;
    if (!pairing || connection.phase != Cv1LinkPhase.ready || sheet == null || !sheet.mounted) return;
    pairing = false;
    if (ModalRoute.isCurrentOf(sheet) == true) Navigator.pop(sheet);
  }

  connection.addListener(closeWhenReady);
  bool? openDiagnostics;
  try {
    openDiagnostics = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: ListenableBuilder(
          listenable: connection,
          builder: (context, _) {
            final l = context.l10n;
            picker = context;
            final connecting = connection.phase == Cv1LinkPhase.connecting;
            final selected = connection.phase == Cv1LinkPhase.ready || connection.phase == Cv1LinkPhase.reconnecting;
            final linkedId = connection.linkedDeviceId;
            final scanned = [
              for (final device in connection.devices) (device: device, shortId: _shortCv1Id(device.id)),
            ];
            final shortIdCounts = <String, int>{};
            for (final entry in scanned) {
              shortIdCounts.update(entry.shortId, (count) => count + 1, ifAbsent: () => 1);
            }
            return ListView(
              shrinkWrap: true,
              children: [
                if (selected)
                  ListTile(
                    leading: cv1DeviceIcon(connection),
                    title: Text('Omi CV1 · ${cv1DeviceStatus(context, connection)}'),
                    subtitle: linkedId == null ? null : Text('${l.deviceId} · ${_shortCv1Id(linkedId)}'),
                    trailing: TextButton(
                      onPressed: () async {
                        if (inputs._closed) return;
                        await inputs.cv1.stop();
                        if (inputs._closed) return;
                        await connection.disconnect();
                        if (context.mounted && !connection.operationFailed) Navigator.pop(context);
                      },
                      child: Text(l.forgetDevice),
                    ),
                  )
                else ...[
                  ListTile(
                    leading: const Icon(Icons.bluetooth_searching),
                    title: Text(connecting ? l.deviceConnecting : l.connectDevice),
                    subtitle: connection.phase == Cv1LinkPhase.scanning ? Text(l.searchingForDevices) : null,
                    trailing: TextButton(
                      onPressed: inputs._closed || connecting ? null : connection.scan,
                      child: Text(l.scanAgain),
                    ),
                  ),
                  for (final (device: device, shortId: shortId) in scanned)
                    ListTile(
                      title: Text(device.name.trim().isEmpty ? 'Omi CV1' : device.name),
                      subtitle: Text('${l.deviceId} · ${shortIdCounts[shortId] == 1 ? shortId : device.id}'),
                      leading: const Icon(Icons.bluetooth),
                      onTap: connecting
                          ? null
                          : () {
                              if (inputs._closed) return;
                              pairing = true;
                              unawaited(connection.connect(device.id));
                            },
                    ),
                ],
                if (connection.phase == Cv1LinkPhase.ready)
                  ListTile(
                    leading: const Icon(Icons.graphic_eq),
                    title: Text(pairedSettingsLabel(context, 'gainDiagnosticsShortcut')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pop(context, true),
                  ),
                if (connection.permissionDenied)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(pairedSettingsLabel(context, 'nextCv1ScanPermission')),
                  )
                else if (connection.operationFailed || connection.phase == Cv1LinkPhase.failed)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      connection.linkState?.reason == Cv1LinkReason.timeout && connection.phase == Cv1LinkPhase.failed
                          ? '${cv1DeviceStatus(context, connection)}. ${pairedSettingsLabel(context, 'nextCv1TimeoutHelp')}'
                          : connection.phase == Cv1LinkPhase.failed
                          ? cv1DeviceStatus(context, connection)
                          : l.connectionFailed,
                    ),
                  ),
                if (connection.phase == Cv1LinkPhase.unavailable)
                  Padding(padding: const EdgeInsets.all(16), child: Text(l.bluetoothNeeded)),
              ],
            );
          },
        ),
      ),
    );
  } finally {
    connection.removeListener(closeWhenReady);
  }
  if (openDiagnostics == true && context.mounted && !inputs._closed) {
    _openDiagnostics(context, inputs, library: library);
  }
}
