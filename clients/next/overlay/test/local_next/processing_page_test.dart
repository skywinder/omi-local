import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/processing.dart';
import 'package:omi/local_next/processing_page.dart';

Map<String, dynamic> _profile(String id, String stage, String name, int configurationRevision) => {
  'id': id,
  'stage': stage,
  'name': name,
  'kind': 'external',
  'configuration_revision': configurationRevision,
};

Map<String, dynamic> _state({int revision = 7, bool switched = false, bool textStages = true}) {
  final live = _profile('live-primary', 'live', 'Live primary', 2);
  final second = _profile('live-second', 'live', 'Live secondary', 1);
  final stt = _profile('stt', 'stt', 'Final engine', 1);
  final summary = _profile('text', 'summary', 'Text engine', 1);
  return {
    'revision': revision,
    'profiles': [live, second, stt, if (textStages) summary],
    'effective': {
      'live': switched ? second : {...live, 'configuration_revision': 1},
      'stt': stt,
      'diarization': null,
      if (textStages) 'summary': summary,
      if (textStages) 'translation': {...summary, 'stage': 'translation', 'inherited_from': 'summary'},
    },
  };
}

Future<void> _open(WidgetTester tester, NextProcessingClient client, ValueNotifier<bool> recording) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: LocalNextProcessingPage(
        client: client,
        serverLabel: 'fixture.local',
        capture: recording,
        isRecording: () => recording.value,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectLive(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('next-live-7')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Live secondary').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('prepared selection remains a draft until recording stops and the owner explicitly confirms', (
    tester,
  ) async {
    final recording = ValueNotifier(false);
    addTearDown(recording.dispose);
    final writes = <Map<String, dynamic>>[];
    final client = NextProcessingClient(
      read: () async => _state(),
      activatePrepared: (body) async {
        writes.add(body);
        return _state(revision: 8, switched: true);
      },
    );
    await _open(tester, client, recording);
    expect(find.text('Active · Live primary'), findsOneWidget);
    expect(find.textContaining('Saved changes are not active'), findsOneWidget);
    await _selectLive(tester);
    expect(writes, isEmpty);
    expect(find.text('Active · Live primary'), findsOneWidget);
    final apply = find.byKey(const ValueKey('next-live-confirm'));
    recording.value = true;
    await tester.pump();
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    recording.value = false;
    await tester.pump();
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(writes, [
      {'revision': 7, 'stage': 'live', 'id': 'live-second'},
    ]);
    expect(find.text('Active · Live secondary'), findsOneWidget);
    final translation = find.byKey(const ValueKey('next-translation-active'));
    await tester.scrollUntilVisible(translation, 360);
    expect(find.text('Default · Summary'), findsOneWidget);
    expect(find.byKey(const ValueKey('next-summary-confirm')), findsNothing);
    expect(find.byKey(const ValueKey('next-translation-confirm')), findsNothing);
  });

  testWidgets('an unsupported server can be refreshed and an uncertain change requires a new read', (tester) async {
    final recording = ValueNotifier(false);
    addTearDown(recording.dispose);
    var reads = 0;
    var writes = 0;
    final client = NextProcessingClient(
      read: () async {
        reads++;
        if (reads == 1) throw NextProcessingFailure.unsupported;
        return _state(revision: reads > 2 ? 8 : 7, switched: reads > 2, textStages: false);
      },
      activatePrepared: (_) async {
        writes++;
        throw NextProcessingFailure.indeterminate;
      },
    );
    await _open(tester, client, recording);
    expect(find.textContaining('Update the paired server'), findsOneWidget);
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    await _selectLive(tester);
    await tester.tap(find.byKey(const ValueKey('next-live-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('may have applied the change'), findsOneWidget);
    expect(find.byKey(const ValueKey('next-live-confirm')), findsNothing);
    expect(reads, 2);
    expect(writes, 1);
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Active · Live secondary'), findsOneWidget);
    expect(reads, 3);
    expect(writes, 1);
  });
}
