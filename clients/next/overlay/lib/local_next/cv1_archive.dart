import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
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
  static const maxWindows = 32;
  File? _sessionFile;
  int? _nextSequence;
  List<String>? _lastWindow;
  String? _sessionDevice;
  int? _sessionCodec;
  int records = 0;
  ({DateTime first, DateTime last})? _savedTimes;
  ({DateTime first, DateTime last})? get savedTimes => _savedTimes;
  static const _record = RingProtocol.recordSize;

  /// Each completed append is flushed before the next consuming Bluetooth request.
  Future<int> append(Uint8List bytes, String deviceId, int sequence, int codec, {int? verifyThrough}) async {
    if (bytes.isEmpty ||
        bytes.length % _record != 0 ||
        bytes.length > maxRecords * _record ||
        (_nextSequence != null && (deviceId != _sessionDevice || _sessionCodec != codec)) ||
        sequence < 0 ||
        (codec != 20 && codec != 21)) {
      throw const FormatException('Invalid CV1 batch');
    }
    final deviceKey = const Uuid().v5(Namespace.url.value, '$owner/$deviceId/$codec');
    Future<File> newWindowFile(int first, Uint8List data) async {
      final id = const Uuid().v5(Namespace.url.value, '$owner/$deviceId/$first/${sha256.convert(data)}');
      final mode = journal.filtersNewAudio ? '.speech' : '.raw';
      return File('${journal.directory.path}/$id.$codec.$deviceKey.$first$mode.cv1').create(exclusive: true);
    }

    final hashes = _recordHashes(bytes);
    final saved = _lastWindow == null ? await _checkpoint(deviceKey) : null;
    final previous = _lastWindow ?? saved?.hashes ?? const <String>[];
    final overlapCount = (_nextSequence ?? saved?.end ?? sequence) - sequence;
    final repeated = _verifiedOverlap(previous, overlapCount, hashes);
    final mustVerify = verifyThrough != null && sequence < verifyThrough;
    if (repeated == null && (_lastWindow != null || mustVerify)) {
      if (overlapCount > 0 || mustVerify) {
        final changed = await newWindowFile(sequence, bytes);
        await changed.writeAsBytes(bytes, flush: true);
      }
      throw const FormatException('Non-contiguous or changed CV1 window');
    }
    // Legacy firmware lacks a ring identity. Across launches, skip only records
    // matching the original sequence, timestamp and full payload hash.
    final overlap = (repeated ?? 0) * _record;
    final fresh = Uint8List.sublistView(bytes, overlap);
    if (fresh.isEmpty) return 0;
    if (records + fresh.length ~/ _record > maxRecords * maxWindows) {
      throw const FormatException('CV1 series is full');
    }
    // Preserve a malformed window separately so earlier valid windows can still be published.
    var micros = 0;
    var first = savedTimes?.first;
    var last = savedTimes?.last;
    try {
      for (final record in _decode(fresh, codec == 20 ? 'opus' : 'opus_fs320')) {
        micros += record.duration;
        final time = DateTime.fromMillisecondsSinceEpoch(record.epoch * 1000, isUtc: true);
        if (first == null || time.isBefore(first)) first = time;
        if (last == null || time.isAfter(last)) last = time;
      }
    } catch (_) {
      final file = await newWindowFile(sequence + overlap ~/ _record, fresh);
      await file.writeAsBytes(fresh, flush: true);
      rethrow;
    }
    _sessionFile ??= await newWindowFile(sequence + overlap ~/ _record, fresh);
    await _sessionFile!.writeAsBytes(fresh, mode: FileMode.append, flush: true);
    if (first != null && last != null) _savedTimes = (first: first, last: last);
    _sessionDevice = deviceId;
    _sessionCodec = codec;
    _lastWindow = hashes;
    records += fresh.length ~/ _record;
    _nextSequence = sequence + bytes.length ~/ _record;
    return micros;
  }

  Future<int> finish() async {
    final file = _sessionFile;
    final micros = file == null ? 0 : await publish(file);
    _sessionFile = null;
    _nextSequence = null;
    _lastWindow = null;
    records = 0;
    return micros;
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

  // An interrupted reply may end before the last record we already hold.
  int? _verifiedOverlap(List<String> saved, int overlap, List<String> received) {
    if (overlap < 0 || overlap > saved.length) return null;
    final count = overlap.clamp(0, received.length);
    final start = saved.length - overlap;
    return listEquals(saved.sublist(start, start + count), received.sublist(0, count)) ? count : null;
  }

  List<String> _recordHashes(Uint8List bytes) => [
    for (int i = 0; i + _record <= bytes.length; i += _record)
      sha256.convert(Uint8List.sublistView(bytes, i, i + _record)).toString(),
  ];

  File _checkpointFile(String key) => File('${journal.directory.path}/$key.cv1-cursor');

  Future<({int end, List<String> hashes})?> _checkpoint(String key) async {
    final file = _checkpointFile(key);
    if (!await file.exists() || await file.length() > 4096) return null;
    final lines = await file.readAsLines(encoding: latin1);
    if (lines.length < 2 || lines.length > maxRecords + 1) return null;
    final end = int.tryParse(lines.first);
    final hashes = lines.sublist(1);
    if (end == null || end < hashes.length || !hashes.every(RegExp(r'^[a-f0-9]{64}$').hasMatch)) return null;
    return (end: end, hashes: hashes);
  }

  Future<void> _rememberTail(String key, int first, Uint8List raw) async {
    final count = raw.length ~/ _record;
    final end = first + count;
    final old = await _checkpoint(key);
    final start = count > maxRecords ? count - maxRecords : 0;
    final hashes = _recordHashes(Uint8List.sublistView(raw, start * _record, count * _record));
    if (old != null &&
        old.end == end &&
        hashes.length <= old.hashes.length &&
        listEquals(old.hashes.sublist(old.hashes.length - hashes.length), hashes)) {
      return;
    }
    if (old?.end == first && hashes.length < maxRecords) {
      hashes.insertAll(
        0,
        old!.hashes.sublist((old.hashes.length + hashes.length - maxRecords).clamp(0, old.hashes.length)),
      );
    }
    final file = _checkpointFile(key);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString([end, ...hashes].join('\n'), flush: true);
    await temp.rename(file.path);
  }

  Future<int> publish(File file) async {
    final fields = file.uri.pathSegments.last.split('.');
    final tagged = fields.length == 6 && {'speech', 'raw'}.contains(fields[4]);
    final reviewSpeech = tagged ? fields.removeAt(4) == 'speech' : false;
    if ((fields.length != 3 && fields.length != 5) ||
        (fields.length == 5 &&
            (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(fields[2]) || (int.tryParse(fields[3]) ?? -1) < 0)) ||
        !{'20', '21'}.contains(fields[1]) ||
        await file.length() > maxWindows * maxRecords * _record) {
      throw const FormatException('Invalid staged CV1 batch');
    }
    final codec = fields[1] == '20' ? 'opus' : 'opus_fs320';
    final raw = await file.readAsBytes();
    if (raw.length < _record) throw const FormatException('Incomplete CV1 batch');
    if (fields.length == 5) {
      final saved = await _checkpoint(fields[2]);
      final count = raw.length ~/ _record;
      if (saved != null && count <= maxRecords) {
        final overlap = saved.end - int.parse(fields[3]);
        if (overlap >= count && _verifiedOverlap(saved.hashes, overlap, _recordHashes(raw)) == count) {
          // Earlier builds could stage a duplicate when an interrupted read ended
          // inside the saved range. The checkpoint follows durable outbox storage.
          await file.delete();
          return 0;
        }
      }
    }
    final groups = <({int offset, int epoch, List<List<int>> packets})>[];
    int? previous;
    var micros = 0;
    var groupMicros = 0;
    for (final (:offset, :epoch, :packets, :duration) in _decode(raw, codec)) {
      if (previous == null ||
          epoch < previous ||
          epoch - previous > 1 ||
          groupMicros + duration > const Duration(minutes: 5).inMicroseconds ||
          groups.last.packets.length + packets.length > LocalAudioJournal.maxPartPackets) {
        groupMicros = 0;
        groups.add((offset: offset, epoch: epoch, packets: []));
      }
      micros += duration;
      groupMicros += duration;
      groups.last.packets.addAll(packets);
      previous = epoch;
    }
    final namespace = raw.length <= maxRecords * _record
        ? fields[0]
        : const Uuid().v5(fields[0], sha256.convert(raw).toString());
    for (final group in groups) {
      await journal.queueRecoveredOpus(
        id: const Uuid().v5(namespace, group.offset.toString()),
        serverId: owner,
        codec: codec,
        startedAt: DateTime.fromMillisecondsSinceEpoch(group.epoch * 1000, isUtc: true),
        packets: group.packets,
        reviewSpeech: reviewSpeech,
      );
    }
    if (fields.length == 5) await _rememberTail(fields[2], int.parse(fields[3]), raw);
    await file.delete();
    journal.retry();
    return micros;
  }

  Iterable<({int offset, int epoch, List<List<int>> packets, int duration})> _decode(
    Uint8List raw,
    String codec,
  ) sync* {
    // Process death during the final append can leave a torn trailing record.
    for (int offset = 0; offset + _record <= raw.length; offset += _record) {
      final record = Uint8List.sublistView(raw, offset, offset + _record);
      final epoch = RingProtocol.readRecordTimestamp(record);
      if (epoch < 1577836800 || epoch > journal.clock().millisecondsSinceEpoch ~/ 1000 + 300) {
        throw const FormatException('Invalid CV1 clock');
      }
      final packets = RingProtocol.parseAudioPayload(Uint8List.sublistView(record, 4));
      if (packets.isEmpty) throw const FormatException('Empty CV1 record');
      final duration = packets.fold<int>(
        0,
        (sum, packet) => sum + LocalAudioRecording.packetMicroseconds(codec, packet),
      );
      yield (offset: offset, epoch: epoch, packets: packets, duration: duration);
    }
  }
}
