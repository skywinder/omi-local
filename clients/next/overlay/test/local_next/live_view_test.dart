import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/live_preview.dart';
import 'package:omi/local_next/live_view.dart';
import 'package:omi/widgets/transcript.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Socket extends Fake implements WebSocket {
  final incoming = StreamController<dynamic>(sync: true);

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  Future<void> addStream(Stream<dynamic> data) => data.drain<void>();
  @override
  int? get closeCode => 1000;
  @override
  Future<void> close([int? code, String? reason]) => incoming.close();
  void send(Map<String, dynamic> message) => incoming.add(jsonEncode(message));

  void snapshot(int revision, String text, {String? translation, bool draft = false}) => send({
    'type': 'local_transcript_snapshot',
    'preview_id': 'preview-fixture',
    'revision': revision,
    'segments': [
      {
        'id': 'line',
        'text': text,
        'start': 1,
        'end': 10,
        'speaker': 'SPEAKER_00',
        if (translation != null)
          'translations': [
            {'lang': 'ru', 'text': translation},
          ],
      },
      if (draft)
        {
          'id': 'draft',
          'text': 'Unfinished sentence',
          'start': 11,
          'end': 12,
          'is_draft': true,
          'translations': [
            {'lang': 'ru', 'text': 'Черновой перевод'},
          ],
        },
    ],
  });
}

void main() {
  testWidgets('paired live transcript keeps a translation through a correction and Stop remains available', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'next.live.translation.fixture-owner': <String>['ru', ''],
    });
    final socket = _Socket();
    final preview = NextLivePreview('fixture-owner', (owner, source, codec) async => socket);
    final recording = ValueNotifier(true);
    final muted = ValueNotifier(false);
    var stops = 0;
    addTearDown(preview.dispose);
    addTearDown(recording.dispose);
    addTearDown(muted.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LocalNextLiveButton(
            preview: preview,
            capture: Listenable.merge([recording, muted]),
            isRecording: () => recording.value,
            isMuted: () => muted.value,
            serverLabel: 'fixture.local',
            onStop: () async {
              stops++;
              recording.value = false;
              preview.end('recording-fixture');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(preview.targetLanguage, 'ru');
    preview.begin('recording-fixture', 'phone', 'pcm16');
    await tester.tap(find.text('Live Transcript'));
    await tester.pumpAndSettle();
    expect(find.text('fixture.local'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    muted.value = true;
    await tester.pump();
    expect(find.text('Muted'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    muted.value = false;
    socket.snapshot(1, 'Old sentence', translation: 'Первый перевод', draft: true);
    await tester.pumpAndSettle();
    expect(tester.widget<TranscriptWidget>(find.byType(TranscriptWidget)).followLatest, isTrue);
    expect(find.text('Первый перевод', findRichText: true), findsOneWidget);
    expect(find.text('Unfinished sentence', findRichText: true), findsOneWidget);
    expect(find.text('Черновой перевод', findRichText: true), findsOneWidget);
    expect(find.text('translated by Omi'), findsNothing);
    socket.snapshot(2, 'Corrected sentence');
    await tester.pumpAndSettle();
    expect(find.text('Corrected sentence', findRichText: true), findsOneWidget);
    expect(find.text('Первый перевод', findRichText: true), findsOneWidget);
    expect(find.text('Unfinished sentence', findRichText: true), findsNothing);
    socket.snapshot(3, 'Corrected sentence', translation: 'Исправленный перевод');
    socket.send({'type': 'service_status', 'provider': 'local_live_translation', 'status': 'unconfigured'});
    await tester.pumpAndSettle();
    expect(find.text('Исправленный перевод', findRichText: true), findsOneWidget);
    expect(find.text('Первый перевод', findRichText: true), findsNothing);
    expect(find.textContaining('No translation model is configured'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(stops, 0);
    await tester.tap(find.text('Live Transcript'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(stops, 1);
    expect(find.text('Stop'), findsNothing);
    await tester.tap(find.byTooltip('Live translation'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('next-live-target')));
    await tester.pumpAndSettle();
    final menu = find.byType(Scrollable).last;
    final off = find.descendant(of: menu, matching: find.text('Off'));
    await tester.scrollUntilVisible(off, -240, scrollable: menu);
    await tester.tap(off);
    await tester.pumpAndSettle();
    expect(preview.targetLanguage, isEmpty);
    expect((await SharedPreferences.getInstance()).getStringList('next.live.translation.fixture-owner'), ['', '']);
  });
}
