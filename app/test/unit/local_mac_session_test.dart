import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/env/dev_env.dart';
import 'package:omi/services/auth/local_mac_session.dart';
import 'package:omi/services/auth_service.dart';
import 'package:omi/services/auth/auth_token_result.dart';
import 'package:omi/utils/offline_network_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'https://synthetic.ngrok.app/';
  final key = List.filled(43, 's').join();
  setUpAll(() {
    Env.init(DevEnv());
    Env.setRuntimeModeForTesting(OmiRuntimeMode.offline);
  });
  tearDownAll(() => Env.setRuntimeModeForTesting(null));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    Env.localTunnelConfigured = false;
    Env.clearApiBaseUrlOverrideForTesting();
  });
  tearDown(() {
    Env.localTunnelConfigured = false;
    Env.clearApiBaseUrlOverrideForTesting();
    OfflineNetworkPolicy.resetForTesting();
  });

  test('first pairing and restart do not need a Firebase session', () async {
    final session = LocalMacSession(probe: (_, __) async => {'uid': 'alice'});
    await session.connect(url, key);
    expect(session.isSignedIn, isTrue);
    expect(SharedPreferencesUtil().uid, 'alice');
    final restored = LocalMacSession();
    await restored.restore();
    expect(restored.isSignedIn, isTrue);
    expect(restored.authorizationFor(Uri.parse('wss://synthetic.ngrok.app/v4/listen')), 'Bearer $key');
    expect(restored.address, url);
    expect(Env.usesLocalTunnel, isTrue);
    expect(session.readiness.isReady, isFalse);
    expect(session.readiness.live, 'unknown');
  });

  test('pairing admits audio while reporting separate live and final readiness', () async {
    final session = LocalMacSession(
        probe: (_, __) async => {
              'uid': 'alice',
              'local_transcription': {
                'live': {'status': 'busy'},
                'final': {'status': 'ready'}
              },
            });
    await session.connect(url, key);
    expect(session.isSignedIn, isTrue);
    expect(session.readiness.live, 'busy');
    expect(session.readiness.finalTranscript, 'ready');
    expect(session.readiness.isReady, isFalse);
    final restored = LocalMacSession();
    await restored.restore();
    expect(restored.readiness.finalTranscript, 'unknown');
    expect(
        LocalTranscriptionReadiness.fromProfile({
          'local_transcription': {'live': 1}
        }).live,
        'unknown');
  });

  test('saved settings survive restart without authenticating or switching the active server', () async {
    final session = LocalMacSession(probe: (_, __) async => {'uid': 'alice'});
    await session.connect(url, key);
    await session.saveSettings(' https://another.ngrok.app ', ' unfinished-key ');
    final restored = LocalMacSession();
    await restored.restore();
    expect(await restored.readSettings(), (address: 'https://another.ngrok.app', key: 'unfinished-key'));
    expect(restored.address, url);
    expect(restored.authorizationFor(Uri.parse(url)), 'Bearer $key');
    expect(restored.permits(Uri.parse('https://another.ngrok.app')), isFalse);
  });

  test('legacy pairing pre-fills settings and sign-out erases the saved key', () async {
    final session = LocalMacSession(probe: (_, __) async => {'uid': 'alice'});
    await session.connect(url, key);
    expect(await session.readSettings(), (address: url, key: key));
    await session.saveSettings(url, key);
    await session.signOut();
    expect((await session.readSettings()).key, isEmpty);
    expect(await const FlutterSecureStorage().read(key: LocalMacSession.settingsKey), isNull);
  });

  test('explicit native launch handoff persists settings without changing authenticated origin', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('com.omi/environment');
    Map<String, String>? handoff = {'url': url, 'key': key};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'takeLocalMacSettings');
      final value = handoff;
      handoff = null;
      return value;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
    final session = LocalMacSession();
    await session.importLaunchSettings();
    expect(await LocalMacSession().readSettings(), (address: url, key: key));
    expect(session.isSignedIn, isFalse);
    await session.saveSettings('https://changed.ngrok.app', key);
    await session.importLaunchSettings();
    expect((await session.readSettings()).address, 'https://changed.ngrok.app');
  });

  test('whitespace from pasted app keys is normalized before verification and storage', () async {
    final session = LocalMacSession(probe: (_, submitted) async {
      expect(submitted, key);
      return {'uid': 'alice'};
    });
    final pasted = ' ${key.substring(0, 20)}\n${key.substring(20)} ';
    await session.saveSettings(url, pasted);
    await session.connect(url, pasted);
    expect((await session.readSettings()).key, key);
    expect(session.accessKey, key);
  });

  test('credentials are restricted to one secure origin', () async {
    final session = LocalMacSession(probe: (_, __) async => {'uid': 'alice'});
    await session.connect(url, key);
    for (final other in [
      'https://synthetic.ngrok.app.evil.test/',
      'http://synthetic.ngrok.app/',
      'https://synthetic.ngrok.app:8000/',
      'https://key@synthetic.ngrok.app/'
    ]) {
      expect(() => session.authorizationFor(Uri.parse(other)), throwsA(isA<LocalMacUnauthorized>()));
    }
    expect(OfflineNetworkPolicy.current.allows(Uri.parse('http://127.0.0.1:9099/')), isFalse);
  });

  test('network failure keeps previous pairing; rejected key stays rejected after restart', () async {
    var available = true;
    final session = LocalMacSession(probe: (_, __) async {
      if (!available) throw const SocketException('unavailable');
      return {'uid': 'alice'};
    });
    await session.connect(url, key);
    available = false;
    await expectLater(session.connect('https://another.ngrok.app/', key), throwsA(isA<SocketException>()));
    expect(session.address, url);
    expect(session.isSignedIn, isTrue);
    await session.rejectKey();
    final restored = LocalMacSession();
    await restored.restore();
    expect(restored.address, url);
    expect(restored.isSignedIn, isFalse);
  });

  test('wrong key or owner never replaces the paired session', () async {
    final session = LocalMacSession(probe: (_, __) async => {'uid': 'bob'});
    await expectLater(session.connect(url, key), throwsA(isA<LocalMacUnauthorized>()));
    await expectLater(session.connect(url, 'wrong'), throwsA(isA<LocalMacUnauthorized>()));
    expect(session.isSignedIn, isFalse);
    expect(await const FlutterSecureStorage().read(key: LocalMacSession.storageKey), isNull);
  });

  test('late rejection from the previous address or key preserves new pairing', () async {
    final session = LocalMacSession(probe: (_, __) async => {'uid': 'alice'});
    await session.connect(url, key);
    final replacement = List.filled(43, 'r').join();
    await session.connect('https://another.ngrok.app/', replacement);
    await session.rejectRequest(Uri.parse(url), 'Bearer $key');
    await session.rejectRequest(Uri.parse(session.address), 'Bearer $key');
    expect(session.isSignedIn, isTrue);
    await session.rejectRequest(Uri.parse(session.address), 'Bearer $replacement');
    expect(session.isSignedIn, isFalse);
  });

  test('late Firebase expiry cannot clear the local owner', () async {
    final session = LocalMacSession(probe: (_, __) async => {'uid': 'alice'});
    await session.connect(url, key);
    await AuthService.instance.expireSession(
      const AuthSessionExpiredEvent(reason: AuthSessionExpirationReason.missingToken),
    );
    expect(session.isSignedIn, isTrue);
    expect(SharedPreferencesUtil().uid, 'alice');
  });
}
