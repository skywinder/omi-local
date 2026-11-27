import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/services/capture/cv1_opus_frame_assembler.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

import 'cv1_resume.dart';
import 'live_preview.dart';

sealed class Cv1CaptureEvent {
  const Cv1CaptureEvent(this.generation);
  final int generation;
}

final class Cv1LinkReady extends Cv1CaptureEvent {
  const Cv1LinkReady(super.generation, this.codecCode);
  final int codecCode;
}

final class Cv1LinkLost extends Cv1CaptureEvent {
  const Cv1LinkLost(super.generation);
}

final class Cv1Audio extends Cv1CaptureEvent {
  const Cv1Audio(super.generation, this.raw);
  final Uint8List raw;
}

final class Cv1Button extends Cv1CaptureEvent {
  const Cv1Button(super.generation, this.code);
  final int code;
}

enum Cv1DoubleTapAction { checkpoint, stop, mute, off }

enum Cv1CaptureIntent { stopped, recording, muted }

enum Cv1CaptureProblem { unsupportedCodec, storage, sourceSwitch, preference }

class NextCv1Capture extends ChangeNotifier {
  NextCv1Capture(
    this.journal,
    this.owner, {
    required this.canStart,
    this.permitsStartRequest,
    this.onStartRequested,
    this.doubleTapAction,
    this.resumeSettings,
    this.preview,
    this.keepListeningAfterSilence,
  });

  final LocalAudioJournal journal;
  final String owner;
  final bool Function() canStart;
  final bool Function()? permitsStartRequest;
  final Future<void> Function()? onStartRequested;
  final Cv1DoubleTapAction Function()? doubleTapAction;
  final Cv1ResumeSettings? resumeSettings;
  final NextLivePreview? preview;
  final bool Function()? keepListeningAfterSilence;
  final _frames = Cv1OpusFrameAssembler();
  LocalAudioRecording? _recording;
  DateTime? startedAt;
  Future<void>? _sealing;
  bool get sealing => _sealing != null;
  Future<void> get _sealed => _sealing ?? Future<void>.value();
  Cv1CaptureIntent _intent = Cv1CaptureIntent.stopped;
  Cv1CaptureIntent get intent => _intent;
  Cv1CaptureProblem? _problem;
  Cv1CaptureProblem? get problem => _problem;
  int? _generation;
  int? get generation => _generation;
  int? _codecCode;
  bool get linked => _codecCode != null;
  String? get _codec => _codecFor(_codecCode);
  String? _codecFor(int? code) => switch (code) {
    20 => 'opus',
    21 => 'opus_fs320',
    _ => null,
  };
  bool get codecSupported => _codec != null;
  bool get active => _intent != Cv1CaptureIntent.stopped;
  bool get wantsAudio => _intent == Cv1CaptureIntent.recording && codecSupported;
  static const _audioGap = Duration(seconds: 5);
  DateTime? _lastPersistedAt;
  Timer? _audioDeadline;
  Timer? _silenceDeadline;
  DateTime? _lastAcceptedAt;
  bool _stopAfterSilence = false;
  bool get hasPersistedAudio => _lastPersistedAt != null;
  bool get audioPaused => wantsAudio && hasPersistedAudio && _audioDeadline == null;

  void _clearAudioStatus() {
    _audioDeadline?.cancel();
    _audioDeadline = null;
    _lastPersistedAt = null;
    _clearSilenceDeadline();
  }

  void _clearSilenceDeadline() {
    _silenceDeadline?.cancel();
    _silenceDeadline = null;
    _lastAcceptedAt = null;
  }

  void rearmSilenceDeadline() {
    _silenceDeadline?.cancel();
    _silenceDeadline = null;
    final seconds = _recording?.silenceSeconds ?? (_recording?.reviewSpeech == true ? 2 : 0);
    final last = _lastAcceptedAt;
    if (!wantsAudio || seconds == 0 || last == null) return;
    final remaining = last.add(Duration(seconds: seconds)).difference(journal.clock());
    if (remaining > Duration.zero) {
      _silenceDeadline = Timer(remaining, rearmSilenceDeadline);
    } else {
      unawaited(_stopAfterSilence ? stop() : finishConversation());
    }
  }

