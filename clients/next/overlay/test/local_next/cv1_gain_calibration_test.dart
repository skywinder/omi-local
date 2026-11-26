import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/cv1_gain_calibration.dart';

class _Decoder implements Cv1GainDecoder {
  @override
  Int16List decode(Uint8List packet) => Int16List.fromList(
    List.filled(320, switch (packet.single) {
      0 => 32,
      1 => 512,
      2 => 4096,
      _ => 32767,
    }),
  );

  @override
  void close() {}
}

Cv1GainCalibration _measure({int room = 100, int speech = 250, int level = 1}) {
  final calibration = Cv1GainCalibration(_Decoder())..settling = false;
  var counter = 0;
  void send(int frames, int amplitude) {
    for (var i = 0; i < frames; i++) {
      calibration.accept(Uint8List.fromList([counter & 0xff, counter >> 8, 0, amplitude]));
      counter++;
    }
  }

  if (room > 0) send(room + 1, 0);
  calibration.speaking = true;
  if (speech > 0) {
    // After a gap the first notification begins a new Opus packet.
    counter++;
    send(speech + 1, level);
  }
  addTearDown(calibration.close);
  return calibration;
}

void main() {
  test('no audio, missing speech audio and a quiet phrase lead to different gain guidance', () {
    expect(_measure(room: 0, speech: 0).advice, Cv1GainAdvice.noAudio);
    final asleep = _measure(speech: 0);
    expect(asleep.room.seconds, 2);
    expect(asleep.speech.seconds, 0);
    expect(asleep.advice, Cv1GainAdvice.noSpeechAudio);
    final quiet = _measure();
    expect(quiet.speech.seconds, 5);
    expect(quiet.speech.peak, closeTo(-36.12, 0.01));
    expect(quiet.advice, Cv1GainAdvice.low);
    expect(_measure(level: 2).advice, Cv1GainAdvice.usable);
  });

  test('a missing background blocks gain increases, but even a short clipped phrase is actionable', () {
    expect(_measure(room: 0).advice, Cv1GainAdvice.noRoomBaseline);
    expect(_measure(speech: 50).advice, Cv1GainAdvice.limitedAudio);
    expect(_measure(room: 0, speech: 25, level: 3).advice, Cv1GainAdvice.overload);
    expect(_measure(level: 0).advice, Cv1GainAdvice.masked);
  });
}
