import 'dart:async';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:omi/services/capture/local_audio_journal.dart';

import 'live_preview.dart';

abstract interface class NextPhoneMicrophone {
  Stream<bool> get interruptions;
  Future<void> start(void Function(Uint8List) onSamples, void Function() onFailure);
  Future<void> stop();
}

class PhoneCaptureDenied implements Exception {}

class FlutterPhoneMicrophone implements NextPhoneMicrophone {
  FlutterPhoneMicrophone({
    @visibleForTesting Future<bool> Function()? requestPermission,
    @visibleForTesting FlutterSoundRecorder Function()? makeRecorder,
    @visibleForTesting Future<void> Function(AudioSessionConfiguration)? configureSession,
    @visibleForTesting bool? isIOS,
  }) : _requestPermission = requestPermission ?? (() async => Permission.microphone.request().isGranted),
       _makeRecorder = makeRecorder ?? FlutterSoundRecorder.new,
       _configureSession = configureSession ?? _configureAudioSession,
       _isIOS = isIOS ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  final Future<bool> Function() _requestPermission;
  final FlutterSoundRecorder Function() _makeRecorder;
  final Future<void> Function(AudioSessionConfiguration) _configureSession;
  final bool _isIOS;
  FlutterSoundRecorder? _recorder;
  StreamController<Uint8List>? _samples;

  static Future<void> _configureAudioSession(AudioSessionConfiguration configuration) async {
    final session = await AudioSession.instance;
    await session.configure(configuration);
  }

  @override
  Stream<bool> get interruptions async* {
    final session = await AudioSession.instance;
    yield* session.interruptionEventStream
        .where((event) => event.type != AudioInterruptionType.duck)
        .map((event) => event.begin);
  }

  @override
  Future<void> start(void Function(Uint8List) onSamples, void Function() onFailure) async {
    if (!await _requestPermission()) throw PhoneCaptureDenied();
    final recorder = _recorder = _makeRecorder();
    await recorder.openRecorder();
    final samples = _samples = StreamController<Uint8List>(sync: true);
    samples.stream.listen(onSamples, onError: (Object _) => onFailure());
    await recorder.startRecorder(
      codec: Codec.pcm16,
      sampleRate: 16000,
      numChannels: 1,
      bufferSize: 2048,
      toStream: samples.sink,
    );
  }

  @override
  Future<void> stop() async {
    final recorder = _recorder;
    final samples = _samples;
    _recorder = null;
    _samples = null;
    try {
      if (recorder != null) {
        await recorder.closeRecorder();
        if (_isIOS) {
          // Flutter Sound leaves its recording category active after close.
          // The playback category lets iOS choose the speaker or connected output.
          await _configureSession(
            const AudioSessionConfiguration(avAudioSessionCategory: AVAudioSessionCategory.playback),
          );
        }
      }
    } finally {
      await samples?.close();
    }
  }
}

enum CaptureProblem { permission, microphone, storage, empty, micStalled }

enum PhoneMicStatus { waiting, recording, interrupted, recovering }

class NextPhoneCapture extends ChangeNotifier {
  NextPhoneCapture(this.journal, this.owner, this.microphone, {this.preview, this.makeTimer = Timer.new});

  final LocalAudioJournal journal;
  final String owner;
  final NextPhoneMicrophone microphone;
  final NextLivePreview? preview;
  final Timer Function(Duration, void Function()) makeTimer;
  PhoneMicStatus? micStatus;
  Timer? _watchdog;
  StreamSubscription<bool>? _interruptions;
  Future<void>? _restarting;
  int _recorderGeneration = 0;
  bool _stopRequested = false;
  bool _triedRestart = false;
  LocalAudioRecording? _recording;
  DateTime? startedAt;
  CaptureProblem? problem;
  bool busy = false;
  bool _writeFailed = false;
  Future<void>? _starting;
  Future<void>? _stopping;
  bool get active => _recording != null;

  Future<void> start() => _starting ??= _start().whenComplete(() {
    _starting = null;
    rearmWatchdog();
  });

  void rearmWatchdog() {
    if (_recording case final current? when _acceptsAudio(current)) _watchFrames(current);
  }

  Future<void> _start() async {
    if (active || busy) return;
    busy = true;
    problem = null;
    _writeFailed = false;
    _stopRequested = false;
    _triedRestart = false;
    micStatus = PhoneMicStatus.waiting;
    startedAt = journal.clock();
    final current = _recording = journal.beginForServer(source: 'phone', codec: 'pcm16', serverId: owner);
    notifyListeners();
    try {
      _interruptions = microphone.interruptions.listen(
        (began) => _handleInterruption(current, began),
        // Frame liveness still detects a stall if interruption events are unavailable.
        onError: (Object _) {},
      );
      await _startRecorder(current);
      if (_acceptsAudio(current)) {
        preview?.begin(current.recordingId, current.source, current.codec);
      }
    } catch (error) {
      if (micStatus != PhoneMicStatus.interrupted || error is PhoneCaptureDenied) {
        _fail(current, error is PhoneCaptureDenied ? CaptureProblem.permission : CaptureProblem.microphone);
      }
    } finally {
      busy = _stopping != null;
      notifyListeners();
    }
  }

