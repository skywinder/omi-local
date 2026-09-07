import 'dart:io';
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
