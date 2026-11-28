import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/cv1_capture.dart';
import 'package:omi/local_next/cv1_resume.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/local_next/live_preview.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

const _silence = [0xf8, 0xff, 0xfe];
final _padded = [0xfb, 0x41, 0x0d, 0xff, 0xfe, ...List.filled(13, 0)];

Cv1Audio _audio(int gen, int counter, int fragment, List<int> payload) =>
    Cv1Audio(gen, Uint8List.fromList([counter & 255, counter >> 8, fragment, ...payload]));

class _Delivered {
  _Delivered(this.header, this.frames);
  final Map<String, dynamic> header;
  final List<List<int>> frames;
}

class _Fixture {
  final uploads = <_Delivered>[];
  final owner = LocalAudioJournal.serverIdentity('http://127.0.0.1:8080', 'synthetic');
  late final LocalAudioJournal journal;
  late final NextCv1Capture capture;

  Future<void> open({
    Future<void> Function()? acquire,
    bool Function()? canStart,
    Future<RandomAccessFile> Function(File)? openJournal,
    NextLivePreview? preview,
    Cv1ResumeSettings? resumeSettings,
    int? Function()? groupSilence,
  }) async {
    final files = await Directory.systemTemp.createTemp();
    journal = LocalAudioJournal(
      directory: files,
      openJournal: openJournal,
      groupSilence: groupSilence,
      upload: (bytes, destination) async {
        expect(destination, owner);
        expect(bytes.take(8), LocalAudioJournal.magic);
        final data = ByteData.sublistView(bytes);
        final end = 12 + data.getUint32(8);
        final header = jsonDecode(utf8.decode(bytes.sublist(12, end))) as Map<String, dynamic>;
        expect(header['server_id'], owner);
        expect(header['source'], 'omi');
        final frames = <List<int>>[];
        for (var offset = end; offset < bytes.length;) {
          final size = data.getUint32(offset);
          offset += 4;
          frames.add(bytes.sublist(offset, offset + size));
          offset += size;
        }
        uploads.add(_Delivered(header, frames));
        return {'stored': true, 'id': header['id'], 'sha256': sha256.convert(bytes).toString()};
      },
    );
    await journal.initialize();
    capture = NextCv1Capture(
      journal,
      owner,
      canStart: canStart ?? () => true,
      onStartRequested: acquire,
      resumeSettings: resumeSettings,
      preview: preview,
    );
    addTearDown(() async {
      await capture.close();
      await journal.drain();
      capture.dispose();
      journal.dispose();
      await files.delete(recursive: true);
    });
  }
}

class _PreviewProbe extends NextLivePreview {
  _PreviewProbe(String owner)
    : super(owner, (owner, source, codec, {silence}) => throw StateError('No network in capture fixture'));

  String? active;
  final openings = <String>[];
  final frames = <List<int>>[];

  @override
  void begin(String recordingId, String source, String codec, {int? silenceSeconds, VoidCallback? onSilence}) {
    if (active == recordingId) return;
    active = recordingId;
    openings.add(recordingId);
  }

  @override
  void end(String recordingId) {
    if (active == recordingId) active = null;
  }

  @override
  void addPersisted(
    String recordingId,
    String source,
    String codec,
    Uint8List bytes, {
    required double startSeconds,
    double? elapsedSeconds,
  }) {
    expect(active, recordingId);
    frames.add(bytes);
  }
}

