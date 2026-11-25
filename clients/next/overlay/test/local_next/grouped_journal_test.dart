import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

const _owner = 'fixture-owner';

Map<String, dynamic> _header(Uint8List bytes) {
  final size = ByteData.sublistView(bytes, 8, 12).getUint32(0, Endian.big);
  return jsonDecode(utf8.decode(bytes.sublist(12, 12 + size))) as Map<String, dynamic>;
}

Map<String, dynamic> _receipt(Uint8List bytes) => {
  'id': _header(bytes)['id'],
  'sha256': sha256.convert(bytes).toString(),
  'stored': true,
};

void main() {
  test('checkpoint keeps a group open and sends finish only after Stop', () async {
    final directory = await Directory.systemTemp.createTemp('next-grouped-audio-');
    addTearDown(() => directory.delete(recursive: true));
    final sent = <Map<String, dynamic>>[];
    final journal = LocalAudioJournal(
      directory: directory,
      groupSilence: () => 30,
      upload: (bytes, serverId) async {
        expect(serverId, _owner);
        sent.add(_header(bytes));
        return _receipt(bytes);
      },
    );
    addTearDown(journal.dispose);
    await journal.initialize();
    final recording = journal.beginForServer(source: 'phone', codec: 'pcm16', serverId: _owner);
    await recording.add([1, 0, 2, 0, 3, 0]);
    await recording.checkpoint();
    await journal.drain();
    expect(recording.audioSeconds, greaterThan(0));
    expect(sent.map((row) => row['kind']), ['audio']);
    expect(sent.single['version'], 3);
    expect(sent.single['silence_seconds'], 30);
    await recording.add([4, 0, 5, 0]);
    await recording.stop();
    await journal.drain();
    expect(sent.map((row) => row['kind']), ['audio', 'audio', 'finish']);
    expect(sent.every((row) => row['recording_id'] == recording.recordingId), isTrue);
    expect(sent.where((row) => row['kind'] == 'audio').map((row) => row['first_sample']), [0, 3]);
    expect(sent.last['index'], 2);
    expect(journal.pendingParts, 0);
  });

  test('recovery seals pending audio before publishing the group finish', () async {
    final directory = await Directory.systemTemp.createTemp('next-group-recovery-');
    addTearDown(() => directory.delete(recursive: true));
    final old = LocalAudioJournal(
      directory: directory,
      groupSilence: () => 0,
      upload: (_, serverId) async => throw StateError('Offline'),
    );
    await old.initialize();
    final recording = old.beginForServer(source: 'phone', codec: 'pcm16', serverId: _owner);
    await recording.add([1, 0]);
    await recording.checkpoint();
    await old.drain();
    old.dispose();
    final audio = directory.listSync().whereType<File>().singleWhere((f) => f.path.endsWith('.ready'));
    final recovering = await audio.rename(audio.path.replaceFirst(RegExp(r'\.ready$'), '.part'));
    await recovering.writeAsBytes([0, 0], mode: FileMode.append);
    final clips = <Uint8List>[];
    final restored = LocalAudioJournal(
      directory: directory,
      upload: (bytes, _) async {
        clips.add(bytes);
        return _receipt(bytes);
      },
    );
    addTearDown(restored.dispose);
    await restored.initialize();
    await restored.drain();
    expect(clips.map((bytes) => _header(bytes)['kind']), ['audio', 'finish']);
    expect(clips.first.sublist(clips.first.length - 6), [0, 0, 0, 2, 1, 0]);
    expect(_header(clips.last)['index'], 1);
    expect(restored.pendingParts, 0);
  });

  test('a malformed grouped part holds its finish for recovery', () async {
    final directory = await Directory.systemTemp.createTemp('next-group-bad-tail-');
    addTearDown(() => directory.delete(recursive: true));
    final old = LocalAudioJournal(
      directory: directory,
      groupSilence: () => 0,
      upload: (_, serverId) async => throw StateError('Offline'),
    );
    await old.initialize();
    final recording = old.beginForServer(source: 'phone', codec: 'pcm16', serverId: _owner);
    await recording.add([1, 0]);
    await recording.checkpoint();
    await old.drain();
    old.dispose();
    final invalid = File('${directory.path}/${recording.recordingId}.damaged.part');
    await invalid.writeAsBytes([1, 2]);
    final sent = <String>[];
    final restored = LocalAudioJournal(
      directory: directory,
      upload: (bytes, _) async {
        sent.add(_header(bytes)['kind'] as String);
        return _receipt(bytes);
      },
    );
    addTearDown(restored.dispose);
    await restored.initialize();
    await restored.drain();
    expect(sent, ['audio']);
    expect(await invalid.readAsBytes(), [1, 2]);
    expect(await File('${directory.path}/${recording.recordingId}.finish').exists(), isTrue);
  });
}
