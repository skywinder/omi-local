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
import 'package:omi/services/local_runtime_status.dart';
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

  Future<LocalRuntimeStatus> status() async => const LocalRuntimeStatus(
        captureState: LocalCaptureState.idle,
        audioSeconds: 0,
        framesReceived: 0,
        liveTranscriptState: LocalLiveTranscriptState.disabled,
        transcriptUpdates: 0,
      );

  Future<void> tapFormButton(WidgetTester tester, String key) async {
    final button = find.byKey(ValueKey(key));
    final formScroll = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    // The status card places these controls beyond the small test viewport;
    // scrolling must also build lazy ListView children before tapping them.
    await tester.scrollUntilVisible(button, 160, scrollable: formScroll);
    await tester.pumpAndSettle();
    expect(button.hitTestable(), findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

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
                          statusFetcher: status,
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
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Локальный Mac')), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const ValueKey('local-mac-key')));
    expect(field.obscureText, isTrue);
    await tester.enterText(find.byKey(const ValueKey('local-mac-address')), 'https://synthetic.ngrok.app');
    await tester.enterText(find.byKey(const ValueKey('local-mac-key')), List.filled(43, 's').join());
    await tapFormButton(tester, 'local-mac-connect');
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
        home: LocalMacPage(
            session: session, statusFetcher: status, stopRecording: () async {}, refreshConnection: () async {}),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('local-mac-address')), 'https://synthetic.ngrok.app');
      await tester.enterText(find.byKey(const ValueKey('local-mac-key')), List.filled(43, 's').join());
      await tapFormButton(tester, 'local-mac-connect');
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

  Future<void> openPage(WidgetTester tester, LocalMacSession session) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: LocalMacPage(
          session: session, statusFetcher: status, stopRecording: () async {}, refreshConnection: () async {}),
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
    await tapFormButton(tester, 'local-mac-save');
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
    await tapFormButton(tester, 'local-mac-connect');
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
