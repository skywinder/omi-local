import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'archive_cache.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:omi/backend/http/api/conversations.dart';
import 'package:omi/backend/http/api_result.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/action_item.dart';
import 'package:omi/backend/schema/folder.dart';
import 'package:omi/backend/schema/gen/goals_wire.g.dart';
import 'package:omi/backend/schema/person.dart';
import 'package:omi/services/capture/local_audio_journal.dart';
import 'package:omi/services/local_runtime_status_model.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'daily_recap.dart';
import 'wav_level.dart';
import 'live_preview.dart';
import 'local_goal.dart';
import 'offline_recordings.dart';
import 'processing.dart';
import 'recording_chat.dart';
import 'recording_summary.dart';
import 'recording_edit.dart';
import 'task_due.dart';
import 'task_suggestion.dart';

enum NextServerConnection { checking, connected, unreachable, rejected, invalid }

enum LibraryFailure implements Exception { address, key, unavailable, malformed, storage }

enum CategoryBackfillFailure implements Exception { unavailable, providerChanged, invalidResult }

enum CategoryBackfillState { updated, alreadyClassified, unclassified, unavailable, changed }

typedef PlaybackRead = ({int status, int length, int? totalLength, String? contentRange, Stream<List<int>> bytes});

typedef ArchiveSearchHit = ({String id, String title, DateTime startedAt, List<TranscriptMatchSnippet> snippets});

typedef ArchiveSearchPage = ({List<ArchiveSearchHit> hits, String? nextCursor});

/// Reserves a quiet capture owner while its replacement is being committed.
/// Acquisition and capture entry points run synchronously on the same isolate.
class NextOwnerChangeGate extends ChangeNotifier {
  bool _held = false;
  bool _closed = false;
  bool Function()? _captureBusy;

  bool get permitsCapture => !_held && !_closed;
  bool get captureBusy => _captureBusy?.call() == true;

  void attachCapture(bool Function() busy) => _captureBusy = busy;

  void detachCapture(bool Function() busy) {
    if (_captureBusy == busy) _captureBusy = null;
  }

  bool tryHold() {
    if (!permitsCapture || captureBusy) return false;
    _held = true;
    notifyListeners();
    return true;
  }

  void release() {
    if (_closed || !_held) return;
    _held = false;
    notifyListeners();
  }

  void _close() {
    _closed = true;
    _captureBusy = null;
  }
}

class PairedLibrary {
  PairedLibrary(String address, String appKey, {bool knownDelivery = false})
    : origin = normalizeAddress(address),
      _key = appKey.replaceAll(RegExp(r'\s'), ''),
      audioDelivery = knownDelivery {
    if (!RegExp(r'^[a-zA-Z0-9_-]{43}$').hasMatch(_key)) throw LibraryFailure.key;
  }

  final Uri origin;
  final String _key;
  bool audioPlayback = false;
  bool audioDelivery;
  bool conversationGroups = false;
  bool recordingEdits = false;
  bool recordingArchive = false;
  bool recordingCategories = false;
  bool categoryBackfill = false;
  bool processingRetryAvailable = false;
  bool speakerLabelsAvailable = false;
  bool tasksAvailable = false;
  bool taskRemindersAvailable = false;
  bool taskSuggestionsAvailable = false;
  bool summaryRegenerationAvailable = false;
  bool summaryJobsAvailable = false;
  bool dailyRecapsAvailable = false;
  bool goalsAvailable = false;
  bool foldersAvailable = false;
  bool folderManagementAvailable = false;
  final ownerChange = NextOwnerChangeGate();
  void Function()? onKeyRejected;
  bool _closed = false;
  final connection = ValueNotifier(NextServerConnection.checking);
  bool verified = false;
  bool get isSignedIn => verified && !_closed;
  late final _archive = ConversationApi(baseUrl: origin.origin, send: _sendArchive);
  late final _archived = ConversationApi(
    baseUrl: origin.origin,
    send: (request) => _sendArchive(request, archivedOnly: true),
  );
  late final _savedRecording = ConversationApi(
    baseUrl: origin.origin,
    send: (request) => _sendArchive(request, resolveLocalRecording: true),
  );
  Future<void>? _checking;
  late final _audioOrigin = _readAudioOrigin();
  final _clients = <HttpClient>{};
  final _previews = <WebSocket>{};
  final _taskDues = <String, LocalTaskDue>{};
  String get audioOwnerId => sha256.convert(utf8.encode(jsonEncode([origin.toString(), _key]))).toString();
  late final offlineRecordings = NextOfflineRecordings(audioOwnerId);
  bool get canOpenOffline => !_closed;

  void close() {
    if (_closed) return;
    _closed = true;
    connection.dispose();
    ownerChange._close();
    verified = false;
    audioDelivery = false;
    conversationGroups = false;
    audioPlayback = false;
    recordingEdits = false;
    recordingArchive = false;
    recordingCategories = false;
    categoryBackfill = false;
    processingRetryAvailable = false;
    speakerLabelsAvailable = false;
    tasksAvailable = false;
    taskRemindersAvailable = false;
    _taskDues.clear();
    taskSuggestionsAvailable = false;
    summaryRegenerationAvailable = false;
    summaryJobsAvailable = false;
    dailyRecapsAvailable = false;
    goalsAvailable = false;
    foldersAvailable = false;
    folderManagementAvailable = false;
    for (final client in _clients) {
      client.close(force: true);
    }
    for (final socket in _previews) {
      abortPairedPreview(socket);
    }
    _previews.clear();
  }

  static const pageSize = 30;
  static const _deadline = Duration(seconds: 15);

  // The Next journal and credentials belong to this installation's service.
  static const legacyPairingKey = 'verified-pair.v1';
  static const pairingStorage = FlutterSecureStorage(
    iOptions: IOSOptions(accountName: 'omi-local-next', accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  static Uri normalizeAddress(String raw) {
    final input = raw.trim();
    final match = RegExp(r'^(?:(http)://)?([0-9.]+)(?::([0-9]+))?/?$').firstMatch(input);
    if (match != null) {
      final host = match[2]!;
      final octets = host.split('.').map(int.tryParse).toList();
      final canonical =
          octets.length == 4 && octets.every((v) => v != null && v >= 0 && v <= 255) && octets.join('.') == host;
      final tailnet = canonical && octets[0] == 100 && octets[1]! >= 64 && octets[1]! <= 127;
      final loopback = host == '127.0.0.1' && match[1] != null;
      final port = match[3] == null ? (match[1] == null ? 20000 : 80) : int.tryParse(match[3]!);
      if ((tailnet || loopback) && port != null && port > 0 && port <= 65535) {
        return Uri(scheme: 'http', host: host, port: port);
      }
    }
    final url = Uri.tryParse(input);
    if (url == null ||
        url.scheme != 'https' ||
        !url.host.contains('.') ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        (url.path.isNotEmpty && url.path != '/') ||
        url.port != 443) {
      throw LibraryFailure.address;
    }
    return Uri(scheme: 'https', host: url.host);
  }

  Future<bool> hasRetainedAudio() => retainedAudioFor(audioOwnerId);

  static final _captureReleases = <String, Future<void>>{};

  static void trackAudioRelease(String ownerId, Future<void> release) {
    _captureReleases[ownerId] = release;
    // A failed teardown leaves custody uncertain until the next recovery.
    unawaited(
      release.then<void>((_) {
        if (identical(_captureReleases[ownerId], release)) _captureReleases.remove(ownerId);
      }, onError: (Object _, StackTrace __) {}),
    );
  }

  static Future<bool> retainedAudioFor(String ownerId, {Directory? documents}) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(ownerId)) throw LibraryFailure.storage;
    try {
      // Revocation can detach the capture view while accepted bytes are still sealing.
      await _captureReleases[ownerId];
      final base = documents ?? await getApplicationDocumentsDirectory();
      final queue = Directory('${base.path}/outbox/$ownerId');
      return await queue.list(followLinks: false).any((entry) {
        return entry.path.endsWith('.part') || entry.path.endsWith('.ready') || entry.path.endsWith('.finish');
      });
    } on PathNotFoundException {
      return false;
    } catch (_) {
      throw LibraryFailure.storage;
    }
  }

