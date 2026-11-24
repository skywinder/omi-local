import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'package:omi/env/env.dart';
import 'package:omi/services/auth/local_mac_session.dart';
import 'package:omi/services/capture/local_audio_journal.dart';
import 'package:omi/services/connectivity_service.dart';
import 'package:omi/utils/offline_network_policy.dart';

export 'package:omi/services/capture/local_audio_journal.dart' show LocalAudioRecording, LocalPartUploader;

class LocalAudioOutbox extends LocalAudioJournal {
  LocalAudioOutbox({
    required super.directory,
    required super.upload,
    super.openJournal,
    super.clock,
    super.partDuration,
    super.maxStorageBytes,
    super.maxQueuedBytes,
  });

  static LocalAudioOutbox? shared;
  static const magic = LocalAudioJournal.magic;
  static String serverIdentity(String address, String key) => LocalAudioJournal.serverIdentity(address, key);
  StreamSubscription<bool>? _connectionChanges;
  bool _observingLifecycle = false;

  LocalAudioRecording begin({
    required String source,
    required String codec,
    required String address,
    required String key,
  }) => beginForServer(source: source, codec: codec, serverId: serverIdentity(address, key));

  static Future<void> initializeProduction() async {
    if (!Env.isOfflineRuntime || shared != null) return;
    final documents = await getApplicationDocumentsDirectory();
    final outbox = LocalAudioOutbox(
      directory: Directory('${documents.path}/local-audio-outbox'),
      upload: uploadPairedPart,
    );
    await outbox.initialize();
    shared = outbox;
    LocalMacSession.instance.addListener(outbox.retry);
    outbox._connectionChanges = ConnectivityService().onConnectionChange.listen((connected) {
      if (connected) unawaited(outbox.recoverConnection());
    });
    WidgetsBinding.instance.addObserver(outbox);
    outbox._observingLifecycle = true;
    outbox.retry();
  }

  static Future<Map<String, dynamic>> uploadPairedPart(
    Uint8List body,
    String serverId, {
    LocalMacSession? session,
    HttpClient Function()? createClient,
  }) async {
    final paired = session ?? LocalMacSession.instance;
    if (!paired.isSignedIn || serverIdentity(paired.address, paired.accessKey!) != serverId) {
      throw const HttpException('Audio belongs to another paired server');
    }
    if (LocalAudioJournal.requiresDeliveryV2(body)) {
      await paired.ensureAudioDelivery();
      if (!paired.isSignedIn || serverIdentity(paired.address, paired.accessKey!) != serverId) {
        throw const HttpException('Audio pairing changed during capability verification');
      }
    }
    final base = Env.parseLocalTunnelUrl(paired.address);
    final uri = base.resolve('v1/local/audio/parts');
    final authorization = paired.authorizationFor(uri);
    return HttpOverrides.runWithHttpOverrides(() async {
      final client = (createClient?.call() ?? HttpClient())..connectionTimeout = const Duration(seconds: 8);
      try {
        return await (() async {
          final request = await client.postUrl(uri);
          request.followRedirects = false;
          request.headers.set(HttpHeaders.authorizationHeader, authorization);
          request.headers.contentType = ContentType.binary;
          request.contentLength = body.length;
          request.add(body);
          final response = await request.close();
          if (response.statusCode != 200) throw const HttpException('Audio delivery was not acknowledged');
          final bytes = <int>[];
          await for (final chunk in response) {
            if (bytes.length + chunk.length > 4096) throw const FormatException('Invalid audio receipt');
            bytes.addAll(chunk);
          }
          return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        })().timeout(const Duration(seconds: 35));
      } finally {
        client.close(force: true);
      }
    }, OfflineHttpOverrides(OfflineNetworkPolicy.tunnel(base)));
  }

  @override
  void dispose() {
    _connectionChanges?.cancel();
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      LocalMacSession.instance.removeListener(retry);
    }
    super.dispose();
  }
}
