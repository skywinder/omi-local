import 'dart:io';
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
      return {'uid': 'alice'};
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

  Future<void> openPage(WidgetTester tester, LocalMacSession session) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: LocalMacPage(session: session, stopRecording: () async {}, refreshConnection: () async {}),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('save and reopen retains settings; eye reveals key and background hides it', (tester) async {
    final session = LocalMacSession(probe: (_, __) async => throw StateError('Saving must not probe'));
    await openPage(tester, session);
    final addressField = find.byKey(const ValueKey('local-mac-address'));
    final keyField = find.byKey(const ValueKey('local-mac-key'));
    await tester.enterText(addressField, 'https://synthetic.ngrok.app');
    await tester.enterText(keyField, 'synthetic-draft-key');
    await tester.tap(find.byKey(const ValueKey('local-mac-show-key')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(keyField).obscureText, isFalse);
    expect(tester.widget<SelectableText>(find.byKey(const ValueKey('local-mac-visible-url'))).data,
        'https://synthetic.ngrok.app');
    expect(
        tester.widget<SelectableText>(find.byKey(const ValueKey('local-mac-visible-key'))).data, 'synthetic-draft-key');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(keyField).obscureText, isTrue);
    expect(find.byKey(const ValueKey('local-mac-visible-key')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.tap(find.byKey(const ValueKey('local-mac-save')));
    await tester.pumpAndSettle();
    expect(session.isSignedIn, isFalse);
    await tester.pumpWidget(const SizedBox());
    await openPage(tester, LocalMacSession());
    expect(tester.widget<TextField>(addressField).controller!.text, 'https://synthetic.ngrok.app');
    expect(tester.widget<TextField>(keyField).controller!.text, 'synthetic-draft-key');
    expect(tester.widget<TextField>(keyField).obscureText, isTrue);
  });

  testWidgets('failed connection preserves entered settings across page reopen', (tester) async {
    final session = LocalMacSession(probe: (_, __) async => throw const SocketException('unavailable'));
    await openPage(tester, session);
    final key = List.filled(43, 's').join();
    await tester.enterText(find.byKey(const ValueKey('local-mac-address')), 'https://synthetic.ngrok.app');
    await tester.enterText(find.byKey(const ValueKey('local-mac-key')), key);
    await tester.tap(find.byKey(const ValueKey('local-mac-connect')));
    await tester.pumpAndSettle();
    expect(session.isSignedIn, isFalse);
    await tester.pumpWidget(const SizedBox());
    await openPage(tester, LocalMacSession());
    expect(tester.widget<TextField>(find.byKey(const ValueKey('local-mac-address'))).controller!.text,
        'https://synthetic.ngrok.app');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('local-mac-key'))).controller!.text, key);
  });

  testWidgets('edits autosave without pressing a button and pasted whitespace is removed', (tester) async {
    await openPage(tester, LocalMacSession());
    final addressField = find.byKey(const ValueKey('local-mac-address'));
    final keyField = find.byKey(const ValueKey('local-mac-key'));
    await tester.enterText(addressField, 'https://synthetic.ngrok.app');
    await tester.enterText(keyField, ' pasted\nkey ');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(keyField).controller!.text, 'pastedkey');
    await tester.pumpWidget(const SizedBox());
    await openPage(tester, LocalMacSession());
    expect(tester.widget<TextField>(addressField).controller!.text, 'https://synthetic.ngrok.app');
    expect(tester.widget<TextField>(keyField).controller!.text, 'pastedkey');
  });
}
