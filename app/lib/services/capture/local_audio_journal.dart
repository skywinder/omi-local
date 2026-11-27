import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' as typed;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import 'package:omi/services/capture/local_opus_preroll.dart';

typedef LocalPartUploader = Future<Map<String, dynamic>> Function(Uint8List body, String serverId);

class LocalSpeechUncertain implements Exception {
  const LocalSpeechUncertain();
}

typedef LocalSpeechRange = ({int first, int end});
typedef LocalSpeechFilter =
    Future<List<LocalSpeechRange>> Function(String codec, List<Uint8List> packets, int preroll, int pauseSeconds);

enum LocalDeliveryIssue implements Exception {
  connection,
  tls,
  pairing,
  server,
  receipt,
  localFile,
  queueStorage,
  speechReview,
}

/// Audio accepted from Flutter is flushed locally before it enters live preview.
/// Immutable parts survive network failure and are removed only on a matching
/// durable server receipt. The cloud WAL and its send-time flags are unrelated.
class LocalAudioJournal extends ChangeNotifier with WidgetsBindingObserver {
  LocalAudioJournal({
    required this.directory,
    required this.upload,
    this.openJournal,
    this.groupSilence,
    this.filterSpeech,
    this.speechMode,
    this.onConversationBoundary,
    DateTime Function()? clock,
    this.partDuration = const Duration(minutes: 5),
    this.maxStorageBytes = 512 * 1024 * 1024,
    this.maxQueuedBytes = 4 * 1024 * 1024,
  }) : clock = clock ?? DateTime.now;

  static const magic = [79, 77, 73, 76, 79, 67, 49, 10];
  static const maxPartBytes = 16 * 1024 * 1024;
  static const maxFrameBytes = 4096;
  static const maxPartPackets = 60000;
  static const groupSilenceChoices = {0, 15, 30, 60, 120};
  static final _groupUuid = RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$');
  final Directory directory;
  final LocalPartUploader upload;
  final LocalSpeechFilter? filterSpeech;
  final bool Function()? speechMode;
  bool get filtersNewAudio => speechMode?.call() == true;
  final Future<RandomAccessFile> Function(File file)? openJournal;
  final int? Function()? groupSilence;
  final void Function(String recordingId, int sample)? onConversationBoundary;
  final DateTime Function() clock;
  final Duration partDuration;
  final int maxStorageBytes;
  final int maxQueuedBytes;
  Future<void> _writes = Future<void>.value();
  Future<void>? _uploading;
  bool _drainRequested = false;
  Timer? _retry;
  final _recordings = <LocalAudioRecording>{};
  int _queuedBytes = 0;
  int pendingParts = 0;
  int pendingBytes = 0;
  int _deliveryRevision = 0;
  int get deliveryRevision => _deliveryRevision;
  Set<LocalDeliveryIssue> _deliveryIssues = const {};
  Set<LocalDeliveryIssue> get deliveryIssues => _deliveryIssues;
  bool get deliveryFailed => deliveryIssues.isNotEmpty;
  bool _recoveryFailed = false;
  String? captureIssue;
  int get activeRecordings => _recordings.length;
  bool get uploading => _uploading != null;
  bool _disposed = false;

  static String serverIdentity(String address, String key) =>
      sha256.convert(utf8.encode(jsonEncode([address, key]))).toString();
  Future<void> flushPendingWrites() => _writes;

