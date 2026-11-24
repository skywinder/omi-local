import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:omi/backend/http/api/conversations.dart';
import 'package:omi/backend/http/api_result.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/services/local_runtime_status_model.dart';
import 'package:path_provider/path_provider.dart';

import 'live_preview.dart';
import 'processing.dart';

enum LibraryFailure implements Exception { address, key, unavailable, malformed, storage }

/// Reserves a quiet capture owner while its replacement is being committed.
/// Acquisition and capture entry points run synchronously on the same isolate.
class NextOwnerChangeGate extends ChangeNotifier {
  bool _held = false;
  bool _closed = false;
  bool Function()? _captureBusy;

  bool get permitsCapture => !_held && !_closed;

  void attachCapture(bool Function() busy) => _captureBusy = busy;

  void detachCapture(bool Function() busy) {
    if (_captureBusy == busy) _captureBusy = null;
  }

  bool tryHold() {
    if (!permitsCapture || _captureBusy?.call() == true) return false;
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
  final ownerChange = NextOwnerChangeGate();
  void Function()? onKeyRejected;
  bool _closed = false;
  bool verified = false;
  bool get isSignedIn => verified && !_closed;
  late final _archive = ConversationApi(baseUrl: origin.origin, send: _sendArchive);
  Future<void>? _checking;
  final _clients = <HttpClient>{};
  final _previews = <WebSocket>{};
  String get audioOwnerId => sha256.convert(utf8.encode(jsonEncode([origin.toString(), _key]))).toString();

  void close() {
    _closed = true;
    ownerChange._close();
    verified = false;
    audioDelivery = false;
    audioPlayback = false;
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
        return entry.path.endsWith('.part') || entry.path.endsWith('.ready');
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
  }) async {
    if (_closed) throw LibraryFailure.key;
    final uri = origin.replace(path: path, queryParameters: query);
    final client = _directClient();
    Future<T> send() async {
      final req = await client.openUrl(method ?? (body == null ? 'GET' : 'POST'), uri).timeout(_deadline);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_key');
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
    if (_closed || !audioDelivery) throw LibraryFailure.unavailable;
    final client = _directClient();
    try {
      final socket = await upgradePairedPreview(client, origin, _key, source, codec);
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

  Future<void> verify() => _checking ??= _verify().whenComplete(() => _checking = null);

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
    permitsActivation: permitsActivation,
  );

  Future<Map<String, dynamic>> readProcessing() => _processing('');

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
  }) async {
    try {
      final payload = body == null ? null : Uint8List.fromList(utf8.encode(jsonEncode(body)));
      if (payload != null && payload.length > 64 * 1024) throw NextProcessingFailure.invalid;
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
    audioPlayback = data['local_audio_playback_version'] == 1;
  }

  static final _archiveId = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');
  static const _archivePath = '/v1/conversations';
  static const _archiveStatuses = [
    ConversationStatus.processing,
    ConversationStatus.completed,
    ConversationStatus.failed,
  ];

  Future<http.Response> _sendArchive(ApiRequest request) async {
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
      if (query.length != 4 ||
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
      query: collection ? query : null,
      readHttpErrors: true,
      overallTimeout: _deadline,
    );
  }

  static LibraryFailure _archiveFailure(ApiProblem problem) => switch (problem.kind) {
    ApiProblemKind.authTerminal || ApiProblemKind.forbidden => LibraryFailure.key,
    ApiProblemKind.decode => LibraryFailure.malformed,
    _ => LibraryFailure.unavailable,
  };

  Future<({List<ServerConversation> rows, int consumed, bool partial, bool more})> list(int offset) async {
    if (offset < 0) throw LibraryFailure.malformed;
    var storageCount = 0;
    bool? hasMore;
    final result = await _archive.list(
      limit: pageSize,
      offset: offset,
      statuses: _archiveStatuses,
      includeDiscarded: true,
      onStorageCount: (value) => storageCount = value,
      onPageHeaders: (headers) => hasMore = headers.hasMore,
    );
    if (!isSignedIn) throw LibraryFailure.key;
    switch (result) {
      case ApiFailure(:final problem):
        throw _archiveFailure(problem);
      case ApiSuccess(:final data, :final rejectedRows, :final truncated):
        final rows = data.where((row) => _archiveId.hasMatch(row.id)).toList();
        if (data.isNotEmpty && rows.isEmpty) throw LibraryFailure.malformed;
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

  Future<ServerConversation> detail(String id) async {
    _conversation(id);
    try {
      final result = await _archive.byId(id);
      if (!isSignedIn) throw LibraryFailure.key;
      switch (result) {
        case ApiFailure(:final problem):
          throw _archiveFailure(problem);
        case ApiSuccess(:final data):
          if (data.id != id) throw LibraryFailure.malformed;
          return data;
      }
    } on TypeError {
      // Domain model normalization also rejects incompatible JSON field types.
      throw LibraryFailure.malformed;
    }
  }

  Future<Map<String, dynamic>> uploadPart(Uint8List body, String serverId) async {
    if (serverId != audioOwnerId || _closed) throw LibraryFailure.key;
    // A saved v2 capability permits offline journaling; first send after launch needs a fresh profile.
    if (!verified) await verify();
    if (!audioDelivery || _closed) throw LibraryFailure.key;
    final result = await _request('/v1/local/audio/parts', (r) => _json(r, 4096), body: body);
    if (result is! Map<String, dynamic>) throw LibraryFailure.malformed;
    return result;
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
}
