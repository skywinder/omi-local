import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omi/env/env.dart';
import 'package:omi/services/auth/local_mac_session.dart';
import 'package:omi/utils/offline_network_policy.dart';

import 'local_runtime_status_model.dart';

export 'local_runtime_status_model.dart';

class LocalRuntimeStatusUnavailable implements Exception {}

class LocalRuntimeStatusClient {
  LocalRuntimeStatusClient({LocalMacSession? session}) : _session = session ?? LocalMacSession.instance;

  final LocalMacSession _session;
  static const requestTimeout = Duration(seconds: 8);
  static const maxResponseBytes = 64 * 1024;

  Future<LocalRuntimeStatus> fetch() async {
    if (!Env.isOfflineRuntime || !_session.isSignedIn) throw LocalMacUnauthorized();
    final address = _session.address;
    final base = Env.parseLocalTunnelUrl(address);
    final uri = base.resolve('v1/local/status');
    final authorization = _session.authorizationFor(uri);
    return HttpOverrides.runWithHttpOverrides(() async {
      final client = HttpClient()..connectionTimeout = requestTimeout;
      try {
        // One deadline covers connection, headers and the entire bounded body.
        return await (() async {
          final request = await client.getUrl(uri);
          request.followRedirects = false;
          request.headers.set(HttpHeaders.authorizationHeader, authorization);
          final response = await request.close();
          if (response.statusCode == 401 || response.statusCode == 403) throw LocalMacUnauthorized();
          if (response.statusCode != 200 || response.contentLength > maxResponseBytes) {
            throw LocalRuntimeStatusUnavailable();
          }
          final bytes = <int>[];
          await for (final chunk in response) {
            if (bytes.length + chunk.length > maxResponseBytes) throw LocalRuntimeStatusUnavailable();
            bytes.addAll(chunk);
          }
          final status = LocalRuntimeStatus.fromJson(jsonDecode(utf8.decode(bytes)));
          if (!_session.isSignedIn || _session.address != address || _session.authorizationFor(uri) != authorization) {
            throw LocalRuntimeStatusUnavailable();
          }
          return status;
        })().timeout(requestTimeout);
      } finally {
        client.close(force: true);
      }
    }, OfflineHttpOverrides(OfflineNetworkPolicy.tunnel(base)));
  }
}
