import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/capture/cv1_opus_frame_assembler.dart';

Uint8List notification(int counter, int fragment, List<int> payload) =>
    Uint8List.fromList([counter & 0xff, counter >> 8, fragment, ...payload]);

void main() {
  test('MTU 23 splits an 18-byte Opus packet into 17 + 1 bytes, including across counter wrap', () {
    // A 20 ms Opus silence packet padded to 18 bytes by libopus.
    final opus = [0xfb, 0x41, 0x0d, 0xff, 0xfe, ...List.filled(13, 0)];
    final frames = Cv1OpusFrameAssembler();
    final first = notification(0xffff, 0, opus.sublist(0, 17));
    expect(frames.add(first), isNull);
    first.fillRange(3, first.length, 0); // Native may reuse the input buffer.
    expect(frames.add(notification(0, 1, opus.sublist(17))), isNull);
    expect(frames.add(notification(1, 0, [0x78, 1])), opus);
    expect(frames.add(notification(2, 0, [0x78, 2])), [0x78, 1]);
    expect(frames.discardedCandidates, 0);
  });

  test('a missing BLE notification or fragment invalidates the whole candidate and resumes at fragment zero', () {
    final frames = Cv1OpusFrameAssembler();
    expect(frames.add(notification(30, 2, [1])), isNull); // Joined mid-frame.
    expect(frames.add(notification(31, 0, [2])), isNull);
    expect(frames.add(notification(33, 0, [3])), isNull); // Counter gap at a start.
    expect(frames.add(notification(34, 2, [4])), isNull); // Missing fragment 1.
    expect(frames.add(notification(35, 3, [5])), isNull);
    expect(frames.add(notification(36, 0, [6])), isNull);
    expect(frames.add(notification(37, 0, [7])), [6]);
    expect(frames.discardedCandidates, 2);
  });

  test('stop or disconnect reports the unconfirmed tail and prevents stitching across sessions', () {
    final frames = Cv1OpusFrameAssembler();
    expect(frames.add(notification(7, 0, [1, 2])), isNull);
    expect(frames.add(notification(8, 1, [3])), isNull);
    expect(frames.discardPending(), 3);
    expect(frames.discardPending(), 0);
    expect(frames.add(notification(9, 2, [4])), isNull);
    expect(frames.add(notification(10, 0, [5])), isNull);
    expect(frames.add(notification(11, 0, [6])), [5]);
    expect(frames.discardPending(), 1); // Even a single notification lacks an end marker.
    expect(frames.discardedCandidates, 2);
  });

  test('malformed and overlong packets cannot commit a partial frame or poison the next one', () {
    final frames = Cv1OpusFrameAssembler();
    expect(frames.add(notification(0, 0, [1])), isNull);
    expect(frames.add(notification(1, 0, [])), isNull);
    expect(frames.add(notification(2, 0, List.filled(160, 2))), isNull);
    expect(frames.add(notification(3, 1, [3])), isNull);
    expect(frames.add(notification(4, 0, [4])), isNull);
    expect(frames.add(notification(5, 0, List.filled(161, 5))), isNull);
    expect(frames.add(notification(6, 0, [6])), isNull);
    expect(frames.add(notification(7, 0, [7])), [6]);
    expect(frames.discardedCandidates, 3);
  });
}