  void _markAudioReceived() {
    _lastPersistedAt = journal.clock();
    if (_audioDeadline != null) return;
    _audioDeadline = Timer(_audioGap, _checkAudioFlow);
    notifyListeners();
  }

  void _checkAudioFlow() {
    final remaining = _lastPersistedAt!.add(_audioGap).difference(journal.clock());
    if (remaining > Duration.zero) {
      _audioDeadline = Timer(remaining, _checkAudioFlow);
      return;
    }
    _audioDeadline = null;
    notifyListeners();
  }

  int? _lastButtonCode;
  int? get lastButtonCode => _lastButtonCode;
  bool _closed = false;
  int _attempt = 0;
  int _segment = 0;
  int _previewEpoch = 0;
  int _buttonRequest = 0;
  bool _requestPending = false;

  Future<void> _remember(Cv1ResumeMode mode) async {
    final settings = resumeSettings;
    if (settings == null || !settings.enabled) return;
    if (!await settings.save(mode) && !_closed) {
      _problem = Cv1CaptureProblem.preference;
      notifyListeners();
    }
  }

  void Function(bool)? requestHardwareMute;
  bool? hardwareMuteConfirmed;

  void suspendForUnconfirmedMute() {
    if (_closed) return;
    _intent = Cv1CaptureIntent.muted;
    notifyListeners();
  }

  void restoreHardwareMute() {
    if (_closed) return;
    _intent = Cv1CaptureIntent.muted;
    hardwareMuteConfirmed = true;
    unawaited(_remember(Cv1ResumeMode.muted));
    notifyListeners();
  }

  void start({bool explicit = true}) {
    if (_closed || active || !canStart()) return;
    _cancelButtonStart();
    if (explicit) requestHardwareMute?.call(false);
    _attempt++;
    startedAt = journal.clock();
    _intent = Cv1CaptureIntent.recording;
    unawaited(_remember(Cv1ResumeMode.armed));
    _problem = linked && !codecSupported ? Cv1CaptureProblem.unsupportedCodec : null;
    notifyListeners();
  }

  Future<void> stop({bool explicit = true}) {
    if (_closed) return _sealed;
    _cancelButtonStart();
    if (explicit) requestHardwareMute?.call(true);
    final remembered = explicit ? _remember(Cv1ResumeMode.stopped) : Future<void>.value();
    if (!active) return Future.wait<void>([_sealed, remembered]);
    _intent = Cv1CaptureIntent.stopped;
    startedAt = null;
    _endSegment();
    notifyListeners();
    return Future.wait<void>([_sealed, remembered]);
  }

  bool get canFinish => active && _recording != null;
  int? get silenceSeconds => _recording?.silenceSeconds;

  /// Seal the current conversation while the same CV1 notification subscription
  /// keeps delivering frames. A new journal starts on the next complete packet.
  Future<void> finishConversation() {
    if (!canFinish) return _sealed;
    _endSegment(reportSealFailure: true);
    startedAt = null;
    notifyListeners();
    return _sealed;
  }

  void toggleMute() {
    if (_closed || !active) return;
    _intent = _intent == Cv1CaptureIntent.muted ? Cv1CaptureIntent.recording : Cv1CaptureIntent.muted;
    requestHardwareMute?.call(_intent == Cv1CaptureIntent.muted);
    unawaited(_remember(_intent == Cv1CaptureIntent.muted ? Cv1ResumeMode.muted : Cv1ResumeMode.armed));
    if (_intent == Cv1CaptureIntent.recording) startedAt ??= journal.clock();
    if (_intent == Cv1CaptureIntent.muted) {
      _frames.discardPending();
      _audioDeadline?.cancel();
      _audioDeadline = null;
      _clearSilenceDeadline();
      _cutPreview();
      _checkpoint(resetOpusContext: true);
    }
    notifyListeners();
  }