  bool _acceptsAudio(LocalAudioRecording current) => _recording == current && !_stopRequested && !_writeFailed;

  Future<void> _startRecorder(LocalAudioRecording current) {
    final generation = ++_recorderGeneration;
    return microphone.start(
      (bytes) {
        if (_recorderGeneration == generation) _write(current, bytes);
      },
      () {
        if (_recorderGeneration == generation && micStatus != PhoneMicStatus.interrupted) {
          // A plugin can report an error while startRecorder is still resolving.
          scheduleMicrotask(() async {
            await _starting;
            if (_recorderGeneration == generation) _recover(current, CaptureProblem.microphone);
          });
        }
      },
    );
  }

  void _handleInterruption(LocalAudioRecording current, bool began) {
    if (!_acceptsAudio(current)) return;
    if (began) {
      _watchdog?.cancel();
      _triedRestart = false;
      _showStatus(PhoneMicStatus.interrupted);
    } else if (micStatus == PhoneMicStatus.interrupted) {
      // Some audio routes restart automatically. Give them a chance to deliver PCM.
      _showStatus(PhoneMicStatus.recovering);
      _watchFrames(current);
    }
  }

  void _showStatus(PhoneMicStatus next) {
    if (micStatus == next) return;
    micStatus = next;
    notifyListeners();
  }

  void _watchFrames(LocalAudioRecording current) {
    if (!_acceptsAudio(current) ||
        _starting != null ||
        _restarting != null ||
        micStatus == PhoneMicStatus.interrupted) {
      return;
    }
    _watchdog?.cancel();
    _watchdog = makeTimer(const Duration(seconds: 4), () => _recover(current, CaptureProblem.micStalled));
  }

  void _recover(LocalAudioRecording current, CaptureProblem reason) {
    if (!_acceptsAudio(current) || micStatus == PhoneMicStatus.interrupted || _restarting != null) return;
    if (_triedRestart) {
      _fail(current, reason);
      return;
    }
    _triedRestart = true;
    ++_recorderGeneration;
    _watchdog?.cancel();
    _restarting = _reopen(current, reason).whenComplete(() {
      _restarting = null;
      if (_acceptsAudio(current) && micStatus != PhoneMicStatus.interrupted) _watchFrames(current);
    });
    _showStatus(PhoneMicStatus.recovering);
  }

  Future<void> _reopen(LocalAudioRecording current, CaptureProblem reason) async {
    try {
      await microphone.stop();
      if (_acceptsAudio(current) && micStatus != PhoneMicStatus.interrupted) await _startRecorder(current);
    } catch (_) {
      if (_acceptsAudio(current) && micStatus != PhoneMicStatus.interrupted) _fail(current, reason);
    }
  }

  void _write(LocalAudioRecording current, Uint8List bytes) {
    if (!_acceptsAudio(current) || micStatus == PhoneMicStatus.interrupted || bytes.isEmpty) return;
    if (bytes.length.isOdd) {
      _fail(current, CaptureProblem.microphone);
      return;
    }
    _triedRestart = false;
    for (int offset = 0; offset < bytes.length; offset += LocalAudioJournal.maxFrameBytes) {
      final end = math.min(offset + LocalAudioJournal.maxFrameBytes, bytes.length);
      final view = Uint8List.sublistView(bytes, offset, end);
      final activePreview = preview;
      final frame = activePreview == null ? view : Uint8List.fromList(view);
      // add() snapshots and counts bytes synchronously before its serialized disk flush.
      unawaited(
        current
            .add(
              frame,
              afterPersisted: activePreview == null
                  ? null
                  : () => activePreview.addPersisted(
                      current.recordingId,
                      current.source,
                      current.codec,
                      frame,
                      startSeconds:
                          current.audioSeconds - LocalAudioRecording.packetMicroseconds(current.codec, frame) / 1000000,
                    ),
            )
            .catchError((Object _) => _fail(current, CaptureProblem.storage)),
      );
    }
    _showStatus(PhoneMicStatus.recording);
    _watchFrames(current);
  }

  void _fail(LocalAudioRecording current, CaptureProblem reason) {
    if (_recording != current || _writeFailed) return;
    _writeFailed = true;
    _watchdog?.cancel();
    problem = reason;
    // A recorder can report a failure from inside start() before it has returned.
    scheduleMicrotask(stop);
  }

  Future<void> stop() => _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void> _stop() async {
    _stopRequested = true;
    ++_recorderGeneration;
    _watchdog?.cancel();
    final previewRecording = _recording;
    if (previewRecording != null) preview?.end(previewRecording.recordingId);
    await _starting;
    await _restarting;
    unawaited(_interruptions?.cancel().catchError((Object _) {}));
    _interruptions = null;
    final current = _recording;
    if (current == null) return;
    busy = true;
    notifyListeners();
    try {
      await microphone.stop();
    } catch (_) {
      problem ??= CaptureProblem.microphone;
    } finally {
      try {
        await current.stop();
        if (current.audioSeconds == 0) problem ??= CaptureProblem.empty;
      } catch (_) {
        problem = CaptureProblem.storage;
      }
      _recording = null;
      startedAt = null;
      micStatus = null;
      busy = false;
      notifyListeners();
    }
  }
}
