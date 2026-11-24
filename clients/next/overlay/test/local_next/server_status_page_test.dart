import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/server_status_page.dart';
import 'package:omi/services/local_runtime_status_model.dart';

class _StatusPair extends PairedLibrary {
  _StatusPair() : super('100.64.0.1', List.filled(43, 'A').join());

  final pending = <Completer<LocalRuntimeStatus?>>[];

  @override
  Future<LocalRuntimeStatus?> readRuntimeStatus() {
    final response = Completer<LocalRuntimeStatus?>();
    pending.add(response);
    return response.future;
  }
}

const _active = LocalRuntimeStatus(
  captureState: LocalCaptureState.received,
  audioSeconds: 12,
  framesReceived: 20,
  liveTranscriptState: LocalLiveTranscriptState.streaming,
  transcriptUpdates: 4,
  stages: {'stt': LocalStageStatus(state: LocalStageState.ready)},
  stagesStale: true,
);

const _idle = LocalRuntimeStatus(
  captureState: LocalCaptureState.idle,
  audioSeconds: 0,
  framesReceived: 0,
  liveTranscriptState: LocalLiveTranscriptState.disabled,
  transcriptUpdates: 0,
);

void main() {
  testWidgets('server diagnostics poll on the visible foreground route and disregard background replies', (
    tester,
  ) async {
    final library = _StatusPair();
    final navigator = GlobalKey<NavigatorState>();
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NextServerStatusPage(library: library, serverName: 'Test server'),
      ),
    );
    expect(library.pending, hasLength(1));
    library.pending.single.complete(_active);
    await tester.pumpAndSettle();
    expect(find.text('Test server'), findsOneWidget);
    expect(find.text('12 seconds'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('next-server-stage-stt'))).data, 'Unknown');

    await tester.pump(const Duration(seconds: 5));
    expect(library.pending, hasLength(2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    library.pending[1].complete(_idle);
    await tester.pump(const Duration(seconds: 10));
    expect(library.pending, hasLength(2));
    expect(find.text('No active audio stream'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(library.pending, hasLength(3));
    library.pending[2].complete(_idle);
    await tester.pumpAndSettle();
    expect(find.text('No active audio stream'), findsOneWidget);
    expect(find.text('12 seconds'), findsNothing);

    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold())));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
    expect(library.pending, hasLength(3));
    navigator.currentState!.pop();
    await tester.pump();
    expect(library.pending, hasLength(4));
    library.pending[3].complete(_idle);
    await tester.pumpAndSettle();
  });

  testWidgets('an older server offers a manual retry without repeated requests', (tester) async {
    final library = _StatusPair();
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NextServerStatusPage(library: library, serverName: 'Test server'),
      ),
    );
    library.pending.single.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('This server does not provide diagnostics.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 15));
    expect(library.pending, hasLength(1));
    await tester.tap(find.byTooltip('Refresh'));
    expect(library.pending, hasLength(2));
    library.pending.last.complete(_idle);
    await tester.pumpAndSettle();
    expect(find.text('No active audio stream'), findsOneWidget);
  });
}