  void handle(Cv1CaptureEvent event) {
    if (_closed || event.generation < (_generation ?? 0)) return;
    switch (event) {
      case Cv1LinkReady(:final codecCode):
        if (_generation == event.generation && _codecCode == codecCode) return;
        _setLink(event.generation, codecCode);
        if (!active && codecSupported && canStart()) {
          switch (resumeSettings?.mode) {
            case Cv1ResumeMode.armed:
              start(explicit: false);
            case Cv1ResumeMode.muted:
              // Restore the control without requesting even one audio notification.
              _intent = Cv1CaptureIntent.muted;
              notifyListeners();
            default:
              break;
          }
        }
      case Cv1LinkLost():
        if (_generation == event.generation && !linked) return;
        _setLink(event.generation, null);
      case Cv1Audio(:final raw):
        if (event.generation == _generation && wantsAudio) _accept(raw);
      case Cv1Button(:final code):
        if (event.generation == _generation && linked) _button(code);
    }
  }

  void _setLink(int generation, int? codecCode) {
    _cancelButtonStart();
    final current = _recording;
    if (current != null &&
        current.silenceSeconds != null &&
        active &&
        (codecCode == null || current.codec == _codecFor(codecCode))) {
      _frames.discardPending();
      _clearAudioStatus();
      _cutPreview();
      _checkpoint(resetOpusContext: true);
    } else {
      _endSegment();
    }
    _generation = generation;
    _codecCode = codecCode;
    _lastButtonCode = null;
    if (_problem != Cv1CaptureProblem.storage) {
      _problem = linked && !codecSupported ? Cv1CaptureProblem.unsupportedCodec : null;
    }
    notifyListeners();
  }

  void _accept(Uint8List raw) {
    if (_silenceDeadline != null) {
      final seconds = _recording!.silenceSeconds ?? 2;
      if (journal.clock().difference(_lastAcceptedAt!) >= Duration(seconds: seconds)) {
        rearmSilenceDeadline();
        if (!wantsAudio) return;
      }
    }
    final previousDrops = _frames.discardedCandidates;
    final frame = _frames.add(raw);
    if (previousDrops != _frames.discardedCandidates) {
      // Start new decoder context after a gap. The assembler may already have
      // accepted the first fragment of the next frame.
      _cutPreview();
      _checkpoint(resetOpusContext: true);
    }
    if (frame == null) return;
    if (_recording == null) {
      _segment++;
      startedAt ??= journal.clock();
      _stopAfterSilence = (journal.groupSilence?.call() ?? 0) > 0 && keepListeningAfterSilence?.call() != true;
    }
    final current = _recording ??= journal.beginForServer(source: 'omi', codec: _codec!, serverId: owner);
    final acceptedAt = journal.clock();
    final elapsed = acceptedAt.difference(startedAt!).inMicroseconds / Duration.microsecondsPerSecond;
    if ((current.silenceSeconds ?? (current.reviewSpeech ? 2 : 0)) > 0) {
      _lastAcceptedAt = acceptedAt;
      if (_silenceDeadline == null) rearmSilenceDeadline();
    }
    final attempt = _attempt;
    final segment = _segment;
    final previewEpoch = _previewEpoch;
    unawaited(
      current
          .add(
            frame,
            afterPersisted: () {
              if (_closed || current != _recording) return;
              if (preview case final live? when previewEpoch == _previewEpoch) {
                final duration = LocalAudioRecording.packetMicroseconds(current.codec, frame) / 1000000;
                live.begin(
                  current.recordingId,
                  current.source,
                  current.codec,
                  silenceSeconds: current.silenceSeconds,
                  onSilence: _stopAfterSilence && (current.silenceSeconds ?? 0) > 0
                      ? () {
                          if (current == _recording && wantsAudio && previewEpoch == _previewEpoch) unawaited(stop());
                        }
                      : null,
                );
                live.addPersisted(
                  current.recordingId,
                  current.source,
                  current.codec,
                  frame,
                  startSeconds: (current.audioSeconds - duration).clamp(0.0, double.infinity),
                  elapsedSeconds: elapsed - duration,
                );
              }
              if (wantsAudio && previewEpoch == _previewEpoch) _markAudioReceived();
            },
          )
          .catchError((Object _) => _writeFailed(current, attempt, segment)),
    );
  }

