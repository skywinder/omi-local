import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omi/env/env.dart';
import 'package:omi/services/auth/local_mac_session.dart';
import 'package:omi/utils/offline_network_policy.dart';

enum LocalCaptureState { idle, waitingAudio, received, decodeError }

enum LocalLiveTranscriptState { disabled, unavailable, ready, busy, streaming, failed }

class LocalRuntimeStatusUnavailable implements Exception {}

/// Aggregate evidence from the Mac, never inferred from a phone socket state.
class LocalRuntimeStatus {
  const LocalRuntimeStatus({
    required this.captureState,
    required this.audioSeconds,
    required this.framesReceived,
    required this.liveTranscriptState,
    required this.transcriptUpdates,
  });

  final LocalCaptureState captureState;
  final double audioSeconds;
  final int framesReceived;
  final LocalLiveTranscriptState liveTranscriptState;
  final int transcriptUpdates;

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
    return LocalRuntimeStatus(
      captureState: captureState,
      audioSeconds: seconds.toDouble(),
      framesReceived: frames,
      liveTranscriptState: liveState,
      transcriptUpdates: updates,
    );
  }
}

class LocalRuntimeStatusClient {
  LocalRuntimeStatusClient({LocalMacSession? session}) : _session = session ?? LocalMacSession.instance;

  final LocalMacSession _session;
  static const requestTimeout = Duration(seconds: 8);
  static const maxResponseBytes = 64 * 1024;

  Future<LocalRuntimeStatus> fetch() async {
    if (!Env.isOfflineRuntime || !_session.isSignedIn) throw LocalMacUnauthorized();
    final address = _session.address;
    final base = Env.parseLocalTunnelUrl(address);
    final uri = base.resolve('v1/local/status');
    final authorization = _session.authorizationFor(uri);
    return HttpOverrides.runWithHttpOverrides(() async {
      final client = HttpClient()..connectionTimeout = requestTimeout;
      try {
        // One deadline covers connection, headers and the entire bounded body.
        return await (() async {
          final request = await client.getUrl(uri);
          request.followRedirects = false;
          request.headers.set(HttpHeaders.authorizationHeader, authorization);
          final response = await request.close();
          if (response.statusCode == 401 || response.statusCode == 403) throw LocalMacUnauthorized();
          if (response.statusCode != 200 || response.contentLength > maxResponseBytes) {
            throw LocalRuntimeStatusUnavailable();
          }
          final bytes = <int>[];
          await for (final chunk in response) {
            if (bytes.length + chunk.length > maxResponseBytes) throw LocalRuntimeStatusUnavailable();
            bytes.addAll(chunk);
          }
          final status = LocalRuntimeStatus.fromJson(jsonDecode(utf8.decode(bytes)));
          if (!_session.isSignedIn || _session.address != address || _session.authorizationFor(uri) != authorization) {
            throw LocalRuntimeStatusUnavailable();
          }
          return status;
        })()
            .timeout(requestTimeout);
      } finally {
        client.close(force: true);
      }
    }, OfflineHttpOverrides(OfflineNetworkPolicy.tunnel(base)));
  }
}
