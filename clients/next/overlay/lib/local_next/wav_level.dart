import 'dart:math' as math;
import 'dart:typed_data';

/// The paired server delivers mono 16 kHz, 16-bit PCM. Bound the read even
/// when the selected archive entry is a multi-hour WAV.
const gainSampleBytes = 10 * 16000 * 2;
const gainHeaderLimit = 65536;

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
        var energy = 0.0;
        var maximum = 0;
        var atLimit = 0;
        for (var pos = at; pos < at + take; pos += 2) {
          final value = data.getInt16(pos, Endian.little);
          maximum = math.max(maximum, value.abs());
          energy += value * value;
          if (value == -32768 || value == 32767) atLimit++;
        }
        final count = take ~/ 2;
        double db(double amplitude) => 20 * math.log(amplitude / 32768) / math.ln10;
        return WavLevel(count / 16000, db(math.sqrt(energy / count)), db(maximum.toDouble()), atLimit);
      }
      at += length + (length.isOdd ? 1 : 0);
    }
    invalid();
  }
}
