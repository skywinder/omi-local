import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/folder.dart';
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
  String category = 'other';
  bool starred = false;
  bool archived = false;
  bool conflict = false;
  String? currentFolder;
  Folder? savedFolder;
  final requests = <Map<String, Object?>>[];
  final filters = <bool>[];

  @override
  Future<ServerConversation> detail(String id) async => ServerConversation.fromJson({
    'id': id,
    'created_at': '2026-01-02T11:00:00Z',
    'started_at': '2026-01-02T11:00:00Z',
    'finished_at': '2026-01-02T11:01:00Z',
    'structured': {'title': title, 'category': category},
    'status': 'completed',
    'external_data': {
      'local_transcript': {
        'stages': {
          'diarization': {'status': 'ready', 'provider': 'Fixture service', 'speakers': 2},
        },
      },
    },
    'starred': starred,
    'archived': archived,
    'folder_id': currentFolder,
    'transcript_segments': [
      {'id': 'actual-line', 'text': transcript, 'start': 4.25, 'end': 6.0, 'is_user': true},
      {'text': 'No stable identifier', 'start': 7.0, 'end': 8.0, 'is_user': true},
    ],
  });

  @override
  Future<({List<ServerConversation> rows, int consumed, bool partial, bool more})> list(
    int offset, {
    bool starredOnly = false,
    bool archivedOnly = false,
    String? folderId,
  }) async {
    filters.add(starredOnly);
    final rows =
        (!archivedOnly || archived) && (!starredOnly || starred) && (folderId == null || currentFolder == folderId)
        ? [await detail(_id)]
        : <ServerConversation>[];
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
      case 'archived':
        archived = edit.value as bool;
      case 'folder':
        currentFolder = edit.value as String?;
      case 'category':
        category = edit.value as String;
    }
    return detail(id);
  }

  @override
  Future<List<Folder>> readFolders() async => [if (savedFolder != null) savedFolder!];

  @override
  Future<Folder> saveFolder(String name, {String? id}) async {
    final now = DateTime.utc(2026, 1, 2);
    return savedFolder = Folder(
      id: id ?? 'project-folder',
      name: name,
      color: '#6B7280',
      icon: 'folder',
      createdAt: now,
      updatedAt: now,
      order: 0,
      conversationCount: 0,
      isDefault: false,
      isSystem: false,
    );
  }
}

class _ManagedLibrary extends _EditableLibrary {
  _ManagedLibrary() {
    foldersAvailable = true;
    folderManagementAvailable = true;
  }

  final ordered = ['first', 'second'];
  final moves = <String?>[];

  @override
  Future<List<Folder>> readFolders() async => [
    for (final id in ordered)
      Folder(
        id: id,
        name: id,
        color: '#6B7280',
        icon: 'folder',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        order: ordered.indexOf(id),
        conversationCount: 0,
        isDefault: false,
        isSystem: false,
      ),
  ];

  @override
  Future<void> reorderFolders(List<String> expected, List<String> replacement) async {
    expect(expected, ordered);
    ordered
      ..clear()
      ..addAll(replacement);
  }

  @override
  Future<void> bulkMoveFolders(Map<String, String?> expected, String? destination) async {
    expect(expected, {_id: currentFolder});
    moves.add(destination);
    currentFolder = destination;
  }

  @override
  Future<void> deleteFolder(String id) async {
    ordered.remove(id);
    if (currentFolder == id) currentFolder = null;
  }
}

