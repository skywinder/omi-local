import 'dart:async';

import 'package:flutter/material.dart';

import 'package:omi/env/env.dart';
import 'package:omi/services/auth/local_mac_session.dart';
import 'package:omi/services/local_runtime_status.dart';
import 'package:omi/utils/l10n_extensions.dart';

/// Polls only while this route and its containing tab are visible and foreground.
class LocalRuntimeStatusCard extends StatefulWidget {
  const LocalRuntimeStatusCard({
    super.key,
    this.session,
    this.fetcher,
    this.active = true,
    this.refreshInterval = const Duration(seconds: 5),
  });

  final LocalMacSession? session;
  final Future<LocalRuntimeStatus> Function()? fetcher;
  final bool active;
  final Duration refreshInterval;

  @override
  State<LocalRuntimeStatusCard> createState() => _LocalRuntimeStatusCardState();
}

enum _ConnectionState { unknown, loading, connected, unavailable, rejected }

class _LocalRuntimeStatusCardState extends State<LocalRuntimeStatusCard> with WidgetsBindingObserver {
  LocalMacSession get _session => widget.session ?? LocalMacSession.instance;
  Timer? _timer;
  int _generation = 0;
  bool _visible = false;
  bool _foreground = true;
  bool _loading = false;
  _ConnectionState _connection = _ConnectionState.unknown;
  LocalRuntimeStatus? _status;

  bool get _canPoll =>
      mounted && Env.isOfflineRuntime && widget.active && _visible && _foreground && _session.isSignedIn;

  @override
  void initState() {
    super.initState();
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _session.addListener(_sessionChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = (ModalRoute.isCurrentOf(context) ?? true) && TickerMode.valuesOf(context).enabled;
    if (_visible != visible) {
      _visible = visible;
      _restart();
    }
  }

  @override
  void didUpdateWidget(LocalRuntimeStatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      (oldWidget.session ?? LocalMacSession.instance).removeListener(_sessionChanged);
      _session.addListener(_sessionChanged);
    }
    if (oldWidget.session != widget.session ||
        oldWidget.active != widget.active ||
        oldWidget.fetcher != widget.fetcher ||
        oldWidget.refreshInterval != widget.refreshInterval) {
      _restart();
    }
  }

  void _sessionChanged() => _restart();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _restart();
  }

  void _restart() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _loading = false;
    _status = null;
    _connection = _ConnectionState.unknown;
    if (mounted) setState(() {});
    if (_canPoll) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (!_canPoll || _loading) return;
    _timer?.cancel();
    _timer = null;
    final generation = _generation;
    setState(() {
      _loading = true;
      _connection = _ConnectionState.loading;
      _status = null;
    });
    try {
      final status = await (widget.fetcher ?? LocalRuntimeStatusClient(session: _session).fetch)();
      if (generation != _generation || !_canPoll) return;
      setState(() {
        _status = status;
        _connection = _ConnectionState.connected;
      });
    } on LocalMacUnauthorized {
      if (generation != _generation || !_canPoll) return;
      setState(() => _connection = _ConnectionState.rejected);
    } catch (_) {
      if (generation != _generation || !_canPoll) return;
      setState(() => _connection = _ConnectionState.unavailable);
    } finally {
      if (generation == _generation && _canPoll) {
        setState(() => _loading = false);
        _timer = Timer(widget.refreshInterval, () => unawaited(_refresh()));
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _session.removeListener(_sessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String _connectionText(BuildContext context) => switch (_connection) {
        _ConnectionState.connected => '${context.l10n.connected} · ${context.l10n.apiKeyAuth}',
        _ConnectionState.loading => context.l10n.loading,
        _ConnectionState.rejected => context.l10n.localMacKeyRejected,
        _ConnectionState.unavailable => context.l10n.localMacConnectionFailed,
        _ConnectionState.unknown => _session.isSignedIn ? context.l10n.unknown : context.l10n.notConnectedStatus,
      };

  String _audioText(BuildContext context) {
    final status = _status;
    if (status == null) return context.l10n.unknown;
    final total = '${context.l10n.total}: ${context.l10n.secondsCount(status.audioSeconds.floor())}';
    return switch (status.captureState) {
      LocalCaptureState.idle || LocalCaptureState.waitingAudio => '${context.l10n.waitingForData} · $total',
      LocalCaptureState.received => total,
      LocalCaptureState.decodeError => '${context.l10n.error} · $total',
    };
  }

  String _transcriptText(BuildContext context) => switch (_status?.liveTranscriptState) {
        LocalLiveTranscriptState.disabled => context.l10n.off,
        LocalLiveTranscriptState.unavailable => context.l10n.transcriptionUnavailable,
        LocalLiveTranscriptState.ready => context.l10n.modelReady,
        LocalLiveTranscriptState.busy => context.l10n.processing,
        LocalLiveTranscriptState.streaming => '${context.l10n.transcriptReceived}: ${_status!.transcriptUpdates}',
        LocalLiveTranscriptState.failed => context.l10n.transcriptionFailed,
        null => context.l10n.unknown,
      };

  Widget _row(String name, String title, String value, IconData icon) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: Colors.white70),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 2),
              Text(value, key: ValueKey('local-runtime-$name'), style: const TextStyle(color: Colors.white)),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (!Env.isOfflineRuntime) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('local-runtime-status'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF222222), borderRadius: BorderRadius.circular(12)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: Text(context.l10n.statusLabel, style: const TextStyle(color: Colors.white))),
          IconButton(
            key: const ValueKey('local-runtime-refresh'),
            tooltip: context.l10n.refresh,
            onPressed: _canPoll && !_loading ? _refresh : null,
            icon: const Icon(Icons.refresh, color: Colors.white70),
          ),
        ]),
        _row('connection', context.l10n.localMacTitle, _connectionText(context), Icons.computer),
        _row('audio', context.l10n.audioDataReceived, _audioText(context), Icons.graphic_eq),
        _row('transcript', context.l10n.realtimeTranscript, _transcriptText(context), Icons.subtitles_outlined),
      ]),
    );
  }
}