void main() {
  test('default CV1 reconnect restores explicit Stop and Mute across cold launches for one pairing', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    Future<NextCv1Capture> open(String owner, {bool available = true}) async {
      final fixture = _Fixture();
      await fixture.open(resumeSettings: Cv1ResumeSettings(prefs, owner), canStart: () => available);
      fixture.capture.handle(const Cv1LinkReady(1, 20));
      return fixture.capture;
    }

    final manual = await open('manual');
    expect(manual.resumeSettings!.enabled, isFalse);
    manual.start();
    await manual.close();
    final restored = await open('manual');
    expect(restored.wantsAudio, isTrue);
    expect(restored.resumeSettings!.enabled, isFalse);
    await restored.stop();
    expect((await open('manual')).active, isFalse);

    final first = await open('a');
    expect(first.active, isFalse);
    await first.resumeSettings!.save(Cv1ResumeMode.armed);
    first.handle(const Cv1LinkLost(1));
    first.handle(const Cv1LinkReady(2, 20));
    expect(first.wantsAudio, isTrue);
    await first.close();
    final resumed = await open('a');
    expect(resumed.wantsAudio, isTrue);
    resumed.toggleMute();
    await resumed.close();
    final muted = await open('a');
    expect(muted.intent, Cv1CaptureIntent.muted);
    expect(muted.wantsAudio, isFalse);
    muted.toggleMute();
    expect(muted.wantsAudio, isTrue);
    await muted.stop();
    final stopped = await open('a');
    expect(stopped.active, isFalse);
    stopped.start();
    await stopped.close();
    expect((await open('a', available: false)).active, isFalse);
    expect((await open('b')).active, isFalse);
    await prefs.setString('next.cv1.resume.c', 'off');
    expect((await open('c')).active, isFalse);
  });

  test('CV1 mute cuts only preview and fences pre-mute flush callbacks from the resumed socket', () async {
    final fixture = _Fixture();
    final preview = _PreviewProbe(fixture.owner);
    addTearDown(preview.dispose);
    await fixture.open(preview: preview);
    final capture = fixture.capture;
    capture.handle(const Cv1LinkReady(1, 21));
    capture.start();
    capture.handle(_audio(1, 0, 0, _silence));
    capture.handle(_audio(1, 1, 0, _padded));
    await fixture.journal.flushPendingWrites();
    expect(preview.frames, [_silence]);

    capture.handle(_audio(1, 2, 0, _silence)); // Confirms _padded before its disk flush completes.
    capture.toggleMute();
    expect(preview.active, isNull);
    capture.toggleMute();
    capture.handle(_audio(1, 8, 0, _silence));
    capture.handle(_audio(1, 9, 0, _padded));
    await fixture.journal.flushPendingWrites();
    expect(preview.openings, hasLength(2));
    expect(preview.openings.toSet(), hasLength(1));
    expect(preview.frames, [_silence, _silence]);
    await capture.stop();
    await fixture.journal.drain();
    final parts = fixture.uploads.toList()
      ..sort((a, b) => (a.header['index'] as int).compareTo(b.header['index'] as int));
    expect(parts.expand((part) => part.frames), [_silence, _padded, _silence]);
  });

  test('a grouped CV1 capture keeps its identity across a same-codec reconnect', () async {
    final f = _Fixture();
    await f.open(groupSilence: () => 15);
    f.capture.handle(const Cv1LinkReady(1, 20));
    f.capture.start();
    f.capture.handle(_audio(1, 1, 0, _silence));
    f.capture.handle(_audio(1, 2, 0, _silence));
    await f.journal.flushPendingWrites();
    f.capture.handle(const Cv1LinkLost(2));
    await f.journal.flushPendingWrites();
    await f.journal.drain();
    expect(f.capture.active, isTrue);
    expect(f.uploads.map((part) => part.header['kind']), ['audio']);
    f.capture.handle(const Cv1LinkReady(3, 20));
    f.capture.handle(_audio(1, 3, 0, _silence));
    f.capture.handle(_audio(3, 1, 0, _silence));
    f.capture.handle(_audio(3, 2, 0, _silence));
    await f.capture.stop();
    await f.journal.drain();
    expect(f.uploads.map((part) => part.header['kind']), ['audio', 'audio', 'finish']);
    final recordingId = f.uploads.first.header['recording_id'];
    expect(f.uploads.every((part) => part.header['recording_id'] == recordingId), isTrue);
    expect(f.uploads[1].header['first_sample'], 320);
    expect(f.uploads[1].header['preroll_frames'], 0);
  });

  test('Finish seals exactly one conversation and keeps the subscribed CV1 listening', () async {
    final f = _Fixture();
    await f.open(groupSilence: () => 15);
    final capture = f.capture;
    capture.handle(const Cv1LinkReady(1, 20));
    capture.start();
    capture.handle(_audio(1, 10, 0, _padded));
    capture.handle(_audio(1, 11, 0, _silence));
    await f.journal.flushPendingWrites();
    expect(capture.canFinish, isTrue);
    final first = capture.finishConversation();
    await capture.finishConversation();
    expect(capture.wantsAudio, isTrue);
    expect(capture.canFinish, isFalse);
    expect(capture.startedAt, isNull);
    capture.handle(_audio(1, 12, 0, _silence));
    capture.handle(_audio(1, 13, 0, _padded));
    await first;
    await f.journal.flushPendingWrites();
    expect(capture.startedAt, isNotNull);
    await capture.stop();
    await f.journal.drain();
    final parts = f.uploads.where((p) => p.header['kind'] == 'audio').toList();
    expect(parts.map((p) => p.frames), [
      [_padded],
      [_silence],
    ]);
    expect(parts.first.header['recording_id'], isNot(parts.last.header['recording_id']));
    final finished = f.uploads.where((p) => p.header['kind'] == 'finish');
    expect(finished.map((p) => p.header['recording_id']), unorderedEquals(parts.map((p) => p.header['recording_id'])));
  });

  test('complete CV1 frames reach only the paired owner, with a new codec and recording after reconnect', () async {
    final fixture = _Fixture();
    await fixture.open();
    final capture = fixture.capture;
    capture.start();
    expect(capture.active, isTrue);
    expect(capture.wantsAudio, isFalse);
    capture.handle(const Cv1LinkReady(1, 20));
    capture.handle(_audio(1, 65535, 0, _padded.sublist(0, 17)));
    capture.handle(const Cv1LinkReady(1, 20)); // Duplicate native status, mid-frame.
    capture.handle(_audio(1, 0, 1, _padded.sublist(17)));
    capture.handle(_audio(1, 1, 0, _silence));
    await fixture.journal.flushPendingWrites();
    expect(capture.hasPersistedAudio, isTrue);
    capture.handle(const Cv1LinkLost(2)); // The last unconfirmed packet cannot cross this boundary.
    expect(capture.active, isTrue);
    expect(capture.wantsAudio, isFalse);
    capture.handle(const Cv1LinkReady(1, 20));
    capture.handle(_audio(1, 2, 0, _silence));
    capture.handle(const Cv1LinkReady(2, 21));
    capture.handle(const Cv1Button(1, 1));
    capture.handle(const Cv1LinkLost(1));
    capture.handle(_audio(2, 70, 1, [0]));
    capture.handle(_audio(2, 71, 0, _silence));
    capture.handle(_audio(2, 72, 0, _padded));
    await capture.stop();
    capture.handle(const Cv1LinkLost(3));
    capture.handle(const Cv1LinkReady(3, 21));
    capture.handle(_audio(3, 73, 0, _silence));
    expect(capture.wantsAudio, isFalse);
    await fixture.journal.drain();
    final opus = fixture.uploads.singleWhere((p) => p.header['codec'] == 'opus');
    final opus320 = fixture.uploads.singleWhere((p) => p.header['codec'] == 'opus_fs320');
    expect(fixture.uploads, hasLength(2));
    expect(opus.frames, [_padded]);
    expect(opus320.frames, [_silence]);
    expect(opus.header['recording_id'], isNot(opus320.header['recording_id']));
  });

  test('mute and counter loss preserve the recording ID and clear decoder history, double tap checkpoints', () async {
    final fixture = _Fixture();
    await fixture.open();
    final capture = fixture.capture;
    capture.handle(const Cv1LinkReady(7, 21));
    expect(capture.active, isFalse);
    capture.handle(const Cv1Button(7, 1));
    for (int i = 0; i < 5; i++) {
      capture.handle(_audio(7, i, 0, _silence));
    }
    await fixture.journal.flushPendingWrites();
    capture.toggleMute();
    expect(capture.hasPersistedAudio, isTrue);
    capture.handle(_audio(7, 5, 0, _padded));
    capture.handle(const Cv1Button(7, 4)); // Gesture edges are observational.
    expect(capture.intent, Cv1CaptureIntent.muted);
    capture.toggleMute();
    for (int i = 6; i <= 10; i++) {
      capture.handle(_audio(7, i, 0, _padded));
    }
    capture.handle(_audio(7, 12, 0, _silence)); // Lose counter 11 and drop the unconfirmed tail.
    capture.handle(_audio(7, 13, 0, _padded));
    capture.handle(const Cv1Button(7, 2));
    expect(capture.intent, Cv1CaptureIntent.recording);
    capture.handle(_audio(7, 14, 0, _silence));
    capture.handle(const Cv1Button(7, 1));
    expect(capture.active, isFalse);
    await capture.stop();
    await fixture.journal.drain();
    final parts = fixture.uploads..sort((a, b) => (a.header['index'] as int).compareTo(b.header['index'] as int));
    expect(parts.map((p) => p.header['recording_id']).toSet(), hasLength(1));
    expect(parts.map((p) => p.header['preroll_frames']), [0, 0, 0, 0]);
    expect(parts.map((p) => p.frames), [
      List.filled(4, _silence),
      List.filled(4, _padded),
      [_silence],
      [_padded],
    ]);
  });

  test(
    'an unsupported codec and a retired button handoff cannot start capture, muted reconnect remains muted',
    () async {
      final transfer = Completer<void>();
      int requests = 0;
      final fixture = _Fixture();
      await fixture.open(
        acquire: () {
          requests++;
          return transfer.future;
        },
      );
      final capture = fixture.capture;
      capture.handle(const Cv1LinkReady(1, 1));
      capture.handle(const Cv1Button(1, 1));
      expect(capture.problem, Cv1CaptureProblem.unsupportedCodec);
      expect(requests, 0);
      capture.handle(const Cv1LinkReady(2, 20));
      capture.handle(const Cv1Button(2, 1));
      expect(requests, 1);
      capture.handle(const Cv1LinkLost(3));
      transfer.complete();
      await Future<void>.value();
      capture.handle(const Cv1LinkReady(3, 20));
      expect(capture.active, isFalse);
      capture.handle(const Cv1Button(3, 1));
      await Future<void>.value();
      expect(capture.wantsAudio, isTrue);
      capture.toggleMute();
      capture.handle(const Cv1LinkLost(4));
      capture.handle(const Cv1LinkReady(4, 20));
      expect(capture.intent, Cv1CaptureIntent.muted);
      expect(capture.wantsAudio, isFalse);
      await capture.stop();
      expect(fixture.uploads, isEmpty);
    },
  );

  test('old queued disk failure cannot stop a new capture, an active disk failure stops its owner', () async {
    final blocked = Completer<void>();
    final release = Completer<void>();
    var failNew = false;
    final fixture = _Fixture();
    await fixture.open(
      openJournal: (file) async {
        if (!blocked.isCompleted) {
          blocked.complete();
          await release.future;
          throw const FileSystemException('synthetic delayed failure');
        }
        if (failNew) throw const FileSystemException('synthetic failure');
        return file.open(mode: FileMode.writeOnly);
      },
    );
    final capture = fixture.capture;
    void submit(int counter) {
      capture.handle(_audio(1, counter, 0, _silence));
      capture.handle(_audio(1, counter + 1, 0, _silence));
    }

    capture.handle(const Cv1LinkReady(1, 20));
    capture.start();
    submit(1);
    await blocked.future;
    final oldStop = capture.stop();
    capture.start();
    submit(5);
    release.complete();
    await oldStop;
    await fixture.journal.flushPendingWrites();
    expect(capture.active, isTrue);
    expect(capture.hasPersistedAudio, isTrue);
    expect(capture.problem, isNull);
    await capture.stop();
    await fixture.journal.drain();
    expect(fixture.uploads.single.frames, [_silence]);
    failNew = true;
    capture.start();
    submit(8);
    await fixture.journal.flushPendingWrites();
    await capture.stop();
    expect(capture.active, isFalse);
    expect(capture.problem, Cv1CaptureProblem.storage);
  });
}
