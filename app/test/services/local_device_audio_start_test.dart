import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/capture/local_device_audio_start.dart';

void main() {
  test('late BLE subscription is cancelled after the session was discarded', () async {
    final audio = StreamController<List<int>>.broadcast(sync: true);
    final pending = Completer<StreamSubscription?>();
    final start = LocalDeviceAudioStart('synthetic');
    final attaching = start.attach(pending.future);
    start.receive([0, 0, 0, 1]);
    start.discard();
    pending.complete(audio.stream.listen(start.receive));
    expect(await attaching, isFalse);
    expect(audio.hasListener, isFalse);
    final sent = <List<int>>[];
    start.forwardTo(sent.add);
    expect(sent, isEmpty);
    await audio.close();
  });

  test('overflow fails the start rather than returning a truncated recording', () async {
    final start = LocalDeviceAudioStart('synthetic', maxBufferedBytes: 4);
    start.receive([0, 0, 0, 1]);
    start.receive([1, 0, 0, 2]);
    expect(start.inputStopped, isTrue);
    expect(() => start.forwardTo((_) => fail('No incomplete queue should be delivered')), throwsStateError);
    start.discard();
  });
}
