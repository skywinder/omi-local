import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/gen/conversation_wire.g.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/local_next_app.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_page.dart';

class _ExistingRecording extends PairedLibrary {
  _ExistingRecording() : super('100.64.0.1', List.filled(43, 'A').join());

  @override
  Future<GeneratedConversation> detail(String id) async => GeneratedConversation.fromJson({
    'id': id,
    'created_at': '2026-01-01T00:00:00Z',
    'started_at': null,
    'finished_at': null,
    'structured': {'title': 'Fixture meeting', 'overview': 'Meeting summary'},
    'transcript_segments': [
      {'is_user': true, 'text': 'Fixture utterance', 'start': 62.0, 'end': 63.0},
    ],
  });
}

void main() {
  testWidgets('a fresh install asks for pairing and reports a rejected key before network access', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(const LocalNextApp());
    await tester.pumpAndSettle();
    expect(find.text('Omi Local Next'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '100.64.0.1');
    await tester.enterText(find.byType(TextField).last, 'short');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid key'), findsOneWidget);
    expect(find.text('Conversations'), findsNothing);
  });

  testWidgets('detail renders the upstream summary and timestamped transcript for an older server', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RecordingPage(library: _ExistingRecording(), id: '00000000-0000-4000-8000-000000000001'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fixture meeting'), findsOneWidget);
    expect(find.text('Meeting summary'), findsOneWidget);
    expect(find.text('Fixture utterance'), findsOneWidget);
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
}
