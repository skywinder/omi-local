import 'dart:math' as math;
import 'dart:typed_data';

/// The paired server delivers mono 16 kHz, 16-bit PCM. Bound the read even
/// when the selected archive entry is a multi-hour WAV.
const gainSampleBytes = 10 * 16000 * 2;
const gainHeaderLimit = 65536;

class PcmLevelMeter {
  int _count = 0;
  double _energy = 0;
  int _maximum = 0;
  int _atLimit = 0;

  void add(int sample) {
    _count++;
    _maximum = math.max(_maximum, sample.abs());
    _energy += sample * sample;
    if (sample == -32768 || sample == 32767) _atLimit++;
  }

  WavLevel get level {
    double db(double amplitude) => 20 * math.log(amplitude / 32768) / math.ln10;
    return WavLevel(
      _count / 16000,
      db(_count == 0 ? 0 : math.sqrt(_energy / _count)),
      db(_maximum.toDouble()),
      _atLimit,
    );
  }
}

class WavLevel {
  const WavLevel(this.seconds, this.rms, this.peak, this.atLimit);
  final double seconds;
  final double rms;
  final double peak;
  final int atLimit;

  static WavLevel measure(Uint8List bytes) {
    Never invalid() => throw const FormatException('Unsupported calibration WAV');
    final data = ByteData.sublistView(bytes);
    String tag(int start) => String.fromCharCodes(bytes.sublist(start, start + 4));
    int u32(int start) => data.getUint32(start, Endian.little);
    int u16(int start) => data.getUint16(start, Endian.little);
    if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') invalid();
    var pcm = false;
    for (var at = 12; at + 8 <= bytes.length && at + 8 <= gainHeaderLimit;) {
      final chunk = tag(at);
      final length = u32(at + 4);
      at += 8;
      if (chunk == 'fmt ') {
        if (length < 16 || at + length > bytes.length) invalid();
        pcm = u16(at) == 1 && u16(at + 2) == 1 && u32(at + 4) == 16000 && u16(at + 12) == 2 && u16(at + 14) == 16;
      }
      if (chunk == 'data') {
        final take = math.min(length, gainSampleBytes);
        if (!pcm || take < 2 || take.isOdd || at + take > bytes.length) invalid();
        final meter = PcmLevelMeter();
        for (var pos = at; pos < at + take; pos += 2) {
          meter.add(data.getInt16(pos, Endian.little));
        }
        return meter.level;
      }
      at += length + (length.isOdd ? 1 : 0);
    }
    invalid();
  }
}
