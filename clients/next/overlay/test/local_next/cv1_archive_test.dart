import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/cv1_archive.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/services/capture/local_audio_journal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const epoch = 1700000000;
  Uint8List record(int seconds) {
    final bytes = Uint8List(444);
    ByteData.sublistView(bytes).setUint32(0, seconds);
    bytes.setRange(4, 7, [2, 8, 33]);
    return bytes;
  }

  late Directory dir;
  late LocalAudioJournal journal;
  late Cv1Archive archive;
  var online = false;
  final accepted = <String, Uint8List>{};
  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    online = false;
    accepted.clear();
    journal = LocalAudioJournal(
      directory: dir,
      upload: (body, owner) async {
        if (!online) throw LocalDeliveryIssue.connection;
        final length = ByteData.sublistView(body).getUint32(8);
        final header = jsonDecode(utf8.decode(body.sublist(12, 12 + length)));
        expect(header['server_id'], owner);
        accepted[header['started_at'] as String] = body;
        return {'stored': true, 'id': header['id'], 'sha256': sha256.convert(body).toString()};
      },
    );
    archive = Cv1Archive(journal, 'paired-owner');
    await journal.initialize();
  });
  tearDown(() async {
    await journal.drain();
    journal.dispose();
    await dir.delete(recursive: true);
  });

  test('keeps historical intervals queued offline, replays identical parts and drains on receipts', () async {
    final raw = Uint8List.fromList([...record(epoch), ...record(epoch), ...record(epoch + 60)]);
    await archive.append(raw, 'test-pendant', 7, 21);
    expect(await archive.finish(), 60000);
    await journal.drain();
    expect(journal.pendingParts, 2);
    await archive.append(raw, 'test-pendant', 7, 21);
    await archive.finish();
    await journal.drain();
    expect(journal.pendingParts, 2);
    online = true;
    await journal.drain();
    expect(accepted.keys, unorderedEquals(['2023-11-14T22:13:20.000Z', '2023-11-14T22:14:20.000Z']));
    expect(journal.pendingParts, 0);
    expect(archive.staged, isEmpty);
  });

  test('a restart publishes contiguous windows as one interval and skips a torn final record', () async {
    final window = Uint8List.fromList([for (var i = 0; i < 32; i++) ...record(epoch)]);
    await archive.append(window, 'test-pendant', 7, 21);
    await archive.append(window, 'test-pendant', 39, 21);
    await archive.staged.single.writeAsBytes([0, 1], mode: FileMode.append, flush: true);
    expect(await Cv1Archive(journal, 'paired-owner').recover(), isTrue);
    await journal.drain();
    expect(journal.pendingParts, 1);
    online = true;
    await journal.drain();
    final body = accepted.values.single;
    final length = ByteData.sublistView(body).getUint32(8);
    expect(body.length - 12 - length, 64 * 6);
  });

  test('re-reading a confirmed prefix includes each identical record once', () async {
    final first = Uint8List.fromList([...record(epoch), ...record(epoch + 1)]);
    final next = Uint8List.fromList([...record(epoch + 1), ...record(epoch + 2)]);
    expect(await archive.append(first, 'same-pendant', 12, 20), 40000);
    expect(await archive.append(next, 'same-pendant', 13, 20), 20000);
    expect(archive.records, 3);
    expect(await archive.finish(), 60000);
    await journal.drain();
    expect(journal.pendingParts, 1);
  });

  test('a subsequent import verifies the previous tail across restart without skipping a reused sequence', () async {
    final first = Uint8List.fromList([...record(epoch), ...record(epoch + 1)]);
    final next = Uint8List.fromList([...record(epoch + 1), ...record(epoch + 2)]);
    await archive.append(first, 'pendant', 44, 20);
    await archive.finish();
    final resumed = Cv1Archive(journal, 'paired-owner');
    expect(await resumed.append(next, 'pendant', 45, 20), 20000);
    expect(await resumed.finish(), 20000);
    final replaced = Cv1Archive(journal, 'paired-owner');
    expect(await replaced.append(record(epoch + 9), 'pendant', 46, 20), 20000);
    await replaced.finish();
    final other = Cv1Archive(journal, 'paired-owner');
    expect(await other.append(record(epoch + 9), 'second-pendant', 46, 20), 20000);
    await other.finish();
  });

  test('unreadable deduplication hints preserve newly received audio', () async {
    await archive.append(record(epoch), 'pendant', 40, 20);
    await archive.finish();
    final checkpoint = dir.listSync().whereType<File>().singleWhere((file) => file.path.endsWith('.cv1-cursor'));
    await checkpoint.writeAsBytes([255, 10, 254]);
    expect(await archive.append(record(epoch + 1), 'pendant', 41, 20), 20000);
    expect(await archive.finish(), 20000);
  });

  test('a later broken clock preserves both the usable prefix and the separate raw window', () async {
    await archive.append(record(epoch), 'test-pendant', 7, 21);
    await expectLater(archive.append(record(epoch), 'test-pendant', 10, 21), throwsFormatException);
    await expectLater(archive.append(record(0), 'test-pendant', 8, 21), throwsFormatException);
    expect(await archive.finish(), 20000);
    expect(await archive.staged.single.readAsBytes(), record(0));
    await journal.drain();
    expect(journal.pendingParts, 1);
  });

  test('keeps invalid RTC data on disk across recovery and never publishes it as current audio', () async {
    await expectLater(archive.append(record(0), 'test-pendant', 7, 20), throwsFormatException);
    expect(await Cv1Archive(journal, 'paired-owner').recover(), isFalse);
    expect(await archive.staged.single.readAsBytes(), record(0));
    expect(journal.pendingParts, 0);
    expect(accepted, isEmpty);
    final documents = Directory('${dir.path}/documents');
    final owner = LocalAudioJournal.serverIdentity('bastion', 'mock');
    final queue = await Directory('${documents.path}/outbox/$owner').create(recursive: true);
    await archive.staged.single.copy('${queue.path}/raw.cv1');
    expect(await PairedLibrary.retainedAudioFor(owner, documents: documents), isTrue);
  });
}
