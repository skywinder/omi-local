import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/capture.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

class TestMic implements NextPhoneMicrophone {
  void Function(Uint8List)? samples;
  bool denied = false;
  final stopped = Completer<void>();

  @override
  Future<void> start(void Function(Uint8List) onSamples, void Function() onFailure) async {
    if (denied) throw PhoneCaptureDenied();
    samples = onSamples;
  }

  @override
  Future<void> stop() async {
    samples = null;
    stopped.complete();
  }
}

void main() {
  test('PCM from microphone survives bad receipt and process restart until its exact part is acknowledged', () async {
    final scratch = await Directory.systemTemp.createTemp();
    addTearDown(() => scratch.delete(recursive: true));
    final id = LocalAudioJournal.serverIdentity('http://127.0.0.1:8080', 'synthetic');
    final journal = LocalAudioJournal(directory: scratch, upload: (body, owner) async => {'stored': true});
    await journal.initialize();
    final mic = TestMic();
    final capture = NextPhoneCapture(journal, id, mic);
    await capture.start();
    expect(capture.active, isTrue);
    final pcm = Uint8List.fromList(List.generate(6000, (i) => i % 250));
    mic.samples!(pcm);
    await capture.stop();
    await journal.drain();
    expect(capture.problem, isNull);
    final saved = scratch.listSync().whereType<File>().single;
    expect(saved.path, endsWith('.ready'));
    final durable = await saved.readAsBytes();
    capture.dispose();
    journal.dispose();

    final delivered = <Uint8List>[];
    final restarted = LocalAudioJournal(
      directory: scratch,
      upload: (body, owner) async {
        expect(owner, id);
        delivered.add(body);
        final fields = ByteData.sublistView(body);
        final end = 12 + fields.getUint32(8);
        final header = jsonDecode(utf8.decode(body.sublist(12, end)));
        expect(header['source'], 'phone');
        expect(header['codec'], 'pcm16');
        final decoded = <int>[];
        for (int offset = end; offset < body.length;) {
          final length = fields.getUint32(offset);
          offset += 4;
          decoded.addAll(body.sublist(offset, offset + length));
          offset += length;
        }
        expect(decoded, pcm);
        return {'stored': true, 'id': header['id'], 'sha256': sha256.convert(body).toString()};
      },
    );
    await restarted.initialize();
    await restarted.drain();
    expect(delivered.single, durable);
    expect(scratch.listSync(), isEmpty);
    restarted.dispose();
  });

  test('denied microphone access publishes no audio and exits recording', () async {
    final scratch = await Directory.systemTemp.createTemp();
    addTearDown(() => scratch.delete(recursive: true));
    final journal = LocalAudioJournal(
      directory: scratch,
      upload: (body, owner) async => throw StateError('unexpected upload'),
    );
    await journal.initialize();
    final mic = TestMic()..denied = true;
    final capture = NextPhoneCapture(journal, 'synthetic', mic);
    await capture.start();
    await capture.stop();
    expect(capture.active, isFalse);
    expect(capture.problem, CaptureProblem.permission);
    expect(scratch.listSync(), isEmpty);
    capture.dispose();
    journal.dispose();
  });
}