  HttpClient _directClient() {
    final client = HttpClient()..connectionTimeout = _deadline;
    _clients.add(client);
    client.findProxy = (target) {
      if (target.origin != origin.origin) throw LibraryFailure.address;
      return 'DIRECT';
    };
    return client;
  }

  void _rejectKey() {
    if (_closed) return;
    unawaited(NextArchiveCache(audioOwnerId).write([]));
    unawaited(offlineRecordings.clear());
    close();
    onKeyRejected?.call();
  }

  Future<T> _request<T>(
    String path,
    Future<T> Function(HttpClientResponse) read, {
    Map<String, String>? query,
    Uint8List? body,
    ContentType? bodyType,
    String? method,
    Duration? overallTimeout,
    Object Function(int status)? statusFailure,
    bool readHttpErrors = false,
    Map<String, String> headers = const {},
  }) async {
    if (_closed) throw LibraryFailure.key;
    final uri = origin.replace(path: path, queryParameters: query);
    final client = _directClient();
    Future<T> send() async {
      final req = await client.openUrl(method ?? (body == null ? 'GET' : 'POST'), uri).timeout(_deadline);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_key');
      headers.forEach(req.headers.set);
      if (body != null) {
        req.headers.contentType = bodyType ?? ContentType.binary;
        req.contentLength = body.length;
        req.add(body);
      }
      final response = await req.close().timeout(overallTimeout ?? _deadline);
      final status = response.statusCode;
      if (status == 401 || (status == 403 && statusFailure == null)) {
        _rejectKey();
        throw LibraryFailure.key;
      }
      if (status != 200 && !readHttpErrors) throw statusFailure?.call(status) ?? LibraryFailure.unavailable;
      return read(response);
    }

    try {
      final response = send();
      return await (overallTimeout == null ? response : response.timeout(overallTimeout));
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Future<WebSocket> connectPreview(String serverId, String source, String codec) async {
    if (_closed || serverId != audioOwnerId) throw LibraryFailure.key;
    if (!verified) await verify();
    final audioOrigin = await _audioOrigin;
    if (_closed || !audioDelivery) throw LibraryFailure.unavailable;
    final client = _directClient();
    try {
      final socket = await upgradePairedPreview(client, origin, _key, source, codec, audioOrigin: audioOrigin);
      if (_closed) {
        abortPairedPreview(socket);
        throw LibraryFailure.key;
      }
      _previews.add(socket);
      unawaited(
        socket.done.then<void>(
          (_) => _previews.remove(socket),
          onError: (Object _, StackTrace __) => _previews.remove(socket),
        ),
      );
      return socket;
    } on WebSocketException catch (error) {
      if (error.httpStatusCode == 401 || error.httpStatusCode == 403) _rejectKey();
      rethrow;
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Future<Uint8List> _bytes(HttpClientResponse response, int limit) async {
    if (response.contentLength > limit) throw LibraryFailure.malformed;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_deadline)) {
      if (bytes.length + chunk.length > limit) throw LibraryFailure.malformed;
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<dynamic> _json(HttpClientResponse response, int limit) async =>
      jsonDecode(utf8.decode(await _bytes(response, limit)));

  Future<void> verify() => _checking ??= _verifyConnection().whenComplete(() => _checking = null);

  Future<void> _verifyConnection() async {
    try {
      await _verify();
      if (!_closed) connection.value = NextServerConnection.connected;
    } catch (error) {
      if (!_closed) {
        connection.value = switch (error) {
          LibraryFailure.key => NextServerConnection.rejected,
          LibraryFailure.malformed => NextServerConnection.invalid,
          _ => NextServerConnection.unreachable,
        };
      }
      rethrow;
    }
  }

  Future<LocalRuntimeStatus?> readRuntimeStatus() => _request(
    '/v1/local/status',
    (response) async {
      if (_closed) throw LibraryFailure.key;
      final code = response.statusCode;
      if (code == 404 || code == 405 || code == 501) return null;
      if (code != 200) throw LibraryFailure.unavailable;
      final value = LocalRuntimeStatus.fromJson(await _json(response, 64 << 10));
      if (_closed) throw LibraryFailure.key;
      return value;
    },
    readHttpErrors: true,
    overallTimeout: const Duration(seconds: 8),
  );

  NextProcessingClient processingClient({bool Function()? permitsActivation}) => NextProcessingClient(
    read: readProcessing,
    activatePrepared: activateProcessing,
    draftRequest: requestProcessingDraft,
    summaryTemplatesRequest: requestSummaryTemplates,
    permitsActivation: permitsActivation,
  );

  Future<Map<String, dynamic>> readProcessing() => _processing('');

  Future<Map<String, dynamic>> requestSummaryTemplates(Map<String, dynamic>? body) =>
      _processing('/summary-settings', body: body, writes: body != null, payloadLimit: 1024 * 1024);

  Future<({int revision, int speakers})?> readLiveTuning() async {
    try {
      return _decodeLiveTuning(await _processing('/live-tuning'));
    } on NextProcessingFailure catch (error) {
      if (error == NextProcessingFailure.unsupported) return null;
      rethrow;
    }
  }

  Future<({int revision, int speakers})> setLiveSpeakerLimit(int revision, int speakers) async {
    if (revision < 0 || speakers < 1 || speakers > 4 || !ownerChange.permitsCapture) {
      throw NextProcessingFailure.invalid;
    }
    final wire = await _processing(
      '/live-tuning',
      body: {'revision': revision, 'max_speakers': speakers},
      writes: true,
    );
    final saved = _decodeLiveTuning(wire, failure: NextProcessingFailure.indeterminate);
    if (saved == null || saved.revision <= revision || saved.speakers != speakers) {
      throw NextProcessingFailure.indeterminate;
    }
    return saved;
  }

  static ({int revision, int speakers})? _decodeLiveTuning(
    Map<String, dynamic> data, {
    NextProcessingFailure failure = NextProcessingFailure.unavailable,
  }) {
    if (data['available'] == false) return null;
    final revision = data['revision'];
    final settings = data['settings'];
    final speakers = settings is Map ? settings['max_speakers'] : null;
    if (data['available'] != true ||
        revision is! int ||
        revision < 0 ||
        speakers is! int ||
        speakers < 1 ||
        speakers > 4) {
      throw failure;
    }
    return (revision: revision, speakers: speakers);
  }

  Future<Map<String, dynamic>> activateProcessing(Map<String, dynamic> body) => _processing(
    '/activate',
    body: body,
    writes: true,
    profileBound: true,
    // The paired router allows preparation of a local provider for up to 700 seconds.
    timeout: const Duration(seconds: 720),
  );

  Future<Map<String, dynamic>> requestProcessingDraft(
    NextDraftOperation operation,
    Map<String, dynamic> body,
    String? profileId,
  ) async {
    if (operation == NextDraftOperation.delete) {
      final revision = body['revision'];
      if (profileId == null ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(profileId) ||
          body.length != 1 ||
          revision is! int ||
          revision < 0) {
        throw NextProcessingFailure.invalid;
      }
      return _processing(
        '/profiles/$profileId',
        method: 'DELETE',
        body: body,
        writes: true,
        profileBound: true,
        timeout: const Duration(seconds: 60),
      );
    }
    if (profileId != null) throw NextProcessingFailure.invalid;
    return _processing(
      '/${operation.name}',
      body: body,
      writes: operation == NextDraftOperation.save,
      timeout: const Duration(seconds: 60),
    );
  }

  Future<Map<String, dynamic>> _processing(
    String suffix, {
    Map<String, dynamic>? body,
    String? method,
    bool writes = false,
    bool profileBound = false,
    Duration timeout = _deadline,
    int payloadLimit = 64 * 1024,
  }) async {
    try {
      final payload = body == null ? null : Uint8List.fromList(utf8.encode(jsonEncode(body)));
      if (payload != null && payload.length > payloadLimit) throw NextProcessingFailure.invalid;
      final data = await _request(
        '/v1/local/processing$suffix',
        (response) => _json(response, 2 * 1024 * 1024),
        body: payload,
        bodyType: ContentType.json,
        method: method,
        overallTimeout: timeout,
        statusFailure: (status) => switch (status) {
          404 when profileBound => NextProcessingFailure.conflict,
          404 || 405 || 501 => NextProcessingFailure.unsupported,
          409 => NextProcessingFailure.conflict,
          400 || 403 || 413 || 422 => NextProcessingFailure.invalid,
          _ => writes ? NextProcessingFailure.indeterminate : NextProcessingFailure.unavailable,
        },
      );
      if (_closed) throw NextProcessingFailure.unauthorized;
      if (data is! Map<String, dynamic>) throw LibraryFailure.malformed;
      return data;
    } on NextProcessingFailure {
      rethrow;
    } catch (error) {
      if (_closed || error == LibraryFailure.key) throw NextProcessingFailure.unauthorized;
      throw writes ? NextProcessingFailure.indeterminate : NextProcessingFailure.unavailable;
    }
  }

  Future<void> _verify() async {
    final data = await _request('/v1/users/profile', (r) => _json(r, 256 * 1024));
    if (data is! Map || data['uid'] != 'alice') throw LibraryFailure.malformed;
    if (_closed) throw LibraryFailure.key;
    verified = true;
    audioDelivery = data['local_audio_delivery_version'] == 2;
    conversationGroups = audioDelivery && data['local_conversation_group_version'] == 1;
    audioPlayback = data['local_audio_playback_version'] == 1;
    recordingEdits = data['local_recording_edits_version'] == 1;
    recordingArchive = recordingEdits && data['local_recording_archive_version'] == 1;
    recordingCategories = recordingEdits && data['local_recording_categories_version'] == 1;
    categoryBackfill = recordingCategories && data['local_category_backfill_version'] == 1;
    processingRetryAvailable = data['local_processing_retry_version'] == 1;
    speakerLabelsAvailable = data['local_speaker_labels_version'] == 1;
    tasksAvailable = data['local_tasks_version'] == 1;
    taskRemindersAvailable = tasksAvailable && data['local_task_reminders_version'] == 1;
    taskSuggestionsAvailable = data['local_task_suggestions_version'] == 1;
    summaryRegenerationAvailable = data['local_summary_regeneration_version'] == 1;
    summaryJobsAvailable = data['local_summary_jobs_version'] == 1;
    dailyRecapsAvailable = data['local_daily_recaps_version'] == 1;
    goalsAvailable = data['local_goals_version'] == 1;
    folderManagementAvailable = data['local_folders_version'] == 2;
    foldersAvailable = folderManagementAvailable || data['local_folders_version'] == 1;
  }

  static final _archiveId = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');
  static const _archivePath = '/v1/conversations';
  static const _archiveStatuses = [
    ConversationStatus.processing,
    ConversationStatus.completed,
    ConversationStatus.failed,
  ];

  Future<http.Response> _sendArchive(
    ApiRequest request, {
    bool resolveLocalRecording = false,
    bool archivedOnly = false,
  }) async {
    if (!isSignedIn) throw LibraryFailure.key;
    final uri = Uri.parse(request.url);
    if (request.method != 'GET' ||
        request.body.isNotEmpty ||
        uri.origin != origin.origin ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw LibraryFailure.address;
    }
    final collection = uri.path == _archivePath;
    final query = uri.queryParameters;
    if (collection) {
      final hasStarred = query['starred'] == 'true';
      final folder = query['folder_id'];
      if (query.length != 4 + (hasStarred ? 1 : 0) + (folder == null ? 0 : 1) ||
          (folder != null && !_folderId.hasMatch(folder)) ||
          (query.containsKey('starred') && !hasStarred) ||
          uri.queryParametersAll.values.any((values) => values.length != 1) ||
          query['limit'] != '$pageSize' ||
          query['include_discarded'] != 'true' ||
          query['statuses'] != 'processing,completed,failed' ||
          (int.tryParse(query['offset'] ?? '') ?? -1) < 0) {
        throw LibraryFailure.malformed;
      }
    } else if (uri.pathSegments.length != 3 || uri.hasQuery || uri.path != _conversation(uri.pathSegments.last)) {
      throw LibraryFailure.malformed;
    }
    // Only the paired origin's bearer header is supplied by _request. Hosted Home ownership,
    // cache and other headers generated for the cloud app have no meaning on this server.
    return _request(
      uri.path,
      (response) async {
        if (response.statusCode != 200) {
          if (response.statusCode < 300) throw LibraryFailure.unavailable;
          return http.Response('', response.statusCode);
        }
        final headers = <String, String>{'content-type': 'application/json; charset=utf-8'};
        if (collection) {
          for (final name in ['x-omi-list-truncated', 'x-omi-conversation-page-size', 'x-omi-has-more']) {
            final values = response.headers[name];
            if (values != null && values.length == 1) headers[name] = values.single;
          }
        }
        return http.Response.bytes(await _bytes(response, collection ? 8 << 20 : 24 << 20), 200, headers: headers);
      },
      query: collection
          ? {...query, 'list_fields_only': 'true', if (archivedOnly) 'archived_only': 'true'}
          : resolveLocalRecording
          ? {'resolve_local_recording': 'true', 'include_recording_results': 'true'}
          : {'include_recording_results': 'true'},
      readHttpErrors: true,
      overallTimeout: _deadline,
    );
  }

  static LibraryFailure _archiveFailure(ApiProblem problem) => switch (problem.kind) {
    ApiProblemKind.authTerminal || ApiProblemKind.forbidden => LibraryFailure.key,
    ApiProblemKind.decode => LibraryFailure.malformed,
    _ => LibraryFailure.unavailable,
  };

  Future<({List<ServerConversation> rows, int consumed, bool partial, bool more})> list(
    int offset, {
    bool starredOnly = false,
    bool archivedOnly = false,
    String? folderId,
  }) async {
    if (offset < 0) throw LibraryFailure.malformed;
    if (archivedOnly && !recordingArchive) throw LibraryFailure.unavailable;
    var storageCount = 0;
    bool? hasMore;
    final result = await (archivedOnly ? _archived : _archive).list(
      limit: pageSize,
      offset: offset,
      statuses: _archiveStatuses,
      includeDiscarded: true,
      starred: starredOnly ? true : null,
      folderId: folderId,
      onStorageCount: (value) => storageCount = value,
      onPageHeaders: (headers) => hasMore = headers.hasMore,
    );
    if (!isSignedIn) throw LibraryFailure.key;
    switch (result) {
      case ApiFailure(:final problem):
        throw _archiveFailure(problem);
      case ApiSuccess(:final data, :final rejectedRows, :final truncated):
        final rows = data.where((row) => _archiveId.hasMatch(row.id)).toList();
        if ((data.isNotEmpty && rows.isEmpty) || (archivedOnly && rows.any((row) => !row.archived))) {
          throw LibraryFailure.malformed;
        }
        final received = data.length + rejectedRows;
        if (storageCount < received || storageCount > pageSize) throw LibraryFailure.malformed;
        return (
          rows: rows,
          consumed: storageCount,
          partial: truncated || rows.length != received,
          // Older Local servers only signal a cut-short read, without an end-of-list header.
          more: storageCount > 0 && (hasMore ?? (storageCount >= pageSize || truncated)),
        );
    }
  }

  static String _conversation(String id) {
    if (!_archiveId.hasMatch(id)) throw LibraryFailure.malformed;
    return '$_archivePath/$id';
  }

  Future<ServerConversation> detail(String id) => _readDetail(id, resolveLocalRecording: false);

  Future<ServerConversation> refreshSavedRecording(String id) => _readDetail(id, resolveLocalRecording: true);

  // The archive has a separate, stable alias for the results of a delivery group.
  static String savedGroupResultsId(String recordingId) => const Uuid().v5(recordingId, 'waiting-for-parts');

  Future<ServerConversation> _readDetail(String id, {required bool resolveLocalRecording}) async {
    _conversation(id);
    try {
      final result = await (resolveLocalRecording ? _savedRecording : _archive).byId(id);
      if (!isSignedIn) throw LibraryFailure.key;
      switch (result) {
        case ApiFailure(:final problem):
          throw _archiveFailure(problem);
        case ApiSuccess(:final data):
          if (data.id != id &&
              (!resolveLocalRecording ||
                  !_archiveId.hasMatch(data.id) ||
                  data.externalIntegration?.localTranscript == null ||
                  data.status != ConversationStatus.completed)) {
            throw LibraryFailure.malformed;
          }
          return data;
      }
    } on TypeError {
      // Domain model normalization also rejects incompatible JSON field types.
      throw LibraryFailure.malformed;
    }
  }

  Future<void> retryProcessing(String id) async {
    _conversation(id);
    if (!isSignedIn || !processingRetryAvailable) throw LibraryFailure.unavailable;
    await _request('/v1/local/conversations/$id/retry-processing', (response) async {
      final data = await _json(response, 4096);
      if (data is! Map || !const {'pending', 'processing'}.contains(data['status'])) throw LibraryFailure.malformed;
    }, method: 'POST');
  }

  Future<ServerConversation> editRecording(String id, RecordingEdit edit) async {
    if (!isSignedIn) throw LibraryFailure.key;
    if (!recordingEdits ||
        (edit.field == 'category' && !recordingCategories) ||
        (edit.field == 'archived' && !recordingArchive)) {
      throw RecordingEditFailure.unavailable;
    }
    _conversation(id);
    try {
      final row = await _request(
        '/v1/local/conversations/$id/edit',
        (response) async {
          if (response.statusCode == HttpStatus.conflict) throw RecordingEditFailure.conflict;
          if (response.statusCode == HttpStatus.requestEntityTooLarge) throw RecordingEditFailure.transcriptEditLimit;
          if (response.statusCode == HttpStatus.serviceUnavailable) throw RecordingEditFailure.transcriptUnavailable;
          if (response.statusCode != HttpStatus.ok) throw RecordingEditFailure.unavailable;
          final data = await _json(response, 24 << 20) as Map<String, dynamic>;
          final row = ServerConversation.fromJson(data['conversation'] as Map<String, dynamic>);
          if (row.id != id || (edit.field == 'archived' && row.archived != edit.value)) throw LibraryFailure.malformed;
          return row;
        },
        method: 'PATCH',
        body: Uint8List.fromList(utf8.encode(jsonEncode(edit.wire))),
        bodyType: ContentType.json,
        readHttpErrors: true,
        overallTimeout: _deadline,
      );
      if (!isSignedIn) throw LibraryFailure.key;
      return row;
    } on TypeError {
      throw LibraryFailure.malformed;
    } on FormatException {
      throw LibraryFailure.malformed;
    }
  }

  Future<RecordingChatProvider?> categoryBackfillProvider() async {
    final data = await _categoryBackfillRequest();
    if (data is! Map<String, dynamic> || !data.containsKey('provider')) throw CategoryBackfillFailure.invalidResult;
    final provider = data['provider'];
    return provider == null ? null : RecordingChatProvider.fromJson(provider as Map<String, dynamic>);
  }

  Future<List<CategoryBackfillState>> classifyRecordingCategories(List<String> ids, String binding) async {
    if (ids.isEmpty || ids.length > 8 || ids.toSet().length != ids.length) throw LibraryFailure.malformed;
    ids.forEach(_conversation);
    final data = await _categoryBackfillRequest({'recording_ids': ids, 'provider_binding': binding});
    if (data is! List || data.length != ids.length) throw CategoryBackfillFailure.invalidResult;
    final results = <CategoryBackfillState>[];
    for (var i = 0; i < ids.length; i++) {
      final item = data[i];
      if (item is! Map || item['id'] != ids[i]) throw CategoryBackfillFailure.invalidResult;
      results.add(switch (item['state']) {
        'updated' => CategoryBackfillState.updated,
        'already_classified' => CategoryBackfillState.alreadyClassified,
        'unclassified' => CategoryBackfillState.unclassified,
        'unavailable' => CategoryBackfillState.unavailable,
        'changed' => CategoryBackfillState.changed,
        _ => throw CategoryBackfillFailure.invalidResult,
      });
    }
    return results;
  }

  Future<dynamic> _categoryBackfillRequest([Map<String, dynamic>? body]) async {
    if (!isSignedIn) throw LibraryFailure.key;
    if (!categoryBackfill) throw CategoryBackfillFailure.unavailable;
    final data = await _request(
      '/v1/local/conversations/classify-categories',
      (response) async {
        if (response.statusCode == HttpStatus.conflict) throw CategoryBackfillFailure.providerChanged;
        if (response.statusCode == HttpStatus.badGateway) throw CategoryBackfillFailure.invalidResult;
        if (response.statusCode != HttpStatus.ok) throw CategoryBackfillFailure.unavailable;
        return _json(response, 32 << 10);
      },
      body: body == null ? null : Uint8List.fromList(utf8.encode(jsonEncode(body))),
      bodyType: body == null ? null : ContentType.json,
      readHttpErrors: true,
      overallTimeout: Duration(seconds: body == null ? 15 : 105),
    );
    if (!isSignedIn) throw LibraryFailure.key;
    return data;
  }

  static final _folderId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  LocalTaskDue? taskDue(String id) => _taskDues[id];

  void _rememberTaskDue(Map<String, dynamic> data) {
    final id = data['id'];
    if (!isSignedIn || id is! String) return;
    final due = LocalTaskDue.fromTask(data);
    if (due == null) {
      _taskDues.remove(id);
    } else {
      _taskDues[id] = due;
    }
  }

  Future<ActionItemsResponse> readTasks(int offset) async {
    if (!isSignedIn || !tasksAvailable) throw LibraryFailure.unavailable;
    final page = await _request(
      '/v1/action-items',
      (response) async {
        final data = await _json(response, 1 << 20) as Map<String, dynamic>;
        final page = ActionItemsResponse.fromJson(data);
        if (data['action_items'] case final List rows) {
          for (final row in rows.whereType<Map<String, dynamic>>()) {
            _rememberTaskDue(row);
          }
        }
        return page;
      },
      query: {'offset': '$offset', 'limit': '30'},
      overallTimeout: _deadline,
    );
    if (!isSignedIn) throw LibraryFailure.key;
    return page;
  }

  Future<ActionItemWithMetadata> readTask(String id) => _taskRequest(id: id, method: 'GET');

  Future<List<LocalTaskReminder>> readTaskReminders() async {
    if (!isSignedIn || !taskRemindersAvailable) throw LibraryFailure.unavailable;
    final items = await _request('/v1/local/action-items/reminders/schedule', (response) async {
      final data = await _json(response, 128 << 10);
      if (data is! List || data.length > 96) throw LibraryFailure.malformed;
      final reminders = <LocalTaskReminder>[];
      final ids = <String>{};
      for (final row in data) {
        if (row is! Map ||
            row['id'] is! String ||
            row['description'] is! String ||
            row['exact_time'] is! bool ||
            row['notify_at'] is! String) {
          throw LibraryFailure.malformed;
        }
        final id = row['id'] as String;
        final description = row['description'] as String;
        final at = DateTime.tryParse(row['notify_at'] as String);
        if (!_folderId.hasMatch(id) ||
            !ids.add(id) ||
            description.isEmpty ||
            description.length > 400 ||
            at == null ||
            !at.isUtc) {
          throw LibraryFailure.malformed;
        }
        reminders.add((id: id, description: description, at: at, exact: row['exact_time'] as bool));
      }
      return reminders;
    });
    if (!isSignedIn) throw LibraryFailure.key;
    return items;
  }

  Future<ActionItemWithMetadata> createTask(
    String requestId,
    String description, {
    String? conversationId,
    String? segmentId,
    String? segmentSha256,
  }) => _taskRequest(
    method: 'POST',
    data: {
      'request_id': requestId,
      'description': description,
      if (conversationId != null) 'conversation_id': conversationId,
      if (segmentId != null) 'segment_id': segmentId,
      if (segmentSha256 != null) 'segment_sha256': segmentSha256,
    },
  );

  Future<RecordingChatProvider?> readTaskSuggestionProvider(String id) => _taskSuggestionRequest(id, (data) {
    final provider = data['provider'];
    return provider == null ? null : RecordingChatProvider.fromJson(provider as Map<String, dynamic>);
  });

  Future<RecordingSummaryOptions> readSummaryOptions(String id) async =>
      RecordingSummaryOptions.fromJson(await _summaryRequest(id));

  Future<List<LocalDailyRecap>> listDailyRecaps(int offset) async {
    final data = await _dailyRecapRequest('/v1/users/daily-summaries', query: {'limit': '20', 'offset': '$offset'});
    return (data['summaries'] as List).cast<Map<String, dynamic>>().map(LocalDailyRecap.fromJson).toList();
  }

  Future<List<GeneratedGoalResponse>> listGoals() async {
    final data = await _goalRequest('/v1/goals/all', query: {'include_ended': 'true'});
    return (data as List).cast<Map<String, dynamic>>().map(GeneratedGoalResponse.fromJson).toList();
  }

  Future<LocalGoalDetail> readGoal(String id) async =>
      LocalGoalDetail.fromJson(await _goalRequest(_goalPath(id)) as Map<String, dynamic>);

  Future<void> createGoal(Map<String, Object?> body) async {
    await _goalRequest('/v1/local/goals', body: body);
  }

  Future<void> logGoalProgress(String id, Map<String, Object?> body) async {
    await _goalRequest('${_goalPath(id)}/progress', body: body);
  }

  String _goalPath(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) throw LocalGoalFailure.invalid;
    return '/v1/local/goals/$id';
  }

  Future<dynamic> _goalRequest(String path, {Map<String, String>? query, Map<String, Object?>? body}) async {
    if (!isSignedIn || !goalsAvailable) throw LocalGoalFailure.unavailable;
    final data = await _request(
      path,
      (response) => _json(response, 2 << 20),
      query: query,
      body: body == null ? null : Uint8List.fromList(utf8.encode(jsonEncode(body))),
      bodyType: ContentType.json,
      statusFailure: (status) => switch (status) {
        HttpStatus.conflict => LocalGoalFailure.conflict,
        400 || 422 => LocalGoalFailure.invalid,
        _ => LocalGoalFailure.unavailable,
      },
    );
    if (!isSignedIn) throw LibraryFailure.key;
    return data;
  }

  Future<DailyRecapPreview> previewDailyRecap(DateTime date) async =>
      DailyRecapPreview.fromJson(await _dailyRecapRequest('/v1/local/daily-recaps/preview', body: dailyRecapDay(date)));

  Future<LocalDailyRecap> generateDailyRecap(DateTime date, DailyRecapPreview preview, String id) async =>
      LocalDailyRecap.fromJson(
        await _dailyRecapRequest(
          '/v1/local/daily-recaps/generate',
          body: {
            'request_id': id,
            ...dailyRecapDay(date),
            'revision': preview.revision,
            'provider_binding': preview.provider!.binding,
          },
          timeout: const Duration(seconds: 84),
        ),
      );

  Future<Map<String, dynamic>> _dailyRecapRequest(
    String path, {
    Map<String, String>? query,
    Map<String, String>? body,
    Duration timeout = _deadline,
  }) async {
    if (!isSignedIn || !dailyRecapsAvailable) throw DailyRecapFailure.unavailable;
    final result = await _request(
      path,
      (response) async => await _json(response, 2 << 20) as Map<String, dynamic>,
      query: query,
      body: body == null ? null : Uint8List.fromList(utf8.encode(jsonEncode(body))),
      bodyType: ContentType.json,
      statusFailure: (status) =>
          status == HttpStatus.conflict ? DailyRecapFailure.changed : DailyRecapFailure.unavailable,
      overallTimeout: timeout,
    );
    if (!isSignedIn) throw LibraryFailure.key;
    return result;
  }

  Map<String, String> _summaryBody(SummaryRegeneration request) => {
    'request_id': request.requestId,
    'source_revision': request.sourceRevision,
    'provider_binding': request.binding,
    'template_id': request.templateId,
    'template_digest': request.templateDigest,
    'prompt': request.prompt,
  };

  Future<void> regenerateSummary(String id, SummaryRegeneration request) async {
    final result = await _summaryRequest(id, body: _summaryBody(request));
    if (result['request_id'] != request.requestId) throw RecordingSummaryFailure.unavailable;
  }

  Future<SummaryJob> enqueueSummary(String id, SummaryRegeneration request) async =>
      decodeSummaryJob(await _summaryRequest(id, body: _summaryBody(request), background: true));

  Future<SummaryJob> readSummaryJob(String id, String requestId) async =>
      decodeSummaryJob(await _summaryRequest(id, query: {'request_id': requestId}, background: true));

  Future<Map<String, dynamic>> _summaryRequest(
    String id, {
    Map<String, String>? body,
    Map<String, String>? query,
    bool? background,
  }) async {
    final useQueue = background ?? (body == null && summaryJobsAvailable);
    if (!isSignedIn || !(useQueue ? summaryJobsAvailable : summaryRegenerationAvailable)) {
      throw RecordingSummaryFailure.unavailable;
    }
    _conversation(id);
    final result = await _request(
      '/v1/local/conversations/$id/${useQueue ? 'summary-jobs' : 'regenerate-summary'}',
      (response) async => await _json(response, 1024 << 10) as Map<String, dynamic>,
      query: query,
      body: body == null ? null : Uint8List.fromList(utf8.encode(jsonEncode(body))),
      bodyType: ContentType.json,
      statusFailure: (status) => switch (status) {
        HttpStatus.conflict => RecordingSummaryFailure.conflict,
        HttpStatus.requestEntityTooLarge => RecordingSummaryFailure.tooLarge,
        422 => RecordingSummaryFailure.noTranscript,
        _ => RecordingSummaryFailure.unavailable,
      },
      overallTimeout: body == null || useQueue ? _deadline : const Duration(seconds: 225),
    );
    if (!isSignedIn) throw LibraryFailure.key;
    return result;
  }

  Future<TaskSuggestions> suggestTasks(String id, String binding) =>
      _taskSuggestionRequest(id, TaskSuggestions.fromJson, body: {'provider_binding': binding});

  Future<T> _taskSuggestionRequest<T>(
    String id,
    T Function(Map<String, dynamic>) parse, {
    Map<String, String>? body,
  }) async {
    if (!isSignedIn || !taskSuggestionsAvailable) throw LibraryFailure.unavailable;
    _conversation(id);
    final result = await _request(
      '/v1/local/conversations/$id/task-suggestions',
      (response) async {
        if (response.statusCode == HttpStatus.conflict) throw RecordingEditFailure.conflict;
        if (response.statusCode != HttpStatus.ok) throw LibraryFailure.unavailable;
        return parse(await _json(response, 128 << 10) as Map<String, dynamic>);
      },
      body: body == null ? null : Uint8List.fromList(utf8.encode(jsonEncode(body))),
      bodyType: ContentType.json,
      readHttpErrors: true,
      overallTimeout: body == null ? _deadline : const Duration(seconds: 100),
    );
    if (!isSignedIn) throw LibraryFailure.key;
    return result;
  }

  Future<ActionItemWithMetadata> editTask(String id, RecordingEdit edit) =>
      _taskRequest(id: id, method: 'PATCH', data: edit.wire);

  Future<ActionItemWithMetadata> _taskRequest({String? id, required String method, Map<String, Object?>? data}) async {
    if (!isSignedIn || !tasksAvailable) throw LibraryFailure.unavailable;
    if (id != null && !_folderId.hasMatch(id)) throw LibraryFailure.malformed;
    final task = await _request(
      id == null ? '/v1/local/action-items' : '/v1/local/action-items/$id',
      (response) async {
        if (response.statusCode == HttpStatus.conflict) throw RecordingEditFailure.conflict;
        if (response.statusCode != HttpStatus.ok) throw LibraryFailure.unavailable;
        final payload = await _json(response, 128 << 10) as Map<String, dynamic>;
        final task = ActionItemWithMetadata.fromJson(payload);
        if (id != null && task.id != id) throw LibraryFailure.malformed;
        _rememberTaskDue(payload);
        return task;
      },
      method: method,
      body: data == null ? null : Uint8List.fromList(utf8.encode(jsonEncode(data))),
      bodyType: ContentType.json,
      readHttpErrors: true,
      overallTimeout: _deadline,
    );
    if (!isSignedIn) throw LibraryFailure.key;
    return task;
  }

  Person _decodePerson(dynamic data) {
    final row = data as Map<String, dynamic>;
    final id = row['id'] as String;
    final name = row['name'] as String;
    if (!_folderId.hasMatch(id) || name.trim().isEmpty) throw LibraryFailure.malformed;
    final originTime = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return Person(
      id: id,
      name: name,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ?? originTime,
      updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? '') ?? originTime,
    );
  }

  Future<List<Person>> readLocalPeople() async {
    if (!isSignedIn || !speakerLabelsAvailable) throw LibraryFailure.unavailable;
    final people = await _request('/v1/local/people', (response) async {
      final raw = await _json(response, 512 << 10) as List;
      return raw.map(_decodePerson).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    });
    if (!isSignedIn) throw LibraryFailure.key;
    return people;
  }

  Future<Person> createLocalPerson(String name) async {
    if (!isSignedIn || !speakerLabelsAvailable) throw LibraryFailure.unavailable;
    final person = await _request(
      '/v1/local/people',
      (response) async => _decodePerson(await _json(response, 16 << 10)),
      body: Uint8List.fromList(utf8.encode(jsonEncode({'name': name}))),
      bodyType: ContentType.json,
    );
    if (!isSignedIn) throw LibraryFailure.key;
    return person;
  }

  Folder _decodeFolder(dynamic body) {
    final folder = Folder.fromJson(body as Map<String, dynamic>);
    if (!_folderId.hasMatch(folder.id)) throw LibraryFailure.malformed;
    return folder;
  }

  Future<List<Folder>> readFolders() async {
    if (!isSignedIn || !foldersAvailable) throw LibraryFailure.unavailable;
    return _request('/v1/local/folders', (response) async {
      final raw = await _json(response, 256 << 10) as List;
      return raw.map(_decodeFolder).toList();
    });
  }

  Future<Folder> saveFolder(String name, {String? id}) async {
    if (!isSignedIn || !foldersAvailable) throw LibraryFailure.unavailable;
    if (id != null && !_folderId.hasMatch(id)) throw LibraryFailure.malformed;
    return _request(
      id == null ? '/v1/local/folders' : '/v1/local/folders/$id',
      (response) async {
        if (response.statusCode != (id == null ? HttpStatus.created : HttpStatus.ok)) {
          throw LibraryFailure.unavailable;
        }
        final saved = _decodeFolder(await _json(response, 16 << 10));
        if (id != null && saved.id != id) throw LibraryFailure.malformed;
        return saved;
      },
      method: id == null ? 'POST' : 'PATCH',
      body: Uint8List.fromList(utf8.encode(jsonEncode({'name': name}))),
      bodyType: ContentType.json,
      readHttpErrors: true,
    );
  }

  Future<void> reorderFolders(List<String> expected, List<String> ordered) =>
      _changeFolders('/reorder', {'expected': expected, 'ordered': ordered});

  Future<void> bulkMoveFolders(Map<String, String?> expected, String? folderId) =>
      _changeFolders('/move', {'expected': expected, 'folder_id': folderId});

  Future<void> deleteFolder(String id) async {
    if (!_folderId.hasMatch(id)) throw LibraryFailure.malformed;
    await _changeFolders('/$id', null);
  }

  Future<void> _changeFolders(String suffix, Map<String, Object?>? body) async {
    if (!isSignedIn || !folderManagementAvailable) throw LibraryFailure.unavailable;
    await _request(
      '/v1/local/folders$suffix',
      (response) async {
        if (response.statusCode == HttpStatus.conflict) {
          final data = await _json(response, 4096);
          if (data is Map && data['detail'] == 'local_folder_too_many') {
            throw RecordingEditFailure.folderTooLarge;
          }
          throw RecordingEditFailure.conflict;
        }
        if (response.statusCode != HttpStatus.noContent) throw LibraryFailure.unavailable;
      },
      method: body == null ? 'DELETE' : 'POST',
      body: body == null ? null : Uint8List.fromList(utf8.encode(jsonEncode(body))),
      bodyType: ContentType.json,
      readHttpErrors: true,
      overallTimeout: const Duration(seconds: 35),
    );
    if (!isSignedIn) throw LibraryFailure.key;
  }

  Future<ArchiveSearchPage?> searchArchive(String query, {String? after, bool byMeaning = false}) async {
    if (!isSignedIn) throw LibraryFailure.key;
    if (query.isEmpty || query.runes.length > 240 || (byMeaning && after != null)) throw LibraryFailure.malformed;
    try {
      final page = await _request(
        byMeaning ? '/v1/local/conversations/semantic-search' : '/v1/local/conversations/search',
        (response) async {
          if (response.statusCode == HttpStatus.notFound) return null;
          if (byMeaning && response.statusCode == HttpStatus.serviceUnavailable) return null;
          if (await _blockedOffline(response)) return null;
          if (response.statusCode != HttpStatus.ok) throw LibraryFailure.unavailable;
          final data = await _json(response, 384 << 10) as Map<String, dynamic>;
          if (!data.containsKey('next_cursor')) throw LibraryFailure.malformed;
          final raw = data['items'] as List;
          final cursor = data['next_cursor'] as String?;
          if (raw.length > 40 || (cursor != null && (byMeaning || cursor.isEmpty || cursor == after))) {
            throw LibraryFailure.malformed;
          }
          final hits = <ArchiveSearchHit>[];
          for (final item in raw.cast<Map<String, dynamic>>()) {
            final id = item['id'] as String;
            if (!_archiveId.hasMatch(id)) throw LibraryFailure.malformed;
            hits.add((
              id: id,
              title: item['title'] as String,
              startedAt: DateTime.parse(item['started_at'] as String),
              snippets: (item['match_snippets'] as List)
                  .cast<Map<String, dynamic>>()
                  .map(TranscriptMatchSnippet.fromJson)
                  .toList(),
            ));
          }
          return (hits: hits, nextCursor: cursor);
        },
        body: Uint8List.fromList(utf8.encode(jsonEncode({'query': query, if (after != null) 'after': after}))),
        bodyType: ContentType.json,
        readHttpErrors: true,
        overallTimeout: const Duration(seconds: 12),
      );
      if (!isSignedIn) throw LibraryFailure.key;
      return page;
    } on TypeError {
      throw LibraryFailure.malformed;
    } on FormatException {
      throw LibraryFailure.malformed;
    }
  }

  Future<bool> _blockedOffline(HttpClientResponse response) async {
    if (response.statusCode != HttpStatus.serviceUnavailable ||
        response.headers.contentType?.mimeType != ContentType.json.mimeType) {
      return false;
    }
    final error = await _json(response, 4096);
    return error is Map && error['reason'] == 'offline_route_blocked';
  }

  String _chatPath(String? id) {
    if (id == null) return '/v1/local/conversations/chat';
    _conversation(id);
    return '/v1/local/conversations/$id/chat';
  }

  static const _chatThreadsPath = '/v1/local/conversations/chat/threads';

  static ArchiveChatThread _archiveChatThread(Object? value) {
    if (value is! Map || value['id'] is! String || value['title'] is! String) throw LibraryFailure.malformed;
    final id = value['id'] as String;
    final title = value['title'] as String;
    if (!_archiveId.hasMatch(id) || title.trim().isEmpty || title.runes.length > 100) throw LibraryFailure.malformed;
    return (id: id, title: title);
  }

  Future<List<ArchiveChatThread>> readArchiveChatThreads() async {
    if (!isSignedIn) throw LibraryFailure.key;
    final rows = await _request(_chatThreadsPath, (response) async {
      final data = await _json(response, 32 << 10);
      if (data is! List) throw LibraryFailure.malformed;
      return data.map(_archiveChatThread).toList();
    });
    if (!isSignedIn) throw LibraryFailure.key;
    return rows;
  }

  Future<ArchiveChatThread> createArchiveChatThread(String id, String title) async {
    if (!isSignedIn) throw LibraryFailure.key;
    if (!_archiveId.hasMatch(id)) throw LibraryFailure.malformed;
    final thread = await _request(
      _chatThreadsPath,
      (response) async {
        if (response.statusCode == HttpStatus.conflict) {
          final data = await _json(response, 4096);
          if (data is Map && data['detail'] == 'archive_chat_thread_limit') throw RecordingChatFailure.threadLimit;
          throw RecordingChatFailure.changed;
        }
        if (response.statusCode != HttpStatus.created) throw RecordingChatFailure.unavailable;
        final saved = _archiveChatThread(await _json(response, 4096));
        if (saved.id != id) throw LibraryFailure.malformed;
        return saved;
      },
      body: Uint8List.fromList(utf8.encode(jsonEncode({'id': id, 'title': title}))),
      bodyType: ContentType.json,
      readHttpErrors: true,
    );
    if (!isSignedIn) throw LibraryFailure.key;
    return thread;
  }

  Future<void> deleteArchiveChatThread(String id) async {
    if (!isSignedIn) throw LibraryFailure.key;
    if (!_archiveId.hasMatch(id)) throw LibraryFailure.malformed;
    await _request(
      '$_chatThreadsPath/$id',
      (response) async {
        if (response.statusCode != HttpStatus.noContent) throw RecordingChatFailure.unavailable;
      },
      method: 'DELETE',
      readHttpErrors: true,
      overallTimeout: const Duration(seconds: 25),
    );
    if (!isSignedIn) throw LibraryFailure.key;
  }

  Future<RecordingChatPageData?> readRecordingChat(String? id, {int? before, String? threadId}) async {
    if (!isSignedIn) throw LibraryFailure.key;
    if (threadId != null && (id != null || !_archiveId.hasMatch(threadId))) throw LibraryFailure.malformed;
    try {
      final page = await _request(
        threadId == null ? _chatPath(id) : '$_chatThreadsPath/$threadId',
        (response) async {
          if (await _blockedOffline(response)) return null;
          if (threadId != null && response.statusCode == HttpStatus.notFound) throw RecordingChatFailure.threadMissing;
          if (response.statusCode != HttpStatus.ok) throw RecordingChatFailure.unavailable;
          return RecordingChatPageData.fromJson(await _json(response, 768 << 10) as Map<String, dynamic>, id);
        },
        query: {if (id == null && threadId == null) 'stored': 'true', if (before != null) 'before': '$before'},
        readHttpErrors: true,
        overallTimeout: const Duration(seconds: 18),
      );
      if (!isSignedIn) throw LibraryFailure.key;
      return page;
    } on TypeError {
      throw LibraryFailure.malformed;
    } on FormatException {
      throw LibraryFailure.malformed;
    }
  }

  Future<RecordingChatTurn> askRecordingChat({
    required String? id,
    required String turnId,
    required String? previous,
    required String binding,
    required String question,
    List<RecordingChatTurn> history = const [],
    bool storeArchive = false,
    String? threadId,
  }) async {
    if (!isSignedIn) throw LibraryFailure.key;
    if (threadId != null && (id != null || !storeArchive || !_archiveId.hasMatch(threadId))) {
      throw LibraryFailure.malformed;
    }
    final payload = {
      'id': turnId,
      if (id != null || storeArchive) 'previous': previous,
      'provider_binding': binding,
      'question': question,
      if (id == null && storeArchive && threadId == null) 'store': true,
      if (id == null && !storeArchive)
        'history': [
          for (final turn in history.take(3)) {'question': turn.question, 'answer': turn.answer},
        ],
    };
    try {
      final turn = await _request(
        threadId == null ? _chatPath(id) : '$_chatThreadsPath/$threadId',
        (response) async {
          if (id == null && response.statusCode == HttpStatus.unprocessableEntity) {
            final error = await _json(response, 4096);
            if (error is Map) {
              if (error['detail'] == 'archive_chat_no_match') throw RecordingChatFailure.noMatches;
              if (error['detail'] == 'archive_chat_scan_limited') throw RecordingChatFailure.scanLimited;
            }
            throw RecordingChatFailure.unavailable;
          }
          if (threadId != null && response.statusCode == HttpStatus.notFound) throw RecordingChatFailure.threadMissing;
          if (response.statusCode == HttpStatus.conflict) {
            if (threadId != null) {
              final data = await _json(response, 4096);
              if (data is Map && data['detail'] == 'archive_chat_turn_limit') throw RecordingChatFailure.turnLimit;
            }
            throw RecordingChatFailure.changed;
          }
          if (await _blockedOffline(response)) {
            throw RecordingChatFailure.changed;
          }
          if (response.statusCode != HttpStatus.ok) throw RecordingChatFailure.unavailable;
          final data = await _json(response, 128 << 10) as Map<String, dynamic>;
          if (storeArchive && (data['sequence'] is! int || (data['sequence'] as int) < 1)) {
            throw RecordingChatFailure.changed;
          }
          final turn = RecordingChatTurn.fromJson(data, id);
          if (turn.id != turnId || turn.question != question) throw LibraryFailure.malformed;
          return turn;
        },
        body: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        bodyType: ContentType.json,
        readHttpErrors: true,
        overallTimeout: const Duration(seconds: 165),
      );
      if (!isSignedIn) throw LibraryFailure.key;
      return turn;
    } on TypeError {
      throw LibraryFailure.malformed;
    } on FormatException {
      throw LibraryFailure.malformed;
    }
  }

  static String _iosPhoneModel(IosDeviceInfo device) {
    // The pinned native catalog stops at iPhone 16e. These model identifiers
    // are from the Xcode device catalog. Unknown iPhones retain their model code.
    const recent = {
      'iPhone18,1': 'iPhone 17 Pro',
      'iPhone18,2': 'iPhone 17 Pro Max',
      'iPhone18,3': 'iPhone 17',
      'iPhone18,4': 'iPhone Air',
      'iPhone18,5': 'iPhone 17e',
      'iPhone19,2': 'iPhone 18 Pro',
      'iPhone19,3': 'iPhone 18 Pro Max',
    };
    final machine = device.utsname.machine;
    final modelName = device.modelName;
    if (modelName.startsWith('iPhone ')) return modelName;
    return recent[machine] ?? (RegExp(r'^iPhone[0-9]+,[0-9]+$').hasMatch(machine) ? machine : '');
  }

  static Future<Map<String, String>> _readAudioOrigin() async {
    final platform = defaultTargetPlatform;
    if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) return const {};
    final headers = {'X-App-Platform': platform == TargetPlatform.android ? 'android' : 'ios'};
    try {
      final deviceInfo = DeviceInfoPlugin();
      final model =
          await (platform == TargetPlatform.android
                  ? deviceInfo.androidInfo.then((device) => device.model)
                  : deviceInfo.iosInfo.then(_iosPhoneModel))
              .timeout(const Duration(seconds: 1));
      final label = model.trim();
      if (label.isNotEmpty && label.length <= 80 && label.toLowerCase() != 'unknown') {
        headers['X-Omi-Local-Recording-Origin'] = base64Url.encode(utf8.encode(jsonEncode({'phone_model': label})));
      }
    } catch (_) {
      // Display metadata is optional. Device info must never block audio delivery.
    }
    return headers;
  }

  Future<Map<String, dynamic>> uploadPart(Uint8List body, String serverId) async {
    if (serverId != audioOwnerId || _closed) throw LibraryFailure.key;
    // A saved v2 capability permits offline journaling; first send after launch needs a fresh profile.
    if (!verified) await verify();
    if (!audioDelivery || _closed) throw LibraryFailure.key;
    if (LocalAudioJournal.deliveryVersion(body) == 3 && !conversationGroups) throw LibraryFailure.unavailable;
    final result = await _request(
      '/v1/local/audio/parts',
      (r) => _json(r, 4096),
      body: body,
      headers: await _audioOrigin,
    );
    if (result is! Map<String, dynamic>) throw LibraryFailure.malformed;
    return result;
  }

  Future<WavLevel> readRecordingLevel(String id) async {
    if (!audioPlayback) throw LibraryFailure.unavailable;
    _conversation(id);
    return _request('/v1/local/conversations/$id/audio', (response) async {
      if (response.headers.contentType?.mimeType != 'audio/wav') throw LibraryFailure.malformed;
      const limit = gainHeaderLimit + gainSampleBytes;
      final prefix = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(_deadline)) {
        final left = limit - prefix.length;
        if (chunk.length >= left) {
          prefix.add(chunk.sublist(0, left));
          break;
        }
        prefix.add(chunk);
      }
      if (_closed) throw LibraryFailure.key;
      return WavLevel.measure(prefix.takeBytes());
    });
  }

