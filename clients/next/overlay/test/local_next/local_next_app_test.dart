import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/local_next_app.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_page.dart';
import 'package:omi/pages/conversation_detail/widgets/conversation_markdown_widget.dart';
import 'package:omi/pages/conversation_detail/widgets/note_sections_sliver.dart';
import 'package:omi/ui/omi_theme.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/widgets/transcript.dart';

class _ExistingRecording extends PairedLibrary {
  _ExistingRecording({this.overview = 'Meeting summary', this.sections = const []})
    : super('100.64.0.1', List.filled(43, 'A').join());

  final String overview;
  final List<Map<String, dynamic>> sections;

  @override
  Future<ServerConversation> detail(String id) async => ServerConversation.fromJson({
    'id': id,
    'created_at': '2026-01-01T00:00:00Z',
    'started_at': null,
    'finished_at': null,
    'structured': {'title': 'Fixture meeting', 'overview': overview, 'sections': sections},
    'external_data': {'local_transcript': <String, dynamic>{}},
    'transcript_segments': [
      {'id': 'line-1', 'is_user': true, 'text': 'Fixture utterance', 'start': 62.0, 'end': 63.0},
      {'is_user': false, 'text': 'Legacy first line', 'start': 64.0, 'end': 65.0},
      {'is_user': false, 'text': 'Legacy second line', 'start': 66.0, 'end': 67.0},
    ],
  });
}

