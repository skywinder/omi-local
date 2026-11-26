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
    expect(await archive.save(raw, 'test-pendant', 7, 21), 60000);
    await journal.drain();
    expect(journal.pendingParts, 2);
    await archive.save(raw, 'test-pendant', 7, 21);
    await journal.drain();
    expect(journal.pendingParts, 2);
    online = true;
    await journal.drain();
    expect(accepted.keys, unorderedEquals(['2023-11-14T22:13:20.000Z', '2023-11-14T22:14:20.000Z']));
    expect(journal.pendingParts, 0);
    expect(archive.staged, isEmpty);
  });

  test('keeps invalid RTC data on disk across recovery and never publishes it as current audio', () async {
    await expectLater(archive.save(record(0), 'test-pendant', 7, 20), throwsFormatException);
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