  Future<T> _serial<T>(Future<T> Function() work) {
    final operation = _writes.then((_) => work());
    _writes = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  static Uint8List _length(int value) => (ByteData(4)..setUint32(0, value, Endian.big)).buffer.asUint8List();

  Future<void> initialize() async {
    await directory.create(recursive: true);
    final incompleteGroups = <String>{};
    for (final entity in directory.listSync()) {
      if (entity is File && entity.path.endsWith('.part')) {
        try {
          await _recover(entity);
        } catch (_) {
          // Keep malformed originals for recovery; never replace or delete them.
          _recoveryFailed = true;
          final fields = entity.uri.pathSegments.last.split('.');
          if (fields.length == 3 && _groupUuid.hasMatch(fields.first)) incompleteGroups.add(fields.first);
        }
      }
    }
    for (final marker in directory.listSync().whereType<File>().where((f) => f.path.endsWith('.finish'))) {
      final id = marker.uri.pathSegments.last.split('.').first;
      if (incompleteGroups.contains(id)) continue;
      try {
        await _promoteFinish(marker, id);
      } catch (_) {
        _recoveryFailed = true;
      }
    }
    if (_recoveryFailed) _deliveryIssues = const {LocalDeliveryIssue.localFile};
    await _countPending();
  }

  static bool requiresDeliveryV2(Uint8List bytes) => deliveryVersion(bytes) >= 2;
  static int deliveryVersion(Uint8List bytes) => _header(bytes).header['version'] as int;

  static ({Map<String, dynamic> header, int offset}) _header(Uint8List bytes) {
    if (bytes.length < 12 || !listEquals(bytes.sublist(0, 8), magic)) {
      throw const FormatException('Invalid local audio journal');
    }
    final size = ByteData.sublistView(bytes, 8, 12).getUint32(0, Endian.big);
    if (size == 0 || size > 4096 || 12 + size > bytes.length) {
      throw const FormatException('Invalid local audio journal header');
    }
    final header = jsonDecode(utf8.decode(bytes.sublist(12, 12 + size))) as Map<String, dynamic>;
    final version = header['version'];
    if (version is! int ||
        !const {1, 2, 3}.contains(version) ||
        header['id'] is! String ||
        header['server_id'] is! String) {
      throw const FormatException('Invalid local audio journal identity');
    }
    final preroll = header['preroll_frames'] ?? 0;
    if (preroll is! int ||
        preroll < 0 ||
        preroll > 32 ||
        (header['version'] == 1 && preroll != 0) ||
        (header['version'] != 1 && !header.containsKey('preroll_frames')) ||
        (header['codec'] == 'pcm16' && preroll != 0)) {
      throw const FormatException('Invalid local audio pre-roll');
    }
    if (header['version'] == 3) {
      final record = header['recording_id'], index = header['index'], kind = header['kind'];
      if (header['group_version'] != 1 ||
          record is! String ||
          !_groupUuid.hasMatch(record) ||
          !groupSilenceChoices.contains(header['silence_seconds']) ||
          index is! int ||
          index < 0 ||
          (kind == 'finish' && (index == 0 || header['id'] != record || preroll != 0 || bytes.length != 12 + size)) ||
          (kind == 'audio' && (header['first_sample'] is! int || (header['first_sample'] as int) < 0)) ||
          (kind != 'audio' && kind != 'finish')) {
        throw const FormatException('Invalid local grouped journal');
      }
    }
    return (header: header, offset: 12 + size);
  }

  Future<void> _recover(File file) async {
    if (await file.length() > maxPartBytes) throw const FormatException('Oversized local audio journal');
    final bytes = await file.readAsBytes();
    final envelope = _header(bytes);
    var position = envelope.offset;
    final start = position;
    var packets = 0;
    while (position + 4 <= bytes.length) {
      final size = ByteData.sublistView(bytes, position, position + 4).getUint32(0, Endian.big);
      if (size == 0 || size > maxFrameBytes) throw const FormatException('Invalid local audio packet');
      if (position + 4 + size > bytes.length) break;
      position += 4 + size;
      packets++;
    }
    if (position == start || packets <= (envelope.header['preroll_frames'] as int? ?? 0)) {
      return; // Decoder context alone is not a new recording to upload.
    }
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.truncate(position);
      await handle.flush();
    } finally {
      await handle.close();
    }
    if (envelope.header['version'] == 3) await _writeFinishMarker(envelope.header);
    await file.rename(
      file.path.replaceFirst(RegExp(r'\.part$'), envelope.header['speech_review'] == 1 ? '.vad' : '.ready'),
    );
  }

  Future<Map<String, dynamic>> _finishHeader(File marker, String recordingId) async {
    if (await marker.length() > 4108) throw const FormatException('Oversized local group finish');
    final header = _header(await marker.readAsBytes()).header;
    if (header['kind'] != 'finish' || header['recording_id'] != recordingId || header['version'] != 3) {
      throw const FormatException('Invalid local group finish');
    }
    return header;
  }

