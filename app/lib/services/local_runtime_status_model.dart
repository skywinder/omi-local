enum LocalCaptureState { idle, waitingAudio, received, decodeError }

enum LocalLiveTranscriptState { disabled, unavailable, ready, busy, streaming, failed }

enum LocalDiarizationState { unknown, disabled, unavailable, ready, busy, pending, labeled, degraded, failed }

enum LocalStageState { ready, unavailable, misconfigured, disabled, unknown }

/// Readiness of one server-side processing stage, as probed by the Mac harness.
class LocalStageStatus {
  const LocalStageStatus({required this.state, this.name, this.kind});

  final LocalStageState state;
  final String? name;
  final String? kind;

  static const stageOrder = ['stt', 'diarization', 'live', 'summary'];

  static LocalStageStatus? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final state = switch (value['status']) {
      'ready' => LocalStageState.ready,
      'unavailable' => LocalStageState.unavailable,
      'misconfigured' => LocalStageState.misconfigured,
      'disabled' => LocalStageState.disabled,
      _ => LocalStageState.unknown,
    };
    String? text(Object? raw) =>
        raw is String && raw.trim().isNotEmpty ? raw.substring(0, raw.length.clamp(0, 100)) : null;
    return LocalStageStatus(state: state, name: text(value['name']), kind: text(value['kind']));
  }

  @override
  bool operator ==(Object other) =>
      other is LocalStageStatus && other.state == state && other.name == name && other.kind == kind;

  @override
  int get hashCode => Object.hash(state, name, kind);

  @override
  String toString() => 'LocalStageStatus($state, $name, $kind)';
}

/// Aggregate evidence from the Mac, never inferred from a phone socket state.
class LocalRuntimeStatus {
  const LocalRuntimeStatus({
    required this.captureState,
    required this.audioSeconds,
    required this.framesReceived,
    required this.liveTranscriptState,
    required this.transcriptUpdates,
    this.diarizationState = LocalDiarizationState.unknown,
    this.labeledSegments = 0,
    this.stages = const {},
    this.stagesStale = false,
  });

  final LocalCaptureState captureState;
  final double audioSeconds;
  final int framesReceived;
  final LocalLiveTranscriptState liveTranscriptState;
  final int transcriptUpdates;
  final LocalDiarizationState diarizationState;
  final int labeledSegments;

  /// Server-side stage readiness keyed by stage; empty when the Mac does not report it.
  final Map<String, LocalStageStatus> stages;
  final bool stagesStale;

  factory LocalRuntimeStatus.fromJson(Object? value) {
    const invalid = FormatException('Invalid local runtime status');
    if (value is! Map<String, dynamic> || value['backend'] != 'ready') throw invalid;
    final capture = value['capture'];
    final live = value['live_transcript'];
    if (capture is! Map<String, dynamic> || live is! Map<String, dynamic>) throw invalid;
    final captureState = switch (capture['state']) {
      'idle' => LocalCaptureState.idle,
      'waiting_audio' => LocalCaptureState.waitingAudio,
      'received' => LocalCaptureState.received,
      'decode_error' => LocalCaptureState.decodeError,
      _ => throw invalid,
    };
    final liveState = switch (live['state']) {
      'disabled' => LocalLiveTranscriptState.disabled,
      'unavailable' => LocalLiveTranscriptState.unavailable,
      'ready' => LocalLiveTranscriptState.ready,
      'busy' => LocalLiveTranscriptState.busy,
      'streaming' => LocalLiveTranscriptState.streaming,
      'failed' => LocalLiveTranscriptState.failed,
      _ => throw invalid,
    };
    // Older servers omit this field. Absence is unknown, never disabled/healthy.
    final diarization = value['diarization'];
    var diarizationState = LocalDiarizationState.unknown;
    var labeledSegments = 0;
    if (diarization != null) {
      if (diarization is! Map<String, dynamic>) throw invalid;
      diarizationState = switch (diarization['state']) {
        'disabled' => LocalDiarizationState.disabled,
        'unavailable' => LocalDiarizationState.unavailable,
        'ready' => LocalDiarizationState.ready,
        'busy' => LocalDiarizationState.busy,
        'pending' => LocalDiarizationState.pending,
        'labeled' => LocalDiarizationState.labeled,
        'degraded' => LocalDiarizationState.degraded,
        'failed' => LocalDiarizationState.failed,
        _ => LocalDiarizationState.unknown,
      };
      final count = diarization['labeled_segments'];
      if (count is! int || count < 0) throw invalid;
      labeledSegments = count;
      if (diarizationState == LocalDiarizationState.labeled && count == 0) throw invalid;
    }
    final seconds = capture['audio_seconds'];
    final frames = capture['frames_received'];
    final updates = live['updates'];
    if (seconds is! num ||
        !seconds.isFinite ||
        seconds < 0 ||
        frames is! int ||
        frames < 0 ||
        updates is! int ||
        updates < 0) {
      throw invalid;
    }
    final stages = <String, LocalStageStatus>{};
    final rawStages = value['stages'];
    if (rawStages is Map<String, dynamic>) {
      for (final stage in LocalStageStatus.stageOrder) {
        final parsed = LocalStageStatus.fromJson(rawStages[stage]);
        if (parsed != null) stages[stage] = parsed;
      }
    }
    return LocalRuntimeStatus(
      captureState: captureState,
      audioSeconds: seconds.toDouble(),
      framesReceived: frames,
      liveTranscriptState: liveState,
      transcriptUpdates: updates,
      diarizationState: diarizationState,
      labeledSegments: labeledSegments,
      stages: stages,
      stagesStale: rawStages is Map<String, dynamic> && rawStages['stale'] == true,
    );
  }
}
