import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:omi/backend/http/api/conversations.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:path_provider/path_provider.dart';

enum OfflineRecordingFailure implements Exception { limit, unavailable }

class OfflineRecording {
  OfflineRecording._(this._directory, this.card, this.bytes);

  final Directory _directory;
  final ServerConversation card;
  final int bytes;
  File get audio => File('${_directory.path}/audio.wav');
  File get _detail => File('${_directory.path}/detail.json');

  Future<ServerConversation> readDetail() async {
    if (await _detail.length() > NextOfflineRecordings._detailLimit) throw OfflineRecordingFailure.unavailable;
    final row = await ConversationApi.decodeOffUi(await _detail.readAsString(), decodeConversationDetail);
    if (row.id != card.id || row.status != ConversationStatus.completed || row.isLocked) {
      throw OfflineRecordingFailure.unavailable;
    }
    return row;
  }
}

/// Explicit downloads are distinct from the temporary archive list and the capture outbox.
class NextOfflineRecordings {
  NextOfflineRecordings(this.owner, {Future<Directory> Function()? directory, this.limit = byteLimit})
    : _directory = directory ?? _deviceDirectory;

  static const byteLimit = 1024 * 1024 * 1024;
  static const _detailLimit = 24 * 1024 * 1024;
  static final _ownerId = RegExp(r'^[a-f0-9]{64}$');
  static final _recordingId = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');
  static Future<void> _writes = Future.value();
  final String owner;
  final int limit;
  final Future<Directory> Function() _directory;

  static Future<Directory> _deviceDirectory() async {
    if (Platform.isIOS) {
      final path = await const MethodChannel(
        'org.omilocal.next/environment',
      ).invokeMethod<String>('prepareOfflineRecordings');
      if (path == null) throw OfflineRecordingFailure.unavailable;
      return Directory(path);
    }
    return Directory('${(await getApplicationSupportDirectory()).path}/NextOfflineRecordings');
  }

  static Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _writes.then((_) => operation());
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Directory _ownerDirectory(Directory root) {
    if (!_ownerId.hasMatch(owner)) throw OfflineRecordingFailure.unavailable;
    return Directory('${root.path}/$owner');
  }

  Directory _recordingDirectory(Directory root, String id) {
    if (!_recordingId.hasMatch(id)) throw OfflineRecordingFailure.unavailable;
    return Directory('${_ownerDirectory(root).path}/$id');
  }

