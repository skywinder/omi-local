import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:omi/services/capture/local_audio_journal.dart';

import 'live_preview.dart';

abstract interface class NextPhoneMicrophone {
  Future<void> start(void Function(Uint8List) onSamples, void Function() onFailure);
  Future<void> stop();
}

class PhoneCaptureDenied implements Exception {}

class FlutterPhoneMicrophone implements NextPhoneMicrophone {
  FlutterSoundRecorder? _recorder;
  StreamController<Uint8List>? _samples;

  @override
  Future<void> start(void Function(Uint8List) onSamples, void Function() onFailure) async {
    if (!await Permission.microphone.request().isGranted) throw PhoneCaptureDenied();
    final recorder = _recorder = FlutterSoundRecorder();
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
      if (recorder != null) await recorder.closeRecorder();
    } finally {
      await samples?.close();
    }
  }
}

enum CaptureProblem { permission, microphone, storage, empty }

class NextPhoneCapture extends ChangeNotifier {
  NextPhoneCapture(this.journal, this.owner, this.microphone, {this.preview});

  final LocalAudioJournal journal;
  final String owner;
  final NextPhoneMicrophone microphone;
  final NextLivePreview? preview;
  LocalAudioRecording? _recording;
  CaptureProblem? problem;
  bool busy = false;
  bool _writeFailed = false;
  Future<void>? _starting;
  Future<void>? _stopping;
  bool get active => _recording != null;

  Future<void> start() => _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    if (active || busy) return;
    busy = true;
    problem = null;
    _writeFailed = false;
    final current = _recording = journal.beginForServer(source: 'phone', codec: 'pcm16', serverId: owner);
    notifyListeners();
    try {
      await microphone.start((bytes) => _write(current, bytes), () => _fail(current, CaptureProblem.microphone));
      if (_recording == current && !_writeFailed && _stopping == null) {
        preview?.begin(current.recordingId, current.source, current.codec);
      }
    } catch (error) {
      _fail(current, error is PhoneCaptureDenied ? CaptureProblem.permission : CaptureProblem.microphone);
    } finally {
      busy = _stopping != null;
      notifyListeners();
    }
  }

  void _write(LocalAudioRecording current, Uint8List bytes) {
    if (_recording != current || _writeFailed || bytes.isEmpty) return;
    if (bytes.length.isOdd) {
      _fail(current, CaptureProblem.microphone);
      return;
    }
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
  }

  void _fail(LocalAudioRecording current, CaptureProblem reason) {
    if (_recording != current || _writeFailed) return;
    _writeFailed = true;
    problem = reason;
    // A recorder can report a failure from inside start() before it has returned.
    scheduleMicrotask(stop);
  }

  Future<void> stop() => _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void> _stop() async {
    final previewRecording = _recording;
    if (previewRecording != null) preview?.end(previewRecording.recordingId);
    await _starting;
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
      busy = false;
      notifyListeners();
    }
  }
}
