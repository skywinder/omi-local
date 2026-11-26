import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:omi/services/capture/local_audio_journal.dart';
import 'package:omi/services/devices/ring_protocol.dart';
import 'package:uuid/uuid.dart';

/// The raw batch belongs to the original pairing until every historical interval
/// is published to its outbox. Stable part IDs allow replay after process death.
class Cv1Archive {
  Cv1Archive(this.journal, this.owner);
  final LocalAudioJournal journal;
  final String owner;
  static const maxRecords = 32;
  static const _record = RingProtocol.recordSize;

  Future<int> save(Uint8List bytes, String deviceId, int sequence, int codec) async {
    if (bytes.isEmpty ||
        bytes.length % _record != 0 ||
        bytes.length > maxRecords * _record ||
        sequence < 0 ||
        (codec != 20 && codec != 21)) {
      throw const FormatException('Invalid CV1 batch');
    }
    final id = const Uuid().v5(Namespace.url.value, '$owner/$deviceId/$sequence/${sha256.convert(bytes)}');
    final file = File('${journal.directory.path}/$id.$codec.cv1');
    await file.writeAsBytes(bytes, flush: true);
    return publish(file);
  }

  Iterable<File> get staged => journal.directory.listSync().whereType<File>().where((f) => f.path.endsWith('.cv1'));

  Future<bool> recover() async {
    var complete = true;
    for (final file in staged.toList()) {
      try {
        await publish(file);
      } catch (_) {
        complete = false;
      }
    }
    return complete;
  }

  Future<int> publish(File file) async {
    final fields = file.uri.pathSegments.last.split('.');
    if (fields.length != 3 || !{'20', '21'}.contains(fields[1]) || await file.length() > maxRecords * _record) {
      throw const FormatException('Invalid staged CV1 batch');
    }
    final codec = fields[1] == '20' ? 'opus' : 'opus_fs320';
    final raw = await file.readAsBytes();
    if (raw.isEmpty || raw.length % _record != 0) throw const FormatException('Incomplete CV1 batch');
    final groups = <({int offset, int epoch, List<List<int>> packets})>[];
    int? previous;
    var micros = 0;
    for (int offset = 0; offset < raw.length; offset += _record) {
      final record = Uint8List.sublistView(raw, offset, offset + _record);
      final epoch = RingProtocol.readRecordTimestamp(record);
      if (epoch < 1577836800 || epoch > journal.clock().millisecondsSinceEpoch ~/ 1000 + 300) {
        throw const FormatException('Invalid CV1 clock');
      }
      final packets = RingProtocol.parseAudioPayload(Uint8List.sublistView(record, 4));
      if (packets.isEmpty) throw const FormatException('Empty CV1 record');
      for (final packet in packets) {
        micros += LocalAudioRecording.packetMicroseconds(codec, packet);
      }
      if (previous == null || epoch < previous || epoch - previous > 1) {
        groups.add((offset: offset, epoch: epoch, packets: []));
      }
      groups.last.packets.addAll(packets);
      previous = epoch;
    }
    for (final group in groups) {
      await journal.queueRecoveredOpus(
        id: const Uuid().v5(fields[0], group.offset.toString()),
        serverId: owner,
        codec: codec,
        startedAt: DateTime.fromMillisecondsSinceEpoch(group.epoch * 1000, isUtc: true),
        packets: group.packets,
      );
    }
    await file.delete();
    journal.retry();
    return micros;
  }
}