  void _cutPreview() {
    _previewEpoch++;
    final recording = _recording;
    if (recording != null) preview?.end(recording.recordingId);
  }

  void _writeFailed(LocalAudioRecording current, int attempt, int segment) {
    if (_closed || attempt != _attempt || segment != _segment) return;
    if (current != _recording && active) return;
    _problem = Cv1CaptureProblem.storage;
    if (active) {
      unawaited(stop(explicit: false));
    } else {
      notifyListeners();
    }
  }

  void _endSegment({bool reportSealFailure = false}) {
    _frames.discardPending();
    _clearAudioStatus();
    _cutPreview();
    final current = _recording;
    _recording = null;
    if (current == null) return;
    final segment = _segment;
    final attempt = _attempt;
    // stop() seals after every already accepted journal write on the same queue.
    late final Future<void> seal;
    seal = current
        .stop()
        .catchError((Object _) {
          if (reportSealFailure && !_closed && attempt == _attempt) {
            // The next conversation may already have accepted audio. Surface the
            // failed seal without stopping that new recording.
            _problem = Cv1CaptureProblem.storage;
            notifyListeners();
          } else {
            _writeFailed(current, attempt, segment);
          }
        })
        .whenComplete(() {
          if (identical(_sealing, seal)) _sealing = null;
        });
    _sealing = seal;
  }

  void _button(int code) {
    _lastButtonCode = code;
    notifyListeners();
    if (code == 1) {
      if (active || _requestPending) {
        unawaited(stop());
      } else if (codecSupported && (permitsStartRequest?.call() ?? true)) {
        unawaited(_startFromButton());
      }
    } else if (code == 2 && active) {
      switch (doubleTapAction?.call() ?? Cv1DoubleTapAction.checkpoint) {
        case Cv1DoubleTapAction.checkpoint:
          if (_intent == Cv1CaptureIntent.recording) _checkpoint();
        case Cv1DoubleTapAction.stop:
          unawaited(stop());
        case Cv1DoubleTapAction.mute:
          toggleMute();
        case Cv1DoubleTapAction.off:
          break;
      }
    }
  }

  void _checkpoint({bool resetOpusContext = false}) {
    final current = _recording;
    if (current == null) return;
    final attempt = _attempt;
    final segment = _segment;
    unawaited(
      current
          .checkpoint(resetOpusContext: resetOpusContext)
          .catchError((Object _) => _writeFailed(current, attempt, segment)),
    );
  }

  Future<void> _startFromButton() async {
    final request = ++_buttonRequest;
    _requestPending = true;
    try {
      if (onStartRequested != null) await onStartRequested!();
      if (request == _buttonRequest) start();
    } catch (_) {
      if (request != _buttonRequest) return;
      _problem = Cv1CaptureProblem.sourceSwitch;
      notifyListeners();
    } finally {
      if (request == _buttonRequest) _requestPending = false;
    }
  }

  void _cancelButtonStart() {
    _buttonRequest++;
    _requestPending = false;
  }

  Future<void> close() {
    if (_closed) return _sealed;
    _closed = true;
    _cancelButtonStart();
    _intent = Cv1CaptureIntent.stopped;
    _endSegment();
    return Future.wait<void>([_sealed, if (resumeSettings case final settings?) settings.saved.then((_) {})]);
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