  Future<void> _writeFinishMarker(Map<String, dynamic> part) async {
    final id = part['recording_id'] as String;
    final index = (part['index'] as int) + 1;
    final marker = File('${directory.path}/$id.finish');
    final oldBytes = await marker.exists() ? await marker.length() : 0;
    if (oldBytes != 0 && ((await _finishHeader(marker, id))['index'] as int) >= index) return;
    final header = utf8.encode(
      jsonEncode(
        {
          ...part,
          'kind': 'finish',
          'id': id,
          'index': index,
          'started_at': part['group_started_at'],
          'preroll_frames': 0,
        }..remove('first_sample'),
      ),
    );
    final temp = File('${marker.path}.tmp');
    await temp.writeAsBytes([...magic, ..._length(header.length), ...header], flush: true);
    await temp.rename(marker.path);
    pendingBytes += 12 + header.length - oldBytes;
  }

  Future<void> _publishFinish(String recordingId) async {
    final marker = File('${directory.path}/$recordingId.finish');
    if (!await marker.exists()) return;
    if (await _promoteFinish(marker, recordingId)) pendingParts++;
    _notifyChanged();
    retry();
  }

  Future<bool> _promoteFinish(File marker, String recordingId) async {
    await _finishHeader(marker, recordingId);
    final ready = File('${directory.path}/$recordingId.ready');
    if (await ready.exists()) {
      if (!listEquals(await marker.readAsBytes(), await ready.readAsBytes())) {
        throw const FormatException('Conflicting local group finish');
      }
      final bytes = await marker.length();
      await marker.delete();
      pendingBytes -= bytes;
      return false;
    }
    await marker.rename(ready.path);
    return true;
  }

  LocalAudioRecording beginForServer({required String source, required String codec, required String serverId}) {
    if (!const {'omi:opus', 'omi:opus_fs320', 'phone:pcm16'}.contains('$source:$codec')) {
      throw StateError('Unsupported local recording format');
    }
    captureIssue = null;
    final silence = groupSilence?.call();
    if (silence != null && !groupSilenceChoices.contains(silence)) throw ArgumentError.value(silence);
    final recording = LocalAudioRecording._(this, source, codec, serverId, silence, filtersNewAudio);
    _recordings.add(recording);
    return recording;
  }

  /// Publish a recovered interval through the same receipt-checked queue as live audio.
  /// The importer supplies a deterministic identity so interrupted publication can be replayed.
  Future<void> queueRecoveredOpus({
    required String id,
    required String serverId,
    required String codec,
    required DateTime startedAt,
    required List<List<int>> packets,
    bool? reviewSpeech,
  }) => _serial(() async {
    if (!_groupUuid.hasMatch(id) ||
        !{'opus', 'opus_fs320'}.contains(codec) ||
        packets.isEmpty ||
        packets.length > maxPartPackets) {
      throw const FormatException('Invalid recovered audio part');
    }
    final header = utf8.encode(
      jsonEncode({
        'version': 2,
        if (reviewSpeech ?? filtersNewAudio) 'speech_review': 1,
        'id': id,
        'recording_id': id,
        'index': 0,
        'source': 'omi',
        'codec': codec,
        'started_at': startedAt.toUtc().toIso8601String(),
        'server_id': serverId,
        'preroll_frames': 0,
      }),
    );
    final body = typed.BytesBuilder()
      ..add(magic)
      ..add(_length(header.length))
      ..add(header);
    for (final packet in packets) {
      if (packet.isEmpty || packet.length > maxFrameBytes || body.length + packet.length + 4 > maxPartBytes) {
        throw const FormatException('Invalid recovered audio packet');
      }
      LocalAudioRecording.packetMicroseconds(codec, packet);
      body
        ..add(_length(packet.length))
        ..add(packet);
    }
    final ready = File('${directory.path}/$id.${(reviewSpeech ?? filtersNewAudio) ? 'vad' : 'ready'}');
    final bytes = body.takeBytes();
    if (await ready.exists()) {
      if (!listEquals(bytes, await ready.readAsBytes())) throw const FormatException('Recovered part conflict');
      return;
    }
    if (pendingBytes + bytes.length > maxStorageBytes) throw LocalDeliveryIssue.queueStorage;
    final temp = File('${directory.path}/$id.importing');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(ready.path);
    await _countPending();
  });

  Future<void> retrySpeechReview() async {
    await _serial(() async {
      for (final held in directory.listSync().whereType<File>().where((f) => f.path.endsWith('.held'))) {
        await held.rename(held.path.replaceFirst(RegExp(r'\.held$'), '.vad'));
      }
    });
    await drain();
  }

