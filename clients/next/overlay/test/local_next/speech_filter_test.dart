import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/speech_filter.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

class _Scorer implements NextSpeechScorer {
  @override
  Future<double> score(Uint8List packet) async => packet.first / 255;
  @override
  Future<double> finish() async => 0;
  @override
  Future<void> close() async {}
}

void main() {
  test('silent drafts stay offline; uncertainty survives a restart and speech needs an exact receipt', () async {
    final dir = await Directory.systemTemp.createTemp('speech-outbox');
    addTearDown(() => dir.delete(recursive: true));
    bool uncertain = false, accept = false;
    final sent = <String>[];
    LocalAudioJournal journal() => LocalAudioJournal(
      directory: dir,
      speechMode: () => true,
      groupSilence: () => 15,
      filterSpeech: (codec, packets, preroll, pause) async {
        if (uncertain) throw StateError('Model unavailable');
        return SpeechActivity.intervals(codec, packets, preroll, pause, open: (_) async => _Scorer());
      },
      upload: (body, _) async {
        final size = ByteData.sublistView(body, 8, 12).getUint32(0);
        final header = jsonDecode(utf8.decode(body.sublist(12, 12 + size)));
        expect(header.containsKey('speech_review'), isFalse);
        sent.add(header['id'] as String);
        return {'stored': true, 'id': header['id'], 'sha256': accept ? sha256.convert(body).toString() : ''};
      },
    );
    var outbox = journal();
    await outbox.initialize();
    Future<void> record(int value) async {
      final capture = outbox.beginForServer(source: 'phone', codec: 'pcm16', serverId: 'owner');
      await capture.add(Uint8List(2048)..[0] = value);
      await capture.stop();
      await outbox.drain();
    }

    await record(0);
    expect(sent, isEmpty);
    expect(outbox.pendingParts, 0);
    uncertain = true;
    await record(200);
    expect(outbox.deliveryIssues, contains(LocalDeliveryIssue.speechReview));
    expect(outbox.pendingParts, 1);
    expect(sent, isEmpty);
    outbox.dispose();
    outbox = journal();
    await outbox.initialize();
    uncertain = false;
    await outbox.drain();
    expect(sent, isNotEmpty);
    expect(outbox.pendingParts, 1);
    expect(outbox.deliveryIssues, contains(LocalDeliveryIssue.receipt));
    accept = true;
    await outbox.drain();
    expect(sent.toSet(), hasLength(1));
    expect(outbox.pendingParts, 0);
    outbox.dispose();
  });

  test('Live opens on speech, includes onset and tail, then stops forwarding silence', () async {
    final emitted = <double>[];
    final boundary = Completer<void>();
    final gate = SpeechPreviewGate(
      'pcm16',
      2,
      (f) => emitted.add(f.start),
      () {},
      boundary.complete,
      (_) async => _Scorer(),
    );
    for (var i = 0; i < 40; i++) {
      gate.add((bytes: Uint8List(3200)..[0] = i == 10 ? 230 : 0, start: i / 10, elapsed: i / 10));
    }
    await boundary.future;
    expect(emitted.first, .7);
    expect(emitted, contains(1.0));
    expect(emitted.last, lessThan(1.7));
    gate.close();
  });
}