  static Future<Map<String, dynamic>> _readJson(File file) async {
    if (await file.length() > _detailLimit) throw OfflineRecordingFailure.unavailable;
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic>) throw OfflineRecordingFailure.unavailable;
    return value;
  }

  Future<OfflineRecording?> _read(Directory folder) async {
    try {
      final index = await _readJson(File('${folder.path}/card.json'));
      final card = ServerConversation.fromJson(index['card'] as Map<String, dynamic>);
      if (!_recordingId.hasMatch(card.id) || !folder.path.endsWith('/${card.id}') || card.isLocked) return null;
      final audioBytes = await File('${folder.path}/audio.wav').length();
      final detailBytes = await File('${folder.path}/detail.json').length();
      if (audioBytes != index['audio_bytes'] || detailBytes != index['detail_bytes']) return null;
      return OfflineRecording._(folder, card, audioBytes + detailBytes);
    } on Exception {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<OfflineRecording?> read(String id) async => _read(_recordingDirectory(await _directory(), id));

  Future<List<OfflineRecording>> list() async {
    final ownerFolder = _ownerDirectory(await _directory());
    if (!await ownerFolder.exists()) return [];
    final rows = <OfflineRecording>[];
    await for (final entity in ownerFolder.list(followLinks: false)) {
      if (entity is Directory && _recordingId.hasMatch(entity.path.split('/').last)) {
        if (await _read(entity) case final recording?) rows.add(recording);
      }
    }
    rows.sort((a, b) => b.card.createdAt.compareTo(a.card.createdAt));
    return rows;
  }

  Future<int> _bytesUsed(Directory root) async {
    if (!await root.exists()) return 0;
    var used = 0;
    await for (final ownerFolder in root.list(followLinks: false)) {
      if (ownerFolder is! Directory || !_ownerId.hasMatch(ownerFolder.path.split('/').last)) continue;
      await for (final folder in ownerFolder.list(followLinks: false)) {
        if (folder is! Directory) continue;
        if (folder.path.split('/').last.startsWith('.partial-')) {
          await folder.delete(recursive: true);
          continue;
        }
        await for (final file in folder.list(followLinks: false)) {
          if (file is File) used += await file.length();
        }
      }
    }
    return used;
  }

  Future<void> save(
    String id, {
    required Future<ServerConversation> Function() load,
    required Future<int> Function(File file, int remaining) download,
    required bool Function() canPublish,
  }) => _serial(() async {
    if (!canPublish()) throw OfflineRecordingFailure.unavailable;
    final root = await _directory();
    final target = _recordingDirectory(root, id);
    if (await _read(target) != null) return;
    final row = await load();
    if (row.id != id || row.isLocked || row.deleted || row.status != ConversationStatus.completed) {
      throw OfflineRecordingFailure.unavailable;
    }
    final local = row.externalIntegration?.localTranscript;
    final origin = local?['origin'];
    final card = {
      'id': row.id,
      'created_at': row.createdAt.toUtc().toIso8601String(),
      'started_at': row.startedAt?.toUtc().toIso8601String(),
      'finished_at': row.finishedAt?.toUtc().toIso8601String(),
      'source': row.source?.name,
      'status': row.status.name,
      'structured': {'title': row.structured.title, 'emoji': row.structured.emoji, 'category': row.structured.category},
      'external_data': {
        'local_transcript': {
          if (origin is Map)
            'origin': {
              for (final key in ['phone_model', 'phone_platform'])
                if (origin[key] is String) key: origin[key],
            },
        },
      },
    };
    final detail = utf8.encode(
      jsonEncode({
        ...card,
        'structured': row.structured.toJson(),
        'transcript_segments': row.transcriptSegments.map((line) => line.toJson()).toList(),
      }),
    );
    if (detail.length > _detailLimit) throw OfflineRecordingFailure.limit;
    final used = await _bytesUsed(root);
    final remaining = limit - used - detail.length;
    if (remaining <= 0) throw OfflineRecordingFailure.limit;
    final ownerFolder = _ownerDirectory(root);
    await ownerFolder.create(recursive: true);
    final stage = await ownerFolder.createTemp('.partial-');
    try {
      final audio = File('${stage.path}/audio.wav');
      final audioBytes = await download(audio, remaining);
      if (audioBytes <= 0 || audioBytes != await audio.length()) throw OfflineRecordingFailure.unavailable;
      final index = utf8.encode(jsonEncode({'card': card, 'audio_bytes': audioBytes, 'detail_bytes': detail.length}));
      if (audioBytes + index.length > remaining) throw OfflineRecordingFailure.limit;
      await File('${stage.path}/detail.json').writeAsBytes(detail, flush: true);
      await File('${stage.path}/card.json').writeAsBytes(index, flush: true);
      if (!canPublish()) throw OfflineRecordingFailure.unavailable;
      if (await target.exists()) await target.delete(recursive: true); // An incomplete older copy is unusable.
      await stage.rename(target.path);
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  });

  Future<void> remove(String id) => _serial(() async {
    final folder = _recordingDirectory(await _directory(), id);
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  Future<void> clear() => _serial(() async {
    try {
      final folder = _ownerDirectory(await _directory());
      if (await folder.exists()) await folder.delete(recursive: true);
    } on Exception {
      // A revoked pairing remains closed even when its private storage is unavailable.
    }
  });
}
