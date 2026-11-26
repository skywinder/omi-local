import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/wav_level.dart';

Uint8List wav(List<int> samples) {
  final data = ByteData(44 + samples.length * 2);
  final b = data.buffer.asUint8List();
  b.setRange(0, 4, 'RIFF'.codeUnits);
  data.setUint32(4, b.length - 8, Endian.little);
  b.setRange(8, 16, 'WAVEfmt '.codeUnits);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  b.setRange(36, 40, 'data'.codeUnits);
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return b;
}

void main() {
  test('known PCM reference, both full-scale rails and digital silence', () {
    final reference = WavLevel.measure(wav([16384, -16384, 0, 0]));
    expect(reference.peak, closeTo(-6.02, 0.01));
    expect(reference.rms, closeTo(-9.03, 0.01));
    expect(reference.atLimit, 0);
    expect(WavLevel.measure(wav([-32768, 32767])).atLimit, 2);
    expect(WavLevel.measure(wav([0])).rms, double.negativeInfinity);
  });
  test('first ten seconds are comparable and malformed WAV is rejected', () {
    final file = wav([...List.filled(160000, 0), 32767]);
    expect(WavLevel.measure(file).seconds, 10);
    expect(WavLevel.measure(file).atLimit, 0);
    expect(() => WavLevel.measure(file.sublist(0, 46)), throwsFormatException);
    file[20] = 3;
    expect(() => WavLevel.measure(file), throwsFormatException);
  });
}
