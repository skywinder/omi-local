import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/services/capture/local_audio_journal.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'capture.dart';
import 'cv1_capture.dart';
import 'cv1_resume.dart';
import 'cv1_transport.dart';
import 'device_diagnostics_page.dart';
import 'live_preview.dart';
import 'live_view.dart';
import 'live_tuning.dart';
import 'paired_library.dart';
import 'processing_page.dart';
import 'server_status_page.dart';
import 'settings_labels.dart';

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
  State<LocalNextCapturePanel> createState() => _CapturePanelState();
}

class _CapturePanelState extends State<LocalNextCapturePanel> with WidgetsBindingObserver {
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
  int? _groupSilence;
  Cv1DoubleTapAction _doubleTap = Cv1DoubleTapAction.checkpoint;
  static const _doubleTapKey = 'next.cv1.doubleTap';
  SharedPreferences? _groupPrefs;
  Timer? _diagnosticPoll;
  String get _groupPrefKey => 'next.capture.groupSilence.${widget.library.audioOwnerId}';

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
        if (LocalAudioJournal.groupSilenceChoices.contains(value)) _groupSilence = value;
        final gesture = _groupPrefs?.getString(_doubleTapKey);
        _doubleTap =
            Cv1DoubleTapAction.values.where((action) => action.name == gesture).firstOrNull ??
            Cv1DoubleTapAction.checkpoint;
      } catch (_) {
        // Audio capture remains available with the default part settings.
      }
      if (_closed) return;
      final journal = _journal = LocalAudioJournal(
        directory: Directory('${documents.path}/outbox/${library.audioOwnerId}'),
        groupSilence: () => library.conversationGroups ? _groupSilence : null,
        upload: (body, id) {
          if (_closed) throw StateError('Pairing closed');
          return library.uploadPart(body, id);
        },
      );
      await journal.initialize();
      if (_closed) return;
      journal.addListener(_deliveryChanged);
      WidgetsBinding.instance.addObserver(journal);
      _inputs = NextCaptureInputs(
        NextPhoneCapture(
          journal,
          library.audioOwnerId,
          FlutterPhoneMicrophone(),
          preview: NextLivePreview(library.audioOwnerId, library.connectPreview),
        ),
        _hasCv1 ? ChannelCv1Transport() : const UnavailableCv1Transport(),
        ownerChange: library.ownerChange,
        doubleTapAction: () => _doubleTap,
        resumeSettings: _groupPrefs == null ? null : Cv1ResumeSettings(_groupPrefs!, library.audioOwnerId),
        diagnosticsHistory: Cv1History(preferences: _groupPrefs),
      );
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
      _sampleIdleLink();
    } else {
      unawaited(_inputs?.connection.history.flush());
    }
  }

  @override
  void dispose() {
    _closed = true;
    _diagnosticPoll?.cancel();
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
    return LocalNextCaptureControls(
      inputs: inputs,
      serverLabel: widget.serverName,
      hasCv1: _hasCv1,
      openServers: widget.openServers,
      library: widget.library,
      groupSilence: _groupSilence,
      onGroupSilence: _groupPrefs == null ? null : _setGroupSilence,
      doubleTap: _doubleTap,
      onDoubleTap: _groupPrefs == null ? null : _setDoubleTap,
    );
  }

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
    if (prefs == null || _captureBusy() || !widget.library.ownerChange.permitsCapture) return false;
    try {
      final saved = seconds == null ? await prefs.remove(_groupPrefKey) : await prefs.setInt(_groupPrefKey, seconds);
      if (saved && mounted) {
        setState(() => _groupSilence = seconds);
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
  bool get hasCaptureInProgress => switching || isRecording || cv1.sealing;
  bool get permitsNewRecording => !_closed && (ownerChange?.permitsCapture ?? true);
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

class LocalNextCaptureControls extends StatelessWidget {
  const LocalNextCaptureControls({
    required this.inputs,
    this.serverLabel = '',
    this.hasCv1 = true,
    this.library,
    this.groupSilence,
    this.onGroupSilence,
    this.doubleTap = Cv1DoubleTapAction.checkpoint,
    this.onDoubleTap,
    this.openServers,
    super.key,
  });
  final NextCaptureInputs inputs;
  final String serverLabel;
  final bool hasCv1;
  final PairedLibrary? library;
  final int? groupSilence;
  final Future<bool> Function(int?)? onGroupSilence;
  final Cv1DoubleTapAction doubleTap;
  final Future<bool> Function(Cv1DoubleTapAction)? onDoubleTap;
  final VoidCallback? openServers;

  void _openDiagnostics(BuildContext context, Listenable capture) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NextDeviceDiagnosticsPage(
          link: inputs.connection,
          capture: capture,
          captureBusy: () => inputs.hasCaptureInProgress,
        ),
      ),
    );
  }

  String _boundary(BuildContext context, int? seconds) => switch (seconds) {
    null => pairedSettingsLabel(context, 'groupCaptureLegacy'),
    0 => pairedSettingsLabel(context, 'groupCaptureSingle'),
    _ => '${pairedSettingsLabel(context, 'groupCaptureSilence')} · ${seconds}s',
  };

  void _settings(BuildContext context, Listenable capture, PairedLibrary library) {
    var boundary = groupSilence;
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
                        leading: const Icon(Icons.bluetooth),
                        title: const Text('Omi CV1'),
                        subtitle: Text(cv1PhaseLabel(context, link.phase)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          unawaited(showNextDevices(context, inputs));
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.monitor_heart_outlined),
                        title: Text(l.deviceDiagnostics),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openDiagnostics(context, capture),
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
                          leading: const Icon(Icons.touch_app_outlined),
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
                      leading: const Icon(Icons.mic_none),
                      title: Text(l.recording),
                      subtitle: Text(
                        inputs.phone.active
                            ? l.phone
                            : inputs.cv1.active
                            ? 'Omi CV1'
                            : l.off,
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.cloud_upload_outlined),
                      title: Text(pairedSettingsLabel(context, 'nextPhoneOutbox')),
                      subtitle: Text(
                        journal.pendingParts == 0
                            ? pairedSettingsLabel(context, 'nextOutboxHealthy')
                            : '${l.nPending(journal.pendingParts)} · ${(journal.pendingBytes / (1 << 20)).toStringAsFixed(1)} MiB',
                      ),
                      trailing: journal.deliveryFailed
                          ? TextButton(onPressed: journal.retry, child: Text(l.retry))
                          : null,
                    ),
                    if (library.conversationGroups && onGroupSilence != null)
                      ListTile(
                        leading: const Icon(Icons.call_split),
                        title: Text(pairedSettingsLabel(context, 'groupCaptureLabel')),
                        subtitle: Text(_boundary(context, boundary)),
                        trailing: PopupMenuButton<int>(
                          key: const ValueKey('next-recording-boundaries'),
                          tooltip: l.edit,
                          enabled: !inputs.hasCaptureInProgress && library.ownerChange.permitsCapture,
                          initialValue: boundary ?? -1,
                          onSelected: (value) async {
                            if (inputs.hasCaptureInProgress || !library.ownerChange.permitsCapture) return;
                            final selected = value == -1 ? null : value;
                            final saved = await onGroupSilence!(selected);
                            if (saved && context.mounted) refresh(() => boundary = selected);
                          },
                          itemBuilder: (context) => [
                            for (final value in [-1, ...LocalAudioJournal.groupSilenceChoices])
                              PopupMenuItem(value: value, child: Text(_boundary(context, value == -1 ? null : value))),
                          ],
                        ),
                      ),
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(pairedSettingsLabel(context, 'localMacServers')),
                      subtitle: Text(serverLabel),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: openServers,
                    ),
                    ListTile(
                      leading: const Icon(Icons.health_and_safety_outlined),
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

  @override
  Widget build(BuildContext context) {
    final capture = inputs.phone;
    final cv1 = inputs.cv1;
    final link = inputs.connection;
    final captureState = Listenable.merge([inputs, capture, cv1, inputs.ownerChange]);
    final journal = capture.journal;
    final l = context.l10n;
    return ListenableBuilder(
      listenable: Listenable.merge([captureState, journal, link]),
      builder: (context, _) => Column(
        children: [
          if ((capture.active ? capture.startedAt : cv1.startedAt) case final started?)
            _ActiveRecordingTime(
              started: started,
              input: capture.active ? pairedSettingsLabel(context, 'nextPhoneInput') : 'CV1',
              clock: journal.clock,
            ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('next-phone-capture'),
                onPressed: inputs.switching || capture.busy || (!capture.active && !inputs.permitsNewRecording)
                    ? null
                    : inputs.togglePhone,
                icon: Icon(capture.active ? Icons.stop : Icons.mic),
                label: Text(capture.active ? '${l.stop} · ${l.phone}' : l.recordWithPhoneMic),
              ),
              if (cv1.linked || cv1.active)
                OutlinedButton.icon(
                  key: const ValueKey('next-cv1-capture'),
                  onPressed: inputs.switching || (!cv1.active && (!cv1.codecSupported || !inputs.permitsNewRecording))
                      ? null
                      : cv1.active
                      ? cv1.stop
                      : inputs.startCv1,
                  icon: Icon(cv1.active ? Icons.stop : Icons.fiber_manual_record),
                  label: Text(cv1.active ? '${l.stop} · CV1' : '${l.recordWith} CV1'),
                ),
              if (cv1.active)
                TextButton.icon(
                  key: const ValueKey('next-cv1-finish'),
                  icon: const Icon(Icons.skip_next),
                  label: Text(pairedSettingsLabel(context, 'nextFinishContinue')),
                  onPressed: inputs.switching || !cv1.canFinish ? null : cv1.finishConversation,
                ),
              if (cv1.active)
                IconButton(
                  tooltip: cv1.intent == Cv1CaptureIntent.muted ? l.unmute : l.mute,
                  icon: Icon(cv1.intent == Cv1CaptureIntent.muted ? Icons.mic_off : Icons.mic),
                  onPressed: inputs.switching ? null : cv1.toggleMute,
                ),
              if (library case final paired?)
                IconButton(
                  key: const ValueKey('next-mobile-settings'),
                  tooltip: pairedSettingsLabel(context, 'nextMobileSettings'),
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => _settings(context, captureState, paired),
                ),
              if (hasCv1)
                TextButton.icon(
                  key: const ValueKey('next-cv1-devices'),
                  icon: Icon(cv1.linked ? Icons.bluetooth_connected : Icons.bluetooth),
                  label: Text(
                    link.phase == Cv1LinkPhase.idle && !cv1.active
                        ? l.connectDevice
                        : [
                            'CV1',
                            cv1PhaseLabel(context, link.phase),
                            if (link.diagnostics?.battery case final battery?) '$battery%',
                            if (cv1.intent == Cv1CaptureIntent.muted)
                              l.muted
                            else if (cv1.active && cv1.linked)
                              cv1.hasPersistedAudio ? l.recording : l.waitingForData,
                          ].join(' · '),
                  ),
                  onPressed: () {
                    unawaited(showNextDevices(context, inputs));
                  },
                ),
            ],
          ),
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
            }),
          if (journal.pendingParts > 0) Text(l.nPending(journal.pendingParts)),
          if (journal.deliveryFailed) TextButton(onPressed: journal.retry, child: Text(l.captureBannerRetrySync)),
          if (inputs.preview case final preview?)
            LocalNextLiveButton(
              preview: preview,
              capture: captureState,
              isRecording: () => inputs.isRecording,
              isMuted: () => cv1.active && cv1.intent == Cv1CaptureIntent.muted,
              onStop: inputs.stopRecording,
              serverLabel: serverLabel,
              library: library,
            ),
        ],
      ),
    );
  }
}

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
    return Text('${widget.input} · $time', key: const ValueKey('next-recording-time'));
  }
}