  bool filtersRecording(String id) => _recordings.any((r) => r.recordingId == id && r.reviewSpeech);

  void checkpointSpeech(String id) {
    for (final recording in _recordings) {
      if (recording.recordingId == id && recording.reviewSpeech) {
        unawaited(recording.checkpoint().catchError((Object _) => reportCaptureIssue('storage')));
      }
    }
  }

  void reportCaptureIssue(String? issue) {
    captureIssue = issue;
    if (!_disposed) notifyListeners();
  }

  void _notifyChanged() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _countPending() async {
    var count = 0;
    var bytes = 0;
    for (final entity in directory.listSync()) {
      if (entity is File) {
        final pending =
            entity.path.endsWith('.ready') ||
            entity.path.endsWith('.vad') ||
            entity.path.endsWith('.held') ||
            entity.path.endsWith('.part');
        if (pending) count++;
        if (pending || entity.path.endsWith('.finish')) bytes += await entity.length();
      }
    }
    pendingParts = count;
    pendingBytes = bytes;
    if (!_disposed) notifyListeners();
  }

  void retry() {
    if (_disposed) return;
    unawaited(drain());
  }

  /// Publish the flushed prefix now, without stopping input or waiting for a
  /// five-minute rotation. New packets retain this recording's next part index.
  Future<void> recoverConnection() async {
    if (_disposed) return;
    for (final recording in _recordings.toList()) {
      try {
        await recording.checkpoint();
      } catch (_) {
        // The original journal remains. Acquisition reports the latched write
        // failure instead of appending behind a damaged or unpublishable tail.
        reportCaptureIssue('storage');
      }
    }
    retry();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(recoverConnection());
  }

  Future<void> drain() {
    if (_disposed) return Future<void>.value();
    final active = _uploading;
    if (active != null) {
      _drainRequested = true;
      return active;
    }
    final run =
        (() async {
          do {
            _drainRequested = false;
            await _drain();
          } while (_drainRequested && !_disposed);
        })().whenComplete(() {
          _uploading = null;
          if (!_disposed) notifyListeners();
        });
    _uploading = run;
    return run;
  }

