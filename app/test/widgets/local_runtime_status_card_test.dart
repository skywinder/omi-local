import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/env/dev_env.dart';
import 'package:omi/env/env.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/settings/local_runtime_status_card.dart';
import 'package:omi/services/auth/local_mac_session.dart';
import 'package:omi/services/local_runtime_status.dart';
import 'package:omi/utils/offline_network_policy.dart';

Map<String, dynamic> payload({String capture = 'received', String live = 'disabled', num seconds = 12.8}) => {
      'backend': 'ready',
      'capture': {'state': capture, 'audio_seconds': seconds, 'frames_received': 640},
      'live_transcript': {'state': live, 'updates': live == 'streaming' ? 2 : 0},
    };

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

  Future<LocalMacSession> paired() async {
    final session = LocalMacSession(probe: (_, __) async => {'uid': 'alice'});
    await session.connect('https://synthetic.ngrok.app', List.filled(43, 's').join());
    return session;
  }

  Future<void> showCard(
    WidgetTester tester,
    LocalMacSession session,
    Future<LocalRuntimeStatus> Function() fetcher, {
    bool active = true,
    GlobalKey<NavigatorState>? navigatorKey,
  }) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: LocalRuntimeStatusCard(session: session, fetcher: fetcher, active: active)),
    ));
    await tester.pumpAndSettle();
  }

  String value(WidgetTester tester, String name) =>
      tester.widget<Text>(find.byKey(ValueKey('local-runtime-$name'))).data!;

  test('parses independent live state and finite cumulative audio seconds', () {
    final status = LocalRuntimeStatus.fromJson(payload());
    expect(status.liveTranscriptState, LocalLiveTranscriptState.disabled);
    expect(status.audioSeconds, 12.8);
    expect(status.framesReceived, 640);
  });

  test('unknown and malformed payloads never become a healthy status', () {
    final malformed = <Object?>[
      null,
      {},
      {...payload(), 'backend': 'unknown'},
      payload(capture: 'recording'),
      payload(live: 'enabled'),
      payload(seconds: -1),
      payload(seconds: double.infinity),
      {
        ...payload(),
        'capture': {'state': 'received', 'audio_seconds': '12', 'frames_received': 1}
      },
      {
        ...payload(),
        'capture': {'state': 'received', 'audio_seconds': 12, 'frames_received': 1.5}
      },
      {
        ...payload(),
        'live_transcript': {'state': 'streaming', 'updates': -1}
      },
    ];
    for (final data in malformed) {
      expect(() => LocalRuntimeStatus.fromJson(data), throwsFormatException);
    }
  });

  test('client refuses an unpaired session without making a request', () async {
    final client = LocalRuntimeStatusClient(session: LocalMacSession());
    await expectLater(client.fetch(), throwsA(isA<LocalMacUnauthorized>()));
  });

  testWidgets('backend authentication does not imply live transcription is enabled', (tester) async {
    await showCard(tester, await paired(), () async => LocalRuntimeStatus.fromJson(payload()));
    expect(value(tester, 'connection'), 'Connected · API Key Auth');
    expect(value(tester, 'transcript'), 'Off');
    expect(value(tester, 'audio'), 'Total: 12 seconds');
    expect(find.textContaining('receiving'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed refresh clears all stale healthy and cumulative values', (tester) async {
    var calls = 0;
    await showCard(tester, await paired(), () async {
      if (++calls == 1) return LocalRuntimeStatus.fromJson(payload(live: 'streaming'));
      throw LocalRuntimeStatusUnavailable();
    });
    expect(value(tester, 'transcript'), 'Transcript received: 2');
    await tester.tap(find.byKey(const ValueKey('local-runtime-refresh')));
    await tester.pumpAndSettle();
    expect(value(tester, 'connection'), startsWith('Could not connect.'));
    expect(value(tester, 'audio'), 'Unknown');
    expect(value(tester, 'transcript'), 'Unknown');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rejected status shows the key error without changing pairing', (tester) async {
    final session = await paired();
    await showCard(tester, session, () async => throw LocalMacUnauthorized());
    expect(value(tester, 'connection'), 'The access key was rejected. Check the key on your Mac.');
    expect(session.isSignedIn, isTrue);
    expect(value(tester, 'transcript'), 'Unknown');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no status requests before a successful pairing', (tester) async {
    var calls = 0;
    await showCard(tester, LocalMacSession(), () async {
      calls++;
      return LocalRuntimeStatus.fromJson(payload());
    });
    await tester.pump(const Duration(seconds: 20));
    expect(calls, 0);
    expect(value(tester, 'connection'), 'Not Connected');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('periodic polling stops when disposed', (tester) async {
    var calls = 0;
    await showCard(tester, await paired(), () async {
      calls++;
      return LocalRuntimeStatus.fromJson(payload());
    });
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 20));
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden tab and background app do not poll', (tester) async {
    var calls = 0;
    final session = await paired();
    Future<LocalRuntimeStatus> fetch() async {
      calls++;
      return LocalRuntimeStatus.fromJson(payload());
    }

    await showCard(tester, session, fetch, active: false);
    await tester.pump(const Duration(seconds: 20));
    expect(calls, 0);
    await showCard(tester, session, fetch);
    expect(calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(value(tester, 'audio'), 'Unknown');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 20));
    expect(calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 2);
    await showCard(tester, session, fetch, active: false);
    await tester.pump(const Duration(seconds: 20));
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('covered route stops polling and resumes after pop', (tester) async {
    var calls = 0;
    final navigator = GlobalKey<NavigatorState>();
    await showCard(tester, await paired(), () async {
      calls++;
      return LocalRuntimeStatus.fromJson(payload());
    }, navigatorKey: navigator);
    expect(calls, 1);
    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold())));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    expect(calls, 1);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late result from the previous pairing cannot replace the current status', (tester) async {
    final session = await paired();
    final oldRequest = Completer<LocalRuntimeStatus>();
    var calls = 0;
    await showCard(tester, session, () async {
      if (++calls == 1) return oldRequest.future;
      return LocalRuntimeStatus.fromJson(payload(live: 'disabled', seconds: 3));
    });
    await session.connect('https://second-synthetic.ngrok.app', List.filled(43, 't').join());
    await tester.pumpAndSettle();
    expect(value(tester, 'audio'), 'Total: 3 seconds');
    oldRequest.complete(LocalRuntimeStatus.fromJson(payload(live: 'streaming', seconds: 99)));
    await tester.pumpAndSettle();
    expect(value(tester, 'audio'), 'Total: 3 seconds');
    expect(value(tester, 'transcript'), 'Off');
    await tester.pumpWidget(const SizedBox());
  });
}
