import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/services/local_runtime_status_model.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'paired_library.dart';
import 'settings_labels.dart';

class NextServerStatusPage extends StatefulWidget {
  const NextServerStatusPage({super.key, required this.library, required this.serverName});

  final PairedLibrary library;
  final String serverName;

  @override
  State<NextServerStatusPage> createState() => _NextServerStatusPageState();
}

class _NextServerStatusPageState extends State<NextServerStatusPage> with WidgetsBindingObserver {
  LocalRuntimeStatus? _status;
  Object? _error;
  Timer? _timer;
  bool _visible = false, _foreground = false, _loading = false, _unsupported = false;
  int _generation = 0;

  bool get _canRead => mounted && _visible && _foreground;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    _foreground = binding.lifecycleState == null || binding.lifecycleState == AppLifecycleState.resumed;
    binding.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = ModalRoute.isCurrentOf(context) ?? true;
    if (visible == _visible) return;
    _visible = visible;
    _resetPoll();
  }

  @override
  void didUpdateWidget(NextServerStatusPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.library == oldWidget.library) return;
    _status = null;
    _error = null;
    _unsupported = false;
    _resetPoll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    _resetPoll();
  }

  void _resetPoll() {
    _generation++;
    _timer?.cancel();
    if (_canRead && !_unsupported) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (!_canRead || _loading) return;
    _timer?.cancel();
    final generation = _generation;
    setState(() => _loading = true);
    try {
      final status = await widget.library.readRuntimeStatus();
      if (_canRead && generation == _generation) {
        setState(() {
          _status = status;
          _error = null;
          _unsupported = status == null;
        });
      }
    } catch (error) {
      if (_canRead && generation == _generation) {
        setState(() {
          _status = null;
          _error = error;
          _unsupported = false;
        });
      }
    } finally {
      _loading = false;
      if (_canRead) {
        if (generation != _generation) {
          unawaited(_refresh());
        } else {
          setState(() {});
          if (!_unsupported && _error != LibraryFailure.key) {
            _timer = Timer(const Duration(seconds: 5), _refresh);
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final status = _status;
    final connection = switch (_error) {
      LibraryFailure.key => l.invalidKey,
      _ when _unsupported => pairedSettingsLabel(context, 'serverStatusUnsupported'),
      _ when _error != null => pairedSettingsLabel(context, 'serverStatusUnavailable'),
      _ when status != null => '${l.connected} · ${l.apiKeyAuth}',
      _ => l.loading,
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(pairedSettingsLabel(context, 'serverStatus')),
        actions: [
          IconButton(onPressed: _loading ? null : _refresh, icon: const Icon(Icons.refresh), tooltip: l.refresh),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: Text(widget.serverName),
            subtitle: Text(connection, key: const ValueKey('next-server-connection')),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (status != null) ...[
            ListTile(
              title: Text(pairedSettingsLabel(context, 'serverStatusAudio')),
              subtitle: Text(switch (status.captureState) {
                LocalCaptureState.idle => pairedSettingsLabel(context, 'serverNoAudioStream'),
                LocalCaptureState.waitingAudio => l.waitingForData,
                LocalCaptureState.decodeError => l.error,
                LocalCaptureState.received => l.secondsCount(status.audioSeconds.floor()),
              }, key: const ValueKey('next-server-audio')),
            ),
            ListTile(
              title: Text(l.liveTranscript),
              subtitle: Text(switch (status.liveTranscriptState) {
                LocalLiveTranscriptState.disabled => l.off,
                LocalLiveTranscriptState.unavailable => l.transcriptionUnavailable,
                LocalLiveTranscriptState.ready => l.modelReady,
                LocalLiveTranscriptState.busy => l.processing,
                LocalLiveTranscriptState.streaming => '${l.transcriptReceived} · ${status.transcriptUpdates}',
                LocalLiveTranscriptState.failed => pairedSettingsLabel(context, 'transcriptionFailed'),
              }, key: const ValueKey('next-server-live')),
            ),
            ListTile(
              title: Text(pairedSettingsLabel(context, 'serverLiveDiarization')),
              subtitle: Text(switch (status.diarizationState) {
                LocalDiarizationState.unknown => l.unknown,
                LocalDiarizationState.disabled => l.off,
                LocalDiarizationState.ready => l.modelReady,
                LocalDiarizationState.busy => l.processing,
                LocalDiarizationState.pending => l.waitingForData,
                LocalDiarizationState.labeled => l.nProcessed(status.labeledSegments),
                LocalDiarizationState.degraded ||
                LocalDiarizationState.unavailable => pairedSettingsLabel(context, 'providerUnavailable'),
                LocalDiarizationState.failed => l.statusFailed,
              }, key: const ValueKey('next-server-diarization')),
            ),
            if (status.stagesStale) ListTile(title: Text(pairedSettingsLabel(context, 'serverStageStale'))),
            for (final (stage, label) in [
              ('stt', l.transcription),
              ('diarization', pairedSettingsLabel(context, 'diarization')),
              ('summary', l.summary),
            ])
              if (status.stages[stage] case final provider?)
                ListTile(
                  title: Text(label),
                  subtitle: Text(
                    status.stagesStale
                        ? l.unknown
                        : switch (provider.state) {
                            LocalStageState.ready => l.modelReady,
                            LocalStageState.unavailable => pairedSettingsLabel(context, 'providerUnavailable'),
                            LocalStageState.misconfigured => pairedSettingsLabel(context, 'providerMisconfigured'),
                            LocalStageState.disabled => l.off,
                            LocalStageState.unknown => l.unknown,
                          },
                    key: ValueKey('next-server-stage-$stage'),
                  ),
                ),
          ],
        ],
      ),
    );
  }
}
