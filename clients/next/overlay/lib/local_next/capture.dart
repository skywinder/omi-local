import 'dart:async';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/services/capture/local_audio_journal.dart';

import 'live_preview.dart';

abstract interface class NextPhoneMicrophone {
  Stream<bool> get interruptions;
  Future<void> start(void Function(Uint8List) onSamples, void Function() onFailure);
  Future<void> stop({bool reopening = false});
}

class PhoneCaptureDenied implements Exception {}

class FlutterPhoneMicrophone implements NextPhoneMicrophone {
  FlutterPhoneMicrophone({
    @visibleForTesting Future<bool> Function()? requestPermission,
    @visibleForTesting FlutterSoundRecorder Function()? makeRecorder,
    @visibleForTesting Future<void> Function(AudioSessionConfiguration)? configureSession,
    @visibleForTesting bool? isIOS,
    @visibleForTesting bool? isAndroid,
  }) : _requestPermission = requestPermission ?? (() async => Permission.microphone.request().isGranted),
       _makeRecorder = makeRecorder ?? FlutterSoundRecorder.new,
       _configureSession = configureSession ?? _configureAudioSession,
       _isIOS = isIOS ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS),
       _isAndroid = isAndroid ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final Future<bool> Function() _requestPermission;
  final FlutterSoundRecorder Function() _makeRecorder;
  final Future<void> Function(AudioSessionConfiguration) _configureSession;
  final bool _isIOS;
  final bool _isAndroid;
  bool _foregroundService = false;
  bool _needsPlaybackSession = false;
  static const _background = MethodChannel('org.omilocal.next/capture');
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
    if (_isAndroid && !_foregroundService) {
      await _background.invokeMethod<void>('startPhone');
      _foregroundService = true;
    }
    final recorder = _recorder = _makeRecorder();
    _needsPlaybackSession = _isIOS;
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
  Future<void> stop({bool reopening = false}) async {
    final recorder = _recorder;
    final samples = _samples;
    _recorder = null;
    _samples = null;
    try {
      await recorder?.closeRecorder();
      if (_needsPlaybackSession && !reopening) {
        // Flutter Sound leaves its recording category active after close.
        await _configureSession(
          const AudioSessionConfiguration(avAudioSessionCategory: AVAudioSessionCategory.playback),
        );
        _needsPlaybackSession = false;
      }
    } finally {
      try {
        await samples?.close();
      } finally {
        if (!reopening && _foregroundService) {
          _foregroundService = false;
          await _background.invokeMethod<void>('stopPhone');
        }
      }
    }
  }
}

enum CaptureProblem { permission, microphone, storage, empty, micStalled }

enum PhoneMicStatus { waiting, recording, interrupted, recovering }

class NextPhoneCapture extends ChangeNotifier {
  NextPhoneCapture(
    this.journal,
    this.owner,
    this.microphone, {
    this.preview,
    this.makeTimer = Timer.new,
    this.preferences,
  });

  final LocalAudioJournal journal;
  final String owner;
  final NextPhoneMicrophone microphone;
  final NextLivePreview? preview;
  final SharedPreferences? preferences;
  String get _resumeKey => 'next.phone.resume.$owner';
  bool get resumeRequested => preferences?.getBool(_resumeKey) ?? false;
  final Timer Function(Duration, void Function()) makeTimer;
  PhoneMicStatus? micStatus;
  Timer? _watchdog;
  StreamSubscription<bool>? _interruptions;
  Future<void>? _restarting;
  int _recorderGeneration = 0;
  bool _stopRequested = false;
  int _recoveryAttempts = 0;
  LocalAudioRecording? _recording;
  DateTime? startedAt;
  CaptureProblem? problem;
  bool busy = false;
  bool _writeFailed = false;
  Future<void>? _starting;
  Future<void>? _stopping;
  bool get active => _recording != null;
  bool get hasSavedAudio => (_recording?.audioSeconds ?? 0) > 0;
  int? get silenceSeconds => _recording?.silenceSeconds;

  Future<void> start() => _starting ??= _start().whenComplete(() {
    _starting = null;
    rearmWatchdog();
  });

  void rearmWatchdog() {
    if (_recording case final current? when _acceptsAudio(current)) _watchFrames(current);
  }

