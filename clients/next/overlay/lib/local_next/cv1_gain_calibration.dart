import 'dart:typed_data';

import 'package:omi/services/capture/cv1_opus_frame_assembler.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

import 'wav_level.dart';

abstract interface class Cv1GainDecoder {
  Int16List decode(Uint8List packet);
  void close();
}

class _OpusGainDecoder implements Cv1GainDecoder {
  final _decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);

  @override
  Int16List decode(Uint8List packet) => _decoder.decode(input: packet);

  @override
  void close() => _decoder.destroy();
}

// opus_dart initializes its process-wide bindings once. Each test still owns
// a fresh decoder so earlier measurements cannot affect its audio state.
final _opusReady = _loadOpus();

Future<void> _loadOpus() async {
  initOpus(await opus_flutter.load());
}

Future<Cv1GainDecoder> openCv1GainDecoder() async {
  await _opusReady;
  return _OpusGainDecoder();
}

enum Cv1GainAdvice { noAudio, noSpeechAudio, limitedAudio, noRoomBaseline, overload, masked, low, usable }

/// Holds only sample statistics from the same CV1 Opus packets used by capture.
class Cv1GainCalibration {
  Cv1GainCalibration(this._decoder);

  final Cv1GainDecoder _decoder;
  final _frames = Cv1OpusFrameAssembler();
  final _room = PcmLevelMeter();
  final _speech = PcmLevelMeter();
  var _recent = PcmLevelMeter();
  bool settling = true;
  bool speaking = false;
  WavLevel get room => _room.level;
  WavLevel get speech => _speech.level;

  static double? speechAboveRoom(WavLevel room, WavLevel speech) {
    if (room.seconds < 1.5 || speech.seconds < 4 || !room.rms.isFinite || !speech.rms.isFinite) return null;
    return speech.rms - room.rms;
  }

  WavLevel takeRecent() {
    final reading = _recent.level;
    _recent = PcmLevelMeter();
    return reading;
  }

  bool accept(Uint8List raw) {
    final packet = _frames.add(raw);
    if (packet == null) return false;
    final samples = _decoder.decode(packet);
    if (settling) return samples.isNotEmpty;
    final meter = speaking ? _speech : _room;
    for (final sample in samples) {
      meter.add(sample);
      _recent.add(sample);
    }
    return samples.isNotEmpty;
  }

  Cv1GainAdvice get advice {
    final spoken = speech;
    final background = room;
    if (spoken.seconds == 0 && background.seconds == 0) return Cv1GainAdvice.noAudio;
    if (spoken.seconds == 0) return Cv1GainAdvice.noSpeechAudio;
    if (spoken.peak >= -1 || spoken.atLimit > 0) return Cv1GainAdvice.overload;
    if (spoken.seconds < 4) return Cv1GainAdvice.limitedAudio;
    if (background.seconds < 1.5) return Cv1GainAdvice.noRoomBaseline;
    if (!spoken.rms.isFinite || spoken.rms - background.rms < 8) return Cv1GainAdvice.masked;
    if (spoken.peak < -25) return Cv1GainAdvice.low;
    return Cv1GainAdvice.usable;
  }

  void close() => _decoder.close();
}
