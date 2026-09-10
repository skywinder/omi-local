import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/env/dev_env.dart';
import 'package:omi/env/env.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/settings/local_mac_page.dart';
import 'package:omi/services/auth/local_mac_session.dart';
import 'package:omi/utils/offline_network_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    Env.init(DevEnv());
    Env.setRuntimeModeForTesting(OmiRuntimeMode.offline);
  });
  tearDownAll(() => Env.setRuntimeModeForTesting(null));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });
  tearDown(() {
    Env.localTunnelConfigured = false;
    OfflineNetworkPolicy.resetForTesting();
  });

  testWidgets('pairing screen hides key and stops capture before connecting', (tester) async {
    final order = <String>[];
    final session = LocalMacSession(probe: (_, __) async {
      order.add('probe');
      return {
        'uid': 'alice',
        'local_transcription': {
          'live': {'status': 'ready'},
          'final': {'status': 'ready'}
        },
      };
    });
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
          builder: (context) => Scaffold(
                  body: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => LocalMacPage(
                          session: session,
                          stopRecording: () async {
                            order.add('stop');
                          },
                          refreshConnection: () async {},
                        ))),
                child: const Text('Open'),
              ))),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Локальный Mac'), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const ValueKey('local-mac-key')));
    expect(field.obscureText, isTrue);
    await tester.enterText(find.byKey(const ValueKey('local-mac-address')), 'https://synthetic.ngrok.app');
    await tester.enterText(find.byKey(const ValueKey('local-mac-key')), List.filled(43, 's').join());
    await tester.tap(find.byKey(const ValueKey('local-mac-connect')));
    await tester.pumpAndSettle();
    expect(order, ['stop', 'probe']);
    expect(session.isSignedIn, isTrue);
    expect(find.text('Open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final readiness in [
    null,
    {
      'live': {'status': 'disabled'},
      'final': {'status': 'unavailable'}
    }
  ]) {
    testWidgets('pairing warns for readiness $readiness while keeping audio connection usable', (tester) async {
      final session = LocalMacSession(probe: (_, __) async => {'uid': 'alice', 'local_transcription': readiness});
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LocalMacPage(session: session, stopRecording: () async {}, refreshConnection: () async {}),
      ));
      await tester.enterText(find.byKey(const ValueKey('local-mac-address')), 'https://synthetic.ngrok.app');
      await tester.enterText(find.byKey(const ValueKey('local-mac-key')), List.filled(43, 's').join());
      await tester.tap(find.byKey(const ValueKey('local-mac-connect')));
      await tester.pumpAndSettle();
      expect(session.isSignedIn, isTrue);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(readiness == null ? 'Live Transcript: Unknown' : 'Live Transcript: Off'), findsOneWidget);
      expect(find.text(readiness == null ? 'Transcript: Unknown' : 'Transcript: Transcription unavailable'),
          findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(session.isSignedIn, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