Future<void> showNextDevices(BuildContext context, NextCaptureInputs inputs) async {
  final connection = inputs.connection;
  if (connection.phase == Cv1LinkPhase.idle || connection.phase == Cv1LinkPhase.failed) unawaited(connection.scan());
  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: ListenableBuilder(
        listenable: connection,
        builder: (context, _) {
          final l = context.l10n;
          final selected = connection.phase == Cv1LinkPhase.ready || connection.phase == Cv1LinkPhase.reconnecting;
          return ListView(
            shrinkWrap: true,
            children: [
              if (selected)
                ListTile(
                  leading: const Icon(Icons.bluetooth_connected),
                  title: const Text('Omi CV1'),
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
                  title: Text(l.connectDevice),
                  subtitle: connection.phase == Cv1LinkPhase.scanning ? Text(l.searchingForDevices) : null,
                  trailing: TextButton(onPressed: inputs._closed ? null : connection.scan, child: Text(l.scanAgain)),
                ),
                for (final device in connection.devices)
                  ListTile(
                    title: Text(device.name.trim().isEmpty ? 'Omi CV1' : device.name),
                    leading: const Icon(Icons.bluetooth),
                    onTap: () async {
                      if (inputs._closed) return;
                      await connection.connect(device.id);
                      if (context.mounted && !connection.operationFailed) Navigator.pop(context);
                    },
                  ),
              ],
              if (connection.permissionDenied)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(pairedSettingsLabel(context, 'nextCv1ScanPermission')),
                )
              else if (connection.operationFailed || connection.phase == Cv1LinkPhase.failed)
                Padding(padding: const EdgeInsets.all(16), child: Text(l.connectionFailed)),
              if (connection.phase == Cv1LinkPhase.unavailable)
                Padding(padding: const EdgeInsets.all(16), child: Text(l.bluetoothNeeded)),
            ],
          );
        },
      ),
    ),
  );
}