  void foregrounded() {
    if (micStatus == PhoneMicStatus.interrupted) _showStatus(PhoneMicStatus.recovering);
    rearmWatchdog();
  }

  Future<void> _start() async {
    if (active || busy || _stopping != null) return;
    busy = true;
    problem = null;
    _writeFailed = false;
    _stopRequested = false;
    _recoveryAttempts = 0;
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
        await _saveResume(true);
        if (!_acceptsAudio(current)) return;
        _beginPreview(current);
      }
    } on PhoneCaptureDenied {
      _fail(current, CaptureProblem.permission);
    } catch (_) {
      if (_acceptsAudio(current) && micStatus != PhoneMicStatus.interrupted) {
        _showStatus(PhoneMicStatus.recovering);
      }
    } finally {
      busy = _stopping != null;
      notifyListeners();
    }
  }

  Future<void> _saveResume(bool requested) async {
    try {
      await preferences?.setBool(_resumeKey, requested);
    } catch (_) {
      // Capture and its journal can continue if preferences are unavailable.
    }
  }

  void _beginPreview(LocalAudioRecording current) {
    preview?.begin(current.recordingId, current.source, current.codec, silenceSeconds: current.silenceSeconds);
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
            if (_recorderGeneration == generation) _recover(current);
          });
        }
      },
    );
  }

  void _handleInterruption(LocalAudioRecording current, bool began) {
    if (!_acceptsAudio(current)) return;
    if (began) {
      _watchdog?.cancel();
      _recoveryAttempts = 0;
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
    final delay = Duration(seconds: 4 << _recoveryAttempts.clamp(0, 3));
    _watchdog = makeTimer(delay, () => _recover(current));
  }

  void _recover(LocalAudioRecording current) {
    if (!_acceptsAudio(current) || micStatus == PhoneMicStatus.interrupted || _restarting != null) return;
    _recoveryAttempts++;
    ++_recorderGeneration;
    _watchdog?.cancel();
    _restarting = _reopen(current).whenComplete(() {
      _restarting = null;
      _watchFrames(current);
    });
    _showStatus(PhoneMicStatus.recovering);
  }

  Future<void> _reopen(LocalAudioRecording current) async {
    try {
      await microphone.stop(reopening: true);
      if (!_acceptsAudio(current) || micStatus == PhoneMicStatus.interrupted) return;
      await _startRecorder(current);
      if (_acceptsAudio(current)) {
        await _saveResume(true);
        if (_acceptsAudio(current)) _beginPreview(current);
      }
    } on PhoneCaptureDenied {
      _fail(current, CaptureProblem.permission);
    } catch (_) {
      // The OS may still hold the audio route. The watchdog backs off and retries.
    }
  }

  void _write(LocalAudioRecording current, Uint8List bytes) {
    if (!_acceptsAudio(current) || micStatus == PhoneMicStatus.interrupted || bytes.isEmpty) return;
    if (bytes.length.isOdd) {
      _recover(current);
      return;
    }
    _recoveryAttempts = 0;
    final batchEnd = journal.clock().difference(startedAt!).inMicroseconds / Duration.microsecondsPerSecond;
    for (int offset = 0; offset < bytes.length; offset += LocalAudioJournal.maxFrameBytes) {
      final end = math.min(offset + LocalAudioJournal.maxFrameBytes, bytes.length);
      final view = Uint8List.sublistView(bytes, offset, end);
      final activePreview = preview;
      final firstAudio = !hasSavedAudio;
      final frame = activePreview == null ? view : Uint8List.fromList(view);
      // add() snapshots and counts bytes synchronously before its serialized disk flush.
      unawaited(
        current
            .add(
              frame,
              afterPersisted: () {
                activePreview?.addPersisted(
                  current.recordingId,
                  current.source,
                  current.codec,
                  frame,
                  startSeconds: math.max(
                    0,
                    current.audioSeconds - LocalAudioRecording.packetMicroseconds(current.codec, frame) / 1000000,
                  ),
                  elapsedSeconds: batchEnd - (bytes.length - offset) / 32000,
                );
                if (firstAudio && _acceptsAudio(current)) notifyListeners();
              },
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
    scheduleMicrotask(close);
  }

  Future<void> stop() {
    final sealed = close();
    return Future.wait([sealed, _saveResume(false)]);
  }

  Future<void> close() => _stopping ??= _stop().whenComplete(() => _stopping = null);

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