  /// Only locally classified packets can enter the network queue. A torn publish
  /// replays the same envelope IDs and bytes, including after a lost receipt.
  Future<void> _reviewSpeech(File staged) async {
    if (await staged.length() > maxPartBytes) throw const FormatException('Oversized speech draft');
    final bytes = await staged.readAsBytes();
    final envelope = _header(bytes);
    final header = envelope.header;
    if (header['speech_review'] != 1 || header['version'] != 2 || filterSpeech == null) {
      throw StateError('Speech review unavailable');
    }
    final packets = <Uint8List>[];
    var offset = envelope.offset;
    while (offset < bytes.length) {
      final size = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.big);
      offset += 4;
      if (size == 0 || size > maxFrameBytes || packets.length >= maxPartPackets) {
        throw const FormatException('Invalid speech draft');
      }
      packets.add(Uint8List.sublistView(bytes, offset, offset + size));
      offset += size;
    }
    final codec = header['codec'] as String;
    final preroll = header['preroll_frames'] as int;
    final ranges = await filterSpeech!(codec, packets, preroll, header['speech_pause'] as int? ?? 2);
    final started = DateTime.parse(header['started_at'] as String);
    final id = header['id'] as String;
    var next = preroll;
    var micros = 0;
    for (final range in ranges) {
      if (range.first < next || range.first >= range.end || range.end > packets.length) {
        throw const FormatException('Invalid speech interval');
      }
      while (next < range.first) {
        micros += LocalAudioRecording.packetMicroseconds(codec, packets[next++]);
      }
      final context = LocalOpusPreroll();
      if (codec != 'pcm16') {
        for (var i = (range.first - 32).clamp(0, range.first); i < range.first; i++) {
          context.remember(packets[i], LocalAudioRecording.packetMicroseconds(codec, packets[i]));
        }
      }
      final partId = const Uuid().v5(id, 'speech/${range.first}/${range.end}');
      final meta = Map<String, dynamic>.of(header)
        ..remove('speech_review')
        ..remove('speech_pause')
        ..addAll({
          'id': partId,
          'recording_id': partId,
          'index': 0,
          'started_at': started.add(Duration(microseconds: micros)).toUtc().toIso8601String(),
          'preroll_frames': context.packets.length,
        });
      final encoded = utf8.encode(jsonEncode(meta));
      final result = typed.BytesBuilder()
        ..add(magic)
        ..add(_length(encoded.length))
        ..add(encoded);
      for (final packet in [...context.packets, ...packets.getRange(range.first, range.end)]) {
        result
          ..add(_length(packet.length))
          ..add(packet);
      }
      final body = result.takeBytes();
      if (body.length > maxPartBytes) throw const FormatException('Oversized speech interval');
      final ready = File('${directory.path}/$partId.ready');
      await _serial(() async {
        if (await ready.exists()) {
          if (!listEquals(await ready.readAsBytes(), body)) throw StateError('Speech part conflict');
        } else {
          if (pendingBytes + body.length > maxStorageBytes) throw LocalDeliveryIssue.queueStorage;
          final temp = File('${ready.path}.tmp');
          await temp.writeAsBytes(body, flush: true);
          await temp.rename(ready.path);
          pendingBytes += body.length;
          pendingParts++;
        }
      });
      while (next < range.end) {
        micros += LocalAudioRecording.packetMicroseconds(codec, packets[next++]);
      }
    }
    await _serial(() async {
      await staged.delete();
      pendingBytes -= bytes.length;
      pendingParts--;
    });
  }

  Future<void> _drain() async {
    _retry?.cancel();
    final issues = <LocalDeliveryIssue>{if (_recoveryFailed) LocalDeliveryIssue.localFile};
    try {
      for (final staged in directory.listSync().whereType<File>().where((f) => f.path.endsWith('.vad'))) {
        if (_disposed) return;
        try {
          await _reviewSpeech(staged);
        } on LocalSpeechUncertain {
          await _serial(() => staged.rename(staged.path.replaceFirst(RegExp(r'\.vad$'), '.held')));
        } on LocalDeliveryIssue catch (issue) {
          issues.add(issue);
        } on FileSystemException {
          issues.add(LocalDeliveryIssue.queueStorage);
        } catch (_) {
          issues.add(LocalDeliveryIssue.speechReview);
        }
      }
      if (directory.listSync().any((entry) => entry.path.endsWith('.held')))
        issues.add(LocalDeliveryIssue.speechReview);
      final files = directory.listSync().whereType<File>().where((file) => file.path.endsWith('.ready')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        try {
          final body = await file.readAsBytes();
          if (body.length > maxPartBytes) throw const FormatException('Oversized local audio part');
          final header = _header(body).header;
          if (header.containsKey('speech_review')) throw LocalDeliveryIssue.speechReview;
          final Map<String, dynamic> receipt;
          try {
            receipt = await upload(body, header['server_id'] as String);
          } on LocalDeliveryIssue {
            rethrow;
          } on TlsException {
            throw LocalDeliveryIssue.tls;
          } on SocketException {
            throw LocalDeliveryIssue.connection;
          } on TimeoutException {
            throw LocalDeliveryIssue.connection;
          } on FormatException {
            throw LocalDeliveryIssue.receipt;
          } catch (_) {
            throw LocalDeliveryIssue.server;
          }
          if (receipt['stored'] != true ||
              receipt['id'] != header['id'] ||
              receipt['sha256'] != sha256.convert(body).toString()) {
            throw LocalDeliveryIssue.receipt;
          }
          await file.delete(); // Only this exact immutable body has been acknowledged.
          _deliveryRevision++;
          final boundary = receipt['conversation_boundary_sample'];
          if (header['version'] == 3 && header['silence_seconds'] != 0 && boundary is int && boundary > 0) {
            onConversationBoundary?.call(header['recording_id'] as String, boundary);
          }
        } on LocalDeliveryIssue catch (issue) {
          // Continue delivering the other immutable parts even if one is blocked.
          issues.add(issue);
        } on FileSystemException {
          issues.add(LocalDeliveryIssue.queueStorage);
        } catch (_) {
          issues.add(LocalDeliveryIssue.localFile);
        }
      }
    } on FileSystemException {
      issues.add(LocalDeliveryIssue.queueStorage);
    }
    try {
      await _serial(_countPending);
    } on FileSystemException {
      issues.add(LocalDeliveryIssue.queueStorage);
    } finally {
      _deliveryIssues = Set.unmodifiable(issues);
      if (!_disposed && (pendingParts > 0 || issues.contains(LocalDeliveryIssue.queueStorage))) {
        _retry = Timer(const Duration(seconds: 15), retry);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    super.dispose();
  }
}

class LocalAudioRecording {
  LocalAudioRecording._(this.outbox, this.source, this.codec, this.serverId, this.silenceSeconds, this.reviewSpeech);

  final LocalAudioJournal outbox;
  final String source;
  final String codec;
  final String serverId;
  final int? silenceSeconds;
  final bool reviewSpeech;
  bool get _grouped => silenceSeconds != null && !reviewSpeech;
  final String recordingId = const Uuid().v4();
  int _index = 0;
  File? _file;
  RandomAccessFile? _handle;
  DateTime? _started;
  DateTime? _groupStarted;
  Map<String, dynamic>? _partHeader;
  int _samples = 0;
  int _freshPackets = 0;
  int _bytes = 0;
  int _audioMicroseconds = 0;
  int _totalAudioMicroseconds = 0;
  double get audioSeconds => _totalAudioMicroseconds / 1000000;
  int _packetCount = 0;
  final _preroll = LocalOpusPreroll();
  bool _closed = false;
  bool _writeFailed = false;
  Future<void>? _stopping;

  Future<void> add(List<int> payload, {void Function()? afterPersisted}) {
    if (_closed) return Future<void>.error(StateError('Local recording is closed'));
    if (payload.isEmpty || payload.length > LocalAudioJournal.maxFrameBytes) {
      return Future<void>.error(StateError('Invalid local audio packet'));
    }
    if (outbox._queuedBytes + payload.length > outbox.maxQueuedBytes) {
      return Future<void>.error(StateError('Local audio storage cannot keep up'));
    }
    final snapshot = Uint8List.fromList(payload);
    final acceptedAt = outbox.clock().toUtc();
    final int duration;
    try {
      duration = packetMicroseconds(codec, snapshot);
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
    outbox._queuedBytes += snapshot.length;
    return outbox._serial(() async {
      try {
        if (_writeFailed) throw StateError('Local journal write failed; original part is retained');
        const groupedPartMicros = 15 * Duration.microsecondsPerSecond;
        final configuredLimit = outbox.partDuration.inMicroseconds;
        final partLimit = _grouped && (silenceSeconds ?? 0) > 0 && configuredLimit > groupedPartMicros
            ? groupedPartMicros
            : configuredLimit;
        if (_handle != null &&
            (_audioMicroseconds + duration > partLimit ||
                _packetCount >= LocalAudioJournal.maxPartPackets ||
                _bytes + snapshot.length + 4 > LocalAudioJournal.maxPartBytes)) {
          await _seal();
        }
        if (_handle == null) await _open(acceptedAt, snapshot.length + 4);
        if (outbox.pendingBytes + snapshot.length + 4 > outbox.maxStorageBytes) {
          throw StateError('Local audio storage is full; pending audio is retained');
        }
        await _handle!.writeFrom(LocalAudioJournal._length(snapshot.length));
        await _handle!.writeFrom(snapshot);
        await _handle!.flush();
        _bytes += snapshot.length + 4;
        _audioMicroseconds += duration;
        _totalAudioMicroseconds += duration;
        _samples += codec == 'pcm16' ? snapshot.length ~/ 2 : duration * 16 ~/ 1000;
        _freshPackets++;
        _packetCount++;
        outbox.pendingBytes += snapshot.length + 4;
        if (codec != 'pcm16') _preroll.remember(snapshot, duration);
        afterPersisted?.call();
      } catch (_) {
        _writeFailed = true;
        outbox.reportCaptureIssue('storage');
        rethrow;
      } finally {
        outbox._queuedBytes -= snapshot.length;
      }
    });
  }

  /// RFC 6716 section 3.1: TOC selects frame duration and packet frame count.
  /// Count audio time, independent of delivery bursts or a changing wall clock.
  static int packetMicroseconds(String codec, List<int> packet) {
    if (codec == 'pcm16') {
      if (packet.length.isOdd) throw StateError('Unaligned PCM16 packet');
      return packet.length * 1000000 ~/ 32000;
    }
    final config = packet.first >> 3;
    final duration = config < 12
        ? const [10000, 20000, 40000, 60000][config % 4]
        : config < 16
        ? const [10000, 20000][config % 2]
        : const [2500, 5000, 10000, 20000][config % 4];
    final code = packet.first & 3;
    if (code == 3 && packet.length < 2) throw StateError('Invalid Opus frame count');
    final frames = code == 0
        ? 1
        : code == 3
        ? packet[1] & 63
        : 2;
    if (frames == 0 || frames * duration > 120000) throw StateError('Invalid Opus duration');
    return duration * frames;
  }

  Future<void> _open(DateTime acceptedAt, int freshPacketBytes) async {
    final id = const Uuid().v4();
    _started = acceptedAt;
    _groupStarted ??= acceptedAt;
    _audioMicroseconds = 0;
    final preroll = _preroll.packets;
    _freshPackets = 0;
    final part = _partHeader = {
      'version': _grouped ? 3 : 2,
      if (reviewSpeech) ...{'speech_review': 1, 'speech_pause': silenceSeconds ?? 2},
      if (_grouped) ...{
        'group_version': 1,
        'kind': 'audio',
        'group_started_at': _groupStarted!.toIso8601String(),
        'silence_seconds': silenceSeconds,
        'first_sample': _samples,
      },
      'id': id,
      'recording_id': recordingId,
      'index': _index++,
      'source': source,
      'codec': codec,
      'started_at': _started!.toIso8601String(),
      'server_id': serverId,
      'preroll_frames': preroll.length,
    };
    final header = utf8.encode(jsonEncode(part));
    final openingBytes = 12 + header.length + preroll.fold<int>(0, (total, packet) => total + 4 + packet.length);
    if (outbox.pendingBytes + openingBytes + freshPacketBytes > outbox.maxStorageBytes) {
      throw StateError('Local audio storage is full; pending audio is retained');
    }
    final filename = _grouped ? '$recordingId.$id' : id;
    _file = File('${outbox.directory.path}/$filename.part');
    await _file!.create(exclusive: true);
    _handle = await (outbox.openJournal?.call(_file!) ?? _file!.open(mode: FileMode.writeOnly));
    await _handle!.writeFrom(LocalAudioJournal.magic);
    await _handle!.writeFrom(LocalAudioJournal._length(header.length));
    await _handle!.writeFrom(header);
    for (final packet in preroll) {
      await _handle!.writeFrom(LocalAudioJournal._length(packet.length));
      await _handle!.writeFrom(packet);
    }
    await _handle!.flush();
    _bytes = openingBytes;
    _packetCount = preroll.length;
    outbox.pendingBytes += _bytes;
    outbox.pendingParts++;
    outbox._notifyChanged();
  }

  Future<void> _seal() async {
    if (_handle == null) return;
    if (_writeFailed) {
      // Never append after a torn packet or publish its journal as upload-ready.
      // Recovery on restart keeps the complete prefix and trims only the tail.
      await _handle!.close();
      _handle = null;
      outbox.retry();
      return;
    }
    await _handle!.flush();
    await _handle!.close();
    _handle = null;
    if (_grouped && _freshPackets > 0) await outbox._writeFinishMarker(_partHeader!);
    await _file!.rename(_file!.path.replaceFirst(RegExp(r'\.part$'), reviewSpeech ? '.vad' : '.ready'));
    _file = null;
    outbox.retry();
  }

  Future<void> stop() {
    if (_stopping != null) return _stopping!;
    _closed = true; // Fence future hardware callbacks before draining accepted ones.
    outbox._recordings.remove(this);
    return _stopping = outbox._serial(() async {
      await _seal();
      if (_grouped && !_writeFailed) await outbox._publishFinish(recordingId);
    });
  }

  /// Seal the accepted prefix. A transport discontinuity can drop decoder
  /// context while preserving the recording identity and upload order.
  Future<void> checkpoint({bool resetOpusContext = false}) {
    if (_closed) return Future.value();
    return outbox._serial(() async {
      if (_writeFailed) return;
      try {
        await _seal();
        if (resetOpusContext) _preroll.clear();
      } catch (_) {
        _writeFailed = true;
        rethrow;
      }
    });
  }
}
