import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/offline_network_policy.dart';

class LocalMacUnauthorized implements Exception {}

typedef LocalProfileProbe = Future<Map<String, dynamic>> Function(Uri base, String key);

/// A local owner session, independent of Firebase's cached user and token timer.
class LocalMacSession extends ChangeNotifier {
  LocalMacSession({FlutterSecureStorage? storage, LocalProfileProbe? probe})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            ),
        _probe = probe ?? probeProfile;

  static final instance = LocalMacSession();
  static const storageKey = 'omi.localMacPairing.v1';
  static const settingsKey = 'omi.localMacSettings.v1';
  final FlutterSecureStorage _storage;
  final LocalProfileProbe _probe;
  Uri? _base;
  String? _key;
  bool _rejected = false;
  bool _publishing = false;

  String get address => _base?.toString() ?? '';
  bool get isSignedIn => _key != null && !_rejected;
  String? get accessKey => isSignedIn ? _key : null;

  static String normalizeKey(String key) => key.replaceAll(RegExp(r'\s'), '');

  /// Explicit installer handoff only: no embedded credentials and no network activation.
  Future<void> importLaunchSettings() async {
    if (!Env.isOfflineRuntime || defaultTargetPlatform != TargetPlatform.iOS) return;
    final saved =
        await const MethodChannel('com.omi/environment').invokeMapMethod<String, String>('takeLocalMacSettings');
    if (saved == null) return;
    final url = Env.parseLocalTunnelUrl(saved['url'] ?? '');
    final key = normalizeKey(saved['key'] ?? '');
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(key)) throw LocalMacUnauthorized();
    await saveSettings(url.toString(), key);
  }

  /// Editing settings never activates a server or changes the authenticated origin.
  Future<({String address, String key})> readSettings() async {
    final raw = await _storage.read(key: settingsKey);
    if (raw != null) {
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      return (address: saved['url'] as String, key: saved['key'] as String);
    }
    return (address: address, key: _key ?? '');
  }

  Future<void> saveSettings(String address, String key) async {
    if (!Env.isOfflineRuntime) throw StateError('Local Mac requires offline runtime');
    await _storage.write(key: settingsKey, value: jsonEncode({'url': address.trim(), 'key': normalizeKey(key)}));
  }

  Future<void> restore() async {
    if (!Env.isOfflineRuntime) return;
    final raw = await _storage.read(key: storageKey);
    if (raw == null) return;
    try {
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      _base = Env.parseLocalTunnelUrl(saved['url'] as String);
      final key = saved['key'] as String?;
      _key = key != null && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(key) ? key : null;
      _rejected = saved['rejected'] == true;
      _activate();
    } on FormatException {
      _key = null;
    } on TypeError {
      _key = null;
    }
  }

  void _activate() {
    Env.localTunnelConfigured = true;
    Env.overrideApiBaseUrl(_base!.toString());
    if (isSignedIn) SharedPreferencesUtil().uid = 'alice';
  }

  Future<void> connect(String address, String key) async {
    if (!Env.isOfflineRuntime) throw StateError('Local Mac requires offline runtime');
    key = normalizeKey(key);
    final base = Env.parseLocalTunnelUrl(address);
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(key)) throw LocalMacUnauthorized();
    final profile = await _probe(base, key);
    if (profile['uid'] != 'alice') throw LocalMacUnauthorized();
    // Persist one atomic Keychain record before publishing a new session.
    _publishing = true;
    try {
      await _storage.write(key: storageKey, value: jsonEncode({'url': base.toString(), 'key': key}));
    } finally {
      _publishing = false;
    }
    _base = base;
    _key = key;
    _rejected = false;
    _activate();
    OfflineNetworkPolicy.installFromEnv();
    notifyListeners();
  }

  bool permits(Uri uri) =>
      _base != null &&
      (uri.scheme == 'https' || uri.scheme == 'wss') &&
      uri.userInfo.isEmpty &&
      uri.host == _base!.host &&
      (uri.hasPort ? uri.port : 443) == 443;

  String authorizationFor(Uri uri) {
    if (!permits(uri) || !isSignedIn) throw LocalMacUnauthorized();
    return 'Bearer $_key';
  }

  Future<void> rejectKey() async {
    if (_rejected) return;
    _rejected = true;
    notifyListeners();
    await _storage.write(key: storageKey, value: jsonEncode({'url': address, 'key': _key, 'rejected': true}));
  }

  Future<void> rejectRequest(Uri uri, String? authorization) async {
    // A late response from the previous address/key cannot expire a new pairing.
    if (_publishing || !permits(uri) || authorization != 'Bearer $_key') return;
    await rejectKey();
  }

  Future<void> signOut() async {
    _key = null;
    _rejected = true;
    notifyListeners();
    await _storage.write(key: storageKey, value: jsonEncode({'url': address, 'rejected': true}));
    await _storage.delete(key: settingsKey);
  }

  static Future<Map<String, dynamic>> probeProfile(Uri base, String key) =>
      HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        try {
          final request = await client.getUrl(base.resolve('v1/users/profile')).timeout(const Duration(seconds: 8));
          request.followRedirects = false;
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
          final response = await request.close().timeout(const Duration(seconds: 8));
          if (response.statusCode == 401 || response.statusCode == 403) throw LocalMacUnauthorized();
          if (response.statusCode != 200) throw const HttpException('Local Mac unavailable');
          final bytes = <int>[];
          await for (final chunk in response.timeout(const Duration(seconds: 8))) {
            bytes.addAll(chunk);
            if (bytes.length > 262144) throw const FormatException('Invalid local profile');
          }
          return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        } finally {
          client.close(force: true);
        }
      }, OfflineHttpOverrides(OfflineNetworkPolicy.tunnel(base)));
}