Future<void> _openDetail(
  WidgetTester tester,
  _ExistingRecording library, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  addTearDown(library.close);
  final previous = OmiColors.active;
  addTearDown(() => OmiColors.active = previous);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildOmiTheme(brightness: brightness),
      builder: (context, child) {
        OmiColors.active = OmiColors.forBrightness(Theme.of(context).brightness);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        );
      },
      home: RecordingPage(library: library, id: '00000000-0000-4000-8000-000000000001'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a fresh install asks for pairing and reports a rejected key before network access', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    const environment = MethodChannel('org.omilocal.next/environment');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(environment, (call) async {
      expect(call.method, 'takeLocalMacSettings');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(environment, null));
    await tester.pumpWidget(const LocalNextApp());
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('server-connect'))).onPressed, isNotNull);
    await tester.pumpAndSettle();
    expect(find.text('Omi Next'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '100.64.0.1');
    await tester.enterText(find.byType(TextField).last, 'short');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid key'), findsOneWidget);
    expect(find.text('Conversations'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('recording tabs keep selected and inactive labels legible in ${brightness.name}', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await _openDetail(tester, _ExistingRecording(), brightness: brightness, textScale: 1.5);
      final tabs = find.byType(TabBar);
      final summary = find.descendant(of: tabs, matching: find.text('Summary'));
      final transcript = find.descendant(of: tabs, matching: find.text('Transcript'));
      final background = Theme.of(tester.element(tabs)).scaffoldBackgroundColor;
      double contrast(Color foreground) {
        final ink = Color.alphaBlend(foreground, background).computeLuminance();
        final surface = background.computeLuminance();
        return ink > surface ? (ink + .05) / (surface + .05) : (surface + .05) / (ink + .05);
      }

      void expectVisible() {
        for (final tab in [summary, transcript]) {
          final color = DefaultTextStyle.of(tester.element(tab)).style.color!;
          expect(contrast(color), greaterThanOrEqualTo(4.5));
        }
        final bar = tester.widget<TabBar>(tabs);
        final indicator = bar.indicator! as UnderlineTabIndicator;
        expect(contrast(indicator.borderSide.color), greaterThanOrEqualTo(3));
        expect(tester.takeException(), isNull);
      }

      expectVisible();
      await tester.tap(transcript);
      await tester.pumpAndSettle();
      expectVisible();
      expect(find.byType(TranscriptWidget), findsOneWidget);
    });
  }

  testWidgets('detail renders the upstream summary and timestamped transcript for an older server', (tester) async {
    await _openDetail(tester, _ExistingRecording());
    expect(find.text('Fixture meeting'), findsOneWidget);
    expect(find.byType(ConversationMarkdownSliver), findsOneWidget);
    expect(find.text('Meeting summary', findRichText: true), findsOneWidget);
    expect(find.text('Play'), findsNothing);
    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Transcript')));
    await tester.pumpAndSettle();
    expect(find.byType(TranscriptWidget), findsOneWidget);
    expect(find.byKey(const ValueKey('transcript-segment-line-1')), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Fixture utterance', findRichText: true), findsOneWidget);
    expect(find.text('Legacy second line', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('1:02'), findsOneWidget);
    expect(find.text('Play'), findsNothing);
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'meeting');
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('Meeting summary'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'UTTERANCE');
    await tester.pump();
    expect(find.text('1:02'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'absent');
    await tester.pump();
    expect(find.text('0/0'), findsOneWidget);
  });

  testWidgets(
    'an edited overview can be copied and searched after replacing generated sections',
    (tester) async {
      await _openDetail(
        tester,
        _ExistingRecording(
          overview: 'Revised verdict',
          sections: [
            {'heading': 'Earlier verdict', 'body_markdown': 'Superseded decision'},
          ],
        ),
      );
      final revision = find.text('Revised verdict', findRichText: true);
      expect(revision, findsOneWidget);
      expect(find.text('Superseded decision', findRichText: true), findsNothing);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = call.arguments['text'] as String?;
        if (call.method == 'Clipboard.hasStrings') return {'value': false};
        return null;
      });
      await tester.longPressAt(tester.getTopLeft(revision) + const Offset(18, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied?.trim(), 'Revised');

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Superseded');
      await tester.pump();
      expect(find.text('0/0'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Revised');
      await tester.pump();
      expect(find.text('1/1'), findsOneWidget);
      expect(find.text('Revised verdict'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('section citations reach the transcript on an older server without loading Markdown images', (
    tester,
  ) async {
    var networkImageLoads = 0;
    final previousClientProvider = debugNetworkImageHttpClientProvider;
    debugNetworkImageHttpClientProvider = () {
      networkImageLoads++;
      throw StateError('A summary tried to resolve an external image');
    };
    try {
      await _openDetail(
        tester,
        _ExistingRecording(
          overview: '',
          sections: [
            {'heading': 'Unused heading', 'body_markdown': '  '},
            {
              'heading': 'Decision',
              'body_markdown':
                  '**Approved**\n\n![tracker](https://fixture.invalid/private.png)'
                  '\n\n![file](file:///unavailable-fixture.png)',
              'source_segment_ids': ['unknown', 'local-next-1', 'line-1', 'line-1'],
            },
          ],
        ),
      );
      expect(find.byType(NoteSectionsSliver), findsOneWidget);
      expect(find.text('Decision', findRichText: true), findsOneWidget);
      expect(find.text('Unused heading', findRichText: true), findsNothing);
      expect(find.text('Approved', findRichText: true), findsOneWidget);
      expect(find.descendant(of: find.byType(ConversationMarkdownSliver), matching: find.byType(Image)), findsNothing);
      expect(networkImageLoads, 0);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('section-sources')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('section-source-line-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('section-source-unknown')), findsNothing);
      expect(find.byKey(const ValueKey('section-source-local-next-1')), findsNothing);
      expect(find.text('Fixture utterance', findRichText: true), findsOneWidget);
      expect(find.text('1:02'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('section-source-line-1')));
      await tester.pumpAndSettle();
      expect(find.byType(TranscriptWidget), findsOneWidget);
      expect(tester.widget<TranscriptWidget>(find.byType(TranscriptWidget)).currentSegmentId, 'line-1');
      expect(find.byKey(const ValueKey('transcript-segment-line-1')), findsOneWidget);
      expect(find.text('Play'), findsNothing);
    } finally {
      debugNetworkImageHttpClientProvider = previousClientProvider;
    }
  });
}
