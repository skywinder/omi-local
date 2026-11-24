import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omi/backend/schema/gen/conversation_wire.g.dart';

import 'live_preview.dart';
import 'processing.dart';

enum LibraryFailure implements Exception { address, key, unavailable, malformed, storage }

class PairedLibrary {
  PairedLibrary(String address, String appKey)
    : origin = _origin(address),
      _key = appKey.replaceAll(RegExp(r'\s'), '') {
    if (!RegExp(r'^[a-zA-Z0-9_-]{43}$').hasMatch(_key)) throw LibraryFailure.key;
  }

  final Uri origin;
  final String _key;
  bool audioPlayback = false;
  bool audioDelivery = false;
  void Function()? onKeyRejected;
  bool _closed = false;
  bool verified = false;
  Future<void>? _checking;
  final _clients = <HttpClient>{};
  final _previews = <WebSocket>{};
  String get audioOwnerId => sha256.convert(utf8.encode(jsonEncode([origin.toString(), _key]))).toString();

  void close() {
    _closed = true;
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

  // One record switches the address and key atomically. An independent Keychain service
  // also prevents legacy settings from being read when both apps use the same team.
  static const _record = 'verified-pair.v1';
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accountName: 'omi-local-next', accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  static Uri _origin(String raw) {
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

  static Future<PairedLibrary?> restore() async {
    final raw = await _storage.read(key: _record);
    if (raw == null) return null;
    final value = jsonDecode(raw);
    if (value is! Map || value['address'] is! String || value['key'] is! String) throw LibraryFailure.storage;
    return PairedLibrary(value['address'], value['key'])..audioDelivery = value['deliveryVersion'] == 2;
  }

  Future<void> save() => _storage.write(
    key: _record,
    value: jsonEncode({'address': origin.origin, 'key': _key, 'deliveryVersion': audioDelivery ? 2 : 0}),
  );
  static Future<void> forget() => _storage.delete(key: _record);

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
      if (status != 200) throw statusFailure?.call(status) ?? LibraryFailure.unavailable;
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

  Future<dynamic> _json(HttpClientResponse response, int limit) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_deadline)) {
      if (bytes.length + chunk.length > limit) throw LibraryFailure.malformed;
      bytes.add(chunk);
    }
    return jsonDecode(utf8.decode(bytes.takeBytes()));
  }

  Future<void> verify() => _checking ??= _verify().whenComplete(() => _checking = null);

  NextProcessingClient processingClient({bool Function()? permitsActivation}) => NextProcessingClient(
    read: readProcessing,
    activatePrepared: activateProcessing,
    draftRequest: requestProcessingDraft,
    permitsActivation: permitsActivation,
  );

  Future<Map<String, dynamic>> readProcessing() => _processing('');

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

  Future<({List<GeneratedConversation> rows, int consumed, bool partial, bool more})> list(int offset) =>
      _request('/v1/conversations', (response) async {
        final value = await _json(response, 8 << 20);
        if (value is! List) throw LibraryFailure.malformed;
        final rows = <GeneratedConversation>[];
        for (final item in value) {
          if (item is! Map<String, dynamic>) continue;
          try {
            rows.add(GeneratedConversation.fromJson(item));
          } on FormatException {
            continue;
          }
        }
        if (value.isNotEmpty && rows.isEmpty) throw LibraryFailure.malformed;
        final truncated = response.headers.value('X-Omi-List-Truncated') == 'true';
        return (
          rows: rows,
          consumed: value.length,
          partial: truncated || rows.length != value.length,
          more: value.isNotEmpty && (value.length >= pageSize || truncated),
        );
      }, query: {'limit': '$pageSize', 'offset': '$offset', 'statuses': 'processing,completed,failed'});

  static String _conversation(String id) {
    if (!RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$').hasMatch(id)) throw LibraryFailure.malformed;
    return '/v1/conversations/$id';
  }

  Future<GeneratedConversation> detail(String id) => _request(_conversation(id), (response) async {
    final value = await _json(response, 24 << 20);
    if (value is! Map<String, dynamic> || value['id'] != id) throw LibraryFailure.malformed;
    return GeneratedConversation.fromJson(value);
  });

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
