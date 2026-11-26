import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/live_preview.dart';
import 'package:omi/local_next/live_view.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/processing.dart';
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

class _TuningPair extends PairedLibrary {
  _TuningPair() : super('100.64.0.1', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');

  var revision = 4, speakers = 2;
  final writes = <(int, int)>[];

  @override
  Future<({int revision, int speakers})?> readLiveTuning() async => (revision: revision, speakers: speakers);

  @override
  Future<({int revision, int speakers})> setLiveSpeakerLimit(int expected, int value) async {
    writes.add((expected, value));
    expect(expected, revision);
    revision++;
    speakers = value;
    if (writes.length == 1) throw NextProcessingFailure.indeterminate;
    return (revision: revision, speakers: speakers);
  }
}

void main() {
  testWidgets('paired server stays connected on the idle Live screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final library = _TuningPair();
    final preview = NextLivePreview('fixture', (owner, source, codec) => throw StateError('no recording'));
    final capture = ValueNotifier(false);
    addTearDown(library.close);
    addTearDown(preview.dispose);
    addTearDown(capture.dispose);
    library.connection.value = NextServerConnection.connected;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LocalNextLiveButton(
            preview: preview,
            capture: capture,
            isRecording: () => false,
            onStop: () async {},
            serverLabel: 'Bastion',
            library: library,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Live Transcript'));
    await tester.pumpAndSettle();
    expect(find.text('Bastion · Connected'), findsOneWidget);
    expect(find.text('No active recording'), findsOneWidget);
    expect(find.text('Off'), findsNothing);
    library.connection.value = NextServerConnection.unreachable;
    await tester.pump();
    expect(find.text('Bastion · Unreachable'), findsOneWidget);
    expect(find.text('No active recording'), findsOneWidget);
  });

  testWidgets('a saved conversation clears only older Live text and leaves Stop available', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final socket = _Socket();
    final preview = NextLivePreview('fixture-owner', (owner, source, codec) async => socket);
    final capture = ValueNotifier(true);
    addTearDown(preview.dispose);
    addTearDown(capture.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LocalNextLiveButton(
            preview: preview,
            capture: capture,
            isRecording: () => capture.value,
            onStop: () async => capture.value = false,
            serverLabel: 'fixture.local',
          ),
        ),
      ),
    );
    preview.begin('saved-group', 'phone', 'pcm16');
    await tester.pump();
    socket.snapshot(1, 'Saved conversation text', draft: true);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('next-live-strip')));
    await tester.pumpAndSettle();
    expect(find.text('Saved conversation text', findRichText: true), findsOneWidget);
    preview.confirmConversationBoundary('saved-group', 10 * 16000);
    await tester.pumpAndSettle();
    expect(find.text('Saved conversation text', findRichText: true), findsNothing);
    expect(find.text('Unfinished sentence', findRichText: true), findsOneWidget);
    expect(find.text('Conversation audio saved'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Stop'), findsOneWidget);
    expect(capture.value, isTrue);
  });

  testWidgets('a full live server explains the missing transcript while Stop stays available', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final socket = _Socket();
    final preview = NextLivePreview('fixture-owner', (owner, source, codec) async => socket);
    final recording = ValueNotifier(true);
    final library = _TuningPair();
    addTearDown(preview.dispose);
    addTearDown(recording.dispose);
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: LocalNextLiveButton(
            preview: preview,
            capture: recording,
            isRecording: () => recording.value,
            serverLabel: 'fixture.local',
            library: library,
            onStop: () async {
              recording.value = false;
            },
          ),
        ),
      ),
    );
    preview.begin('fixture', 'phone', 'pcm16');
    await tester.pump();
    socket.send({
      'type': 'service_status',
      'provider': 'local_live_preview',
      'status': 'stt_failed',
      'reason': 'session_limit',
    });
    await tester.pump();
    const warning = 'All live transcription slots are in use. Audio is still recording.';
    expect(find.text(warning), findsOneWidget);
    expect(recording.value, isTrue);
    await tester.tap(find.byKey(const ValueKey('next-live-strip')));
    await tester.pumpAndSettle();
    expect(find.text(warning), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Stop'), findsOneWidget);
  });

  testWidgets('saving a speaker limit requires confirmation and leaves the current stream status intact', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final socket = _Socket();
    final library = _TuningPair();
    final preview = NextLivePreview('fixture-owner', (owner, source, codec) async => socket);
    final recording = ValueNotifier(true);
    addTearDown(preview.dispose);
    addTearDown(recording.dispose);
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LocalNextLiveButton(
            preview: preview,
            capture: recording,
            isRecording: () => recording.value,
            serverLabel: 'fixture.local',
            library: library,
            onStop: () async {
              preview.end('fixture');
              recording.value = false;
            },
          ),
        ),
      ),
    );
    preview.begin('fixture', 'phone', 'pcm16');
    await tester.tap(find.byKey(const ValueKey('next-live-strip')));
    await tester.pumpAndSettle();
    socket.send({
      'type': 'service_status',
      'provider': 'local_live_tuning',
      'status': 'applied',
      'revision': 4,
      'max_speakers': 2,
    });
    socket.send({
      'type': 'service_status',
      'provider': 'local_live_tuning',
      'status': 'failed',
      'revision': 3,
      'max_speakers': 1,
    });
    await tester.pump();
    expect(find.text('Speaker limit in this stream: 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live speaker limit'));
    await tester.pumpAndSettle();

    Future<void> select(String value) async {
      await tester.tap(find.byKey(const ValueKey('next-live-speakers')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(value).last);
      await tester.pumpAndSettle();
    }

    final save = find.byType(FilledButton);
    await select('3');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(library.writes, [(4, 3)]);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    await select('4');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(library.writes, [(4, 3), (5, 4)]);
    expect(find.text('Saved for the next recognition stream.'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Speaker limit in this stream: 2'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(find.text('Speaker limit in this stream: 2'), findsNothing);
  });

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
    await tester.tap(find.byKey(const ValueKey('next-live-strip')));
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

    void longSnapshot(int revision, int count) => socket.send({
      'type': 'local_transcript_snapshot',
      'preview_id': 'preview-fixture',
      'revision': revision,
      'segments': List.generate(count, (i) => {'id': 'line-$i', 'text': 'Sentence $i', 'start': i, 'end': i + 1}),
    });
    longSnapshot(4, 45);
    await tester.pumpAndSettle();
    final bar = tester.widget<Scrollbar>(
      find.descendant(of: find.byType(TranscriptWidget), matching: find.byType(Scrollbar)),
    );
    expect(bar.thumbVisibility, true);
    expect(bar.interactive, true);
    final controller = bar.controller!;
    await tester.drag(find.byType(TranscriptWidget), const Offset(0, 400));
    await tester.pumpAndSettle();
    final offset = controller.offset;
    expect(controller.position.extentAfter, greaterThan(150));
    longSnapshot(5, 46);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(offset, 2));
    await tester.tap(find.byKey(const ValueKey('transcript_jump_to_latest')));
    await tester.pumpAndSettle();
    expect(controller.position.extentAfter, lessThan(2));

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(stops, 0);
    expect(find.text('Sentence 45'), findsOneWidget);
    final latest = tester.widget<Text>(find.text('Sentence 45'));
    expect(latest.maxLines, 1);
    expect(latest.overflow, TextOverflow.ellipsis);
    await tester.tap(find.byKey(const ValueKey('next-live-strip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(stops, 1);
    expect(find.text('Stop'), findsNothing);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('next-live-target')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'рус');
    await tester.pump();
    expect(find.text('Русский (Russian)'), findsOneWidget);
    expect(find.text('English'), findsNothing);
    await tester.enterText(find.byType(TextField), 'no-such-language');
    await tester.pump();
    expect(find.text('No results found'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'fr');
    await tester.pump();
    await tester.tap(find.text('Français (French)'));
    await tester.pumpAndSettle();
    expect(preview.targetLanguage, 'fr');
    await tester.tap(find.byKey(const ValueKey('next-live-other')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'eng');
    await tester.pump();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(preview.otherLanguage, 'en');
    await tester.tap(find.byKey(const ValueKey('next-live-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(preview.targetLanguage, isEmpty);
    expect((await SharedPreferences.getInstance()).getStringList('next.live.translation.fixture-owner'), ['', '']);
  });
}