Future<void> _menu(WidgetTester tester, String label) async {
  await tester.tap(find.byWidgetPredicate((widget) => widget is PopupMenuButton));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('archiving and restoring a paired conversation moves it between the two lists', (tester) async {
    final library = _EditableLibrary()..recordingArchive = true;
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: LocalNextLibraryPage(library: library),
      ),
    );
    await tester.pumpAndSettle();
    final title = find.text('Original title');
    final archive = find.byKey(const ValueKey('archive-archived'));
    await tester.tap(title);
    await tester.pumpAndSettle();
    library.conflict = true;
    await _menu(tester, 'Archive recording');
    expect(library.archived, isFalse);
    library.conflict = false;
    await _menu(tester, 'Archive recording');
    expect(library.archived, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(title, findsNothing);
    await tester.tap(archive);
    await tester.pumpAndSettle();
    await tester.tap(title);
    await tester.pumpAndSettle();
    await _menu(tester, 'Restore from archive');
    expect(library.requests.last, {'field': 'archived', 'expected': true, 'value': false});
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('No archived recordings'), findsOneWidget);
    await tester.tap(archive);
    await tester.pumpAndSettle();
    expect(title, findsOneWidget);
  });

  testWidgets('a read-only transcript shows the recorded diarization result and copies the complete text', (
    tester,
  ) async {
    final library = _EditableLibrary()..recordingEdits = false;
    addTearDown(library.close);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LocalNextLibraryPage(library: library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Original title'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fixture service · 2 speakers'), findsOneWidget);
    await _menu(tester, 'Copy Transcript');
    expect(copied, contains('Original words'));
    expect(copied, contains('No stable identifier'));
    await tester.tap(find.byWidgetPredicate((widget) => widget is PopupMenuButton));
    await tester.pumpAndSettle();
    expect(find.text('Share Audio'), findsNothing);
  });

  testWidgets('bulk folder control moves selected rows and confirms folder removal without removing the row', (
    tester,
  ) async {
    final library = _ManagedLibrary();
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: LocalNextLibraryPage(library: library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select recordings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Original title'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to Folder · 1/100'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'second'));
    await tester.pumpAndSettle();
    expect(library.moves, ['second']);
    await tester.tap(find.text('Folders'));
    await tester.pumpAndSettle();
    Finder menu(String folder) => find.descendant(
      of: find.widgetWithText(ListTile, folder),
      matching: find.byWidgetPredicate((widget) => widget is PopupMenuButton),
    );
    await tester.tap(menu('second'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();
    expect(library.ordered, ['second', 'first']);
    await tester.tap(menu('second'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(library.currentFolder, 'second');
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete')));
    await tester.pumpAndSettle();
    expect(library.currentFolder, isNull);
    expect(library.ordered, ['first']);
    await tester.tap(find.text('All recordings'));
    await tester.pumpAndSettle();
    expect(find.text('Original title'), findsOneWidget);
  });

  testWidgets('paired folders can be created, renamed, selected, and cleared on a recording', (tester) async {
    final library = _EditableLibrary()..foldersAvailable = true;
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LocalNextLibraryPage(library: library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Original title'));
    await tester.pumpAndSettle();
    await _menu(tester, 'Move to Folder');
    await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Projects');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(library.savedFolder?.name, 'Projects');
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, 'Projects'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(library.currentFolder, 'project-folder', reason: 'Sent edits: ${library.requests}');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Meetings');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Meetings'));
    await tester.pumpAndSettle();
    expect(find.text('Original title'), findsOneWidget);
    await tester.tap(find.text('Original title'));
    await tester.pumpAndSettle();
    await _menu(tester, 'Move to Folder');
    await tester.tap(find.text('No Folder'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Original title'), findsNothing);
    expect(library.requests, [
      {'field': 'folder', 'expected': null, 'value': 'project-folder'},
      {'field': 'folder', 'expected': 'project-folder', 'value': null},
    ]);
  });

  testWidgets('a paired archive edits title and transcript and can filter by favorites', (tester) async {
    final library = _EditableLibrary()..recordingCategories = true;
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LocalNextLibraryPage(library: library),
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
    await _menu(tester, 'Change category');
    await tester.tap(find.byKey(const ValueKey('conversation-category-personal')));
    await tester.pumpAndSettle();
    expect(find.text('👤 Personal'), findsOneWidget);
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
    await tester.tap(find.widgetWithText(FilterChip, 'Starred'));
    await tester.pumpAndSettle();
    expect(library.filters, [false, true]);
    expect(find.text('Revised title'), findsOneWidget);
    final originalTitle = sha256.convert(utf8.encode('Original title')).toString();
    final originalText = sha256.convert(utf8.encode('Original words')).toString();
    expect(library.requests, [
      {'field': 'title', 'expected': originalTitle, 'value': 'Revised title'},
      {'field': 'category', 'expected': 'other', 'value': 'personal'},
      {'field': 'starred', 'expected': false, 'value': true},
      {'field': 'segment_text', 'expected': originalText, 'value': 'Corrected words', 'segment_id': 'actual-line'},
      {'field': 'segment_text', 'expected': originalText, 'value': 'Corrected words', 'segment_id': 'actual-line'},
    ]);
  });
}