  Future<void> readPlayback(String id, {String? range, required Future<void> Function(PlaybackRead) read}) {
    if (!isSignedIn) throw LibraryFailure.key;
    if (!audioPlayback) throw LibraryFailure.unavailable;
    _conversation(id);
    return _request(
      '/v1/local/conversations/$id/audio',
      (response) async {
        final status = response.statusCode;
        final header = response.headers.value(HttpHeaders.contentRangeHeader);
        final length = response.contentLength;
        int? total;
        switch (status) {
          case HttpStatus.ok:
            if (response.headers.value(HttpHeaders.acceptRangesHeader) == 'bytes') total = length;
          case HttpStatus.partialContent:
            final match = RegExp(r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$').firstMatch(header ?? '');
            final first = int.tryParse(match?.group(1) ?? '');
            final last = int.tryParse(match?.group(2) ?? '');
            total = int.tryParse(match?.group(3) ?? '');
            if (range == null ||
                first == null ||
                last == null ||
                total == null ||
                last >= total ||
                last < first ||
                last - first + 1 != length) {
              throw LibraryFailure.malformed;
            }
          case HttpStatus.requestedRangeNotSatisfiable:
            if (range == null || !RegExp(r'^bytes \*/[0-9]+$').hasMatch(header ?? '')) throw LibraryFailure.malformed;
            return read((
              status: status,
              length: 0,
              totalLength: null,
              contentRange: header,
              bytes: const Stream.empty(),
            ));
          default:
            throw LibraryFailure.unavailable;
        }
        if (length <= 0 || response.headers.contentType?.mimeType != 'audio/wav') throw LibraryFailure.malformed;
        await read((
          status: status,
          length: length,
          totalLength: total,
          contentRange: header,
          bytes: response.timeout(_deadline),
        ));
      },
      readHttpErrors: true,
      headers: {if (range != null) HttpHeaders.rangeHeader: range},
    );
  }

  Future<void> downloadAudio(String id, File target) async {
    if (!audioPlayback) throw LibraryFailure.unavailable;
    _conversation(id);
    await _request('/v1/local/conversations/$id/audio', (response) async {
      if (response.headers.contentType?.mimeType != 'audio/wav') throw LibraryFailure.malformed;
      final file = await target.open(mode: FileMode.write);
      try {
        await for (final chunk in response.timeout(_deadline)) {
          await file.writeFrom(chunk);
        }
      } finally {
        await file.close();
      }
    });
  }

  Future<void> saveOfflineRecording(String id) => offlineRecordings.save(
    id,
    load: () => detail(id),
    canPublish: () => isSignedIn && audioPlayback,
    download: (file, remaining) async {
      var size = 0;
      await readPlayback(
        id,
        read: (audio) async {
          if (audio.status != HttpStatus.ok || audio.length < 12) throw OfflineRecordingFailure.unavailable;
          if (audio.length > remaining) throw OfflineRecordingFailure.limit;
          final writer = await file.open(mode: FileMode.write);
          try {
            await for (final chunk in audio.bytes) {
              size += chunk.length;
              if (size > audio.length) throw OfflineRecordingFailure.unavailable;
              await writer.writeFrom(chunk);
            }
            if (size != audio.length) throw OfflineRecordingFailure.unavailable;
            await writer.flush();
          } finally {
            await writer.close();
          }
          final reader = await file.open();
          try {
            final header = ascii.decode(await reader.read(12), allowInvalid: true);
            if (!(header.startsWith('RIFF') || header.startsWith('RF64')) || !header.endsWith('WAVE')) {
              throw OfflineRecordingFailure.unavailable;
            }
          } finally {
            await reader.close();
          }
        },
      );
      return size;
    },
  );
}
