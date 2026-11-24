import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/local_next_app.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_edit.dart';

const _id = '00000000-0000-4000-8000-000000000001';

class _EditableLibrary extends PairedLibrary {
  _EditableLibrary() : super('100.64.0.1', List.filled(43, 'A').join()) {
    verified = true;
    recordingEdits = true;
  }

  String title = 'Original title';
  String transcript = 'Original words';
  bool starred = false;
  bool conflict = false;
  final requests = <Map<String, Object>>[];
  final filters = <bool>[];

  @override
  Future<ServerConversation> detail(String id) async => ServerConversation.fromJson({
    'id': id,
    'created_at': '2026-01-02T11:00:00Z',
    'started_at': '2026-01-02T11:00:00Z',
    'finished_at': '2026-01-02T11:01:00Z',
    'structured': {'title': title},
    'status': 'completed',
    'starred': starred,
    'transcript_segments': [
      {'id': 'actual-line', 'text': transcript, 'start': 4.25, 'end': 6.0, 'is_user': true},
      {'text': 'No stable identifier', 'start': 7.0, 'end': 8.0, 'is_user': true},
    ],
  });

  @override
  Future<({List<ServerConversation> rows, int consumed, bool partial, bool more})> list(
    int offset, {
    bool starredOnly = false,
  }) async {
    filters.add(starredOnly);
    final rows = !starredOnly || starred ? [await detail(_id)] : <ServerConversation>[];
    return (rows: rows, consumed: rows.length, partial: false, more: false);
  }

  @override
  Future<ServerConversation> editRecording(String id, RecordingEdit edit) async {
    expect(id, _id);
    requests.add(edit.wire);
    if (conflict) throw RecordingEditFailure.conflict;
    switch (edit.field) {
      case 'title':
        title = edit.value as String;
      case 'segment_text':
        transcript = edit.value as String;
      case 'starred':
        starred = edit.value as bool;
    }
    return detail(id);
  }
}

Future<void> _menu(WidgetTester tester, String label) async {
  await tester.tap(find.byWidgetPredicate((widget) => widget is PopupMenuButton));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a paired archive edits title and transcript and can filter by favorites', (tester) async {
    final library = _EditableLibrary();
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LocalNextLibraryPage(library: library, disconnect: () async {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Original title'));
    await tester.pumpAndSettle();
    await _menu(tester, 'Rename recording');
    await tester.enterText(find.byType(TextField), 'Revised title');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Revised title'), findsOneWidget);
    await _menu(tester, 'Add to favorites');
    await _menu(tester, 'Edit transcript');
    expect(find.text('No stable identifier'), findsNothing);
    await tester.tap(find.text('Original words'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Corrected words');
    library.conflict = true;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Corrected words'), findsOneWidget);
    expect(find.textContaining('The recording changed'), findsOneWidget);
    expect(library.transcript, 'Original words');
    library.conflict = false;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Revised title'), findsOneWidget);
    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(library.filters, [false, true]);
    expect(find.text('Revised title'), findsOneWidget);
    final originalTitle = sha256.convert(utf8.encode('Original title')).toString();
    final originalText = sha256.convert(utf8.encode('Original words')).toString();
    expect(library.requests, [
      {'field': 'title', 'expected': originalTitle, 'value': 'Revised title'},
      {'field': 'starred', 'expected': false, 'value': true},
      {'field': 'segment_text', 'expected': originalText, 'value': 'Corrected words', 'segment_id': 'actual-line'},
      {'field': 'segment_text', 'expected': originalText, 'value': 'Corrected words', 'segment_id': 'actual-line'},
    ]);
  });
}
