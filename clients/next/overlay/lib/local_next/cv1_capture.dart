import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/services/capture/cv1_opus_frame_assembler.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

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

enum Cv1CaptureIntent { stopped, recording, muted }

enum Cv1CaptureProblem { unsupportedCodec, storage, sourceSwitch }

class NextCv1Capture extends ChangeNotifier {
  NextCv1Capture(this.journal, this.owner, {required this.canStart, this.onStartRequested});

  final LocalAudioJournal journal;
  final String owner;
  final bool Function() canStart;
  final Future<void> Function()? onStartRequested;
  final _frames = Cv1OpusFrameAssembler();
  LocalAudioRecording? _recording;
  Future<void> _sealing = Future.value();
  Cv1CaptureIntent _intent = Cv1CaptureIntent.stopped;
  Cv1CaptureIntent get intent => _intent;
  Cv1CaptureProblem? _problem;
  Cv1CaptureProblem? get problem => _problem;
  int? _generation;
  int? get generation => _generation;
  int? _codecCode;
  bool get linked => _codecCode != null;
  String? get _codec => switch (_codecCode) {
    20 => 'opus',
    21 => 'opus_fs320',
    _ => null,
  };
  bool get codecSupported => _codec != null;
  bool get active => _intent != Cv1CaptureIntent.stopped;
  bool get wantsAudio => _intent == Cv1CaptureIntent.recording && codecSupported;
  bool _hasPersistedAudio = false;
  bool get hasPersistedAudio => _hasPersistedAudio;
  int? _lastButtonCode;
  int? get lastButtonCode => _lastButtonCode;
  bool _closed = false;
  int _attempt = 0;
  int _segment = 0;
  int _buttonRequest = 0;
  bool _requestPending = false;

  void start() {
    if (_closed || active || !canStart()) return;
    _cancelButtonStart();
    _attempt++;
    _intent = Cv1CaptureIntent.recording;
    _problem = linked && !codecSupported ? Cv1CaptureProblem.unsupportedCodec : null;
    notifyListeners();
  }

  Future<void> stop() {
    if (_closed) return _sealing;
    _cancelButtonStart();
    if (!active) return _sealing;
    _intent = Cv1CaptureIntent.stopped;
    _endSegment();
    notifyListeners();
    return _sealing;
  }

  void toggleMute() {
    if (_closed || !active) return;
    _intent = _intent == Cv1CaptureIntent.muted ? Cv1CaptureIntent.recording : Cv1CaptureIntent.muted;
    if (_intent == Cv1CaptureIntent.muted) {
      _frames.discardPending();
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
    _endSegment();
    _generation = generation;
    _codecCode = codecCode;
    _lastButtonCode = null;
    if (_problem != Cv1CaptureProblem.storage) {
      _problem = linked && !codecSupported ? Cv1CaptureProblem.unsupportedCodec : null;
    }
    notifyListeners();
  }

  void _accept(Uint8List raw) {
    final previousDrops = _frames.discardedCandidates;
    final frame = _frames.add(raw);
    if (previousDrops != _frames.discardedCandidates) {
      // Start new decoder context after a gap. The assembler may already have
      // accepted the first fragment of the next frame.
      _checkpoint(resetOpusContext: true);
    }
    if (frame == null) return;
    if (_recording == null) _segment++;
    final current = _recording ??= journal.beginForServer(source: 'omi', codec: _codec!, serverId: owner);
    final attempt = _attempt;
    final segment = _segment;
    unawaited(
      current
          .add(
            frame,
            afterPersisted: () {
              if (_closed || current != _recording || _hasPersistedAudio) return;
              _hasPersistedAudio = true;
              notifyListeners();
            },
          )
          .catchError((Object _) => _writeFailed(current, attempt, segment)),
    );
  }

  void _writeFailed(LocalAudioRecording current, int attempt, int segment) {
    if (_closed || attempt != _attempt || segment != _segment) return;
    if (current != _recording && active) return;
    _problem = Cv1CaptureProblem.storage;
    if (active) {
      unawaited(stop());
    } else {
      notifyListeners();
    }
  }

  void _endSegment() {
    _frames.discardPending();
    _hasPersistedAudio = false;
    final current = _recording;
    _recording = null;
    if (current == null) return;
    final segment = _segment;
    final attempt = _attempt;
    // stop() seals after every already accepted journal write on the same queue.
    _sealing = current.stop().catchError((Object _) => _writeFailed(current, attempt, segment));
  }

  void _button(int code) {
    _lastButtonCode = code;
    notifyListeners();
    if (code == 1) {
      if (active || _requestPending) {
        unawaited(stop());
      } else if (codecSupported) {
        unawaited(_startFromButton());
      }
    } else if (code == 2 && _intent == Cv1CaptureIntent.recording) {
      _checkpoint();
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
    if (_closed) return _sealing;
    _closed = true;
    _cancelButtonStart();
    _intent = Cv1CaptureIntent.stopped;
    _endSegment();
    return _sealing;
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
