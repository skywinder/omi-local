import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/local_memories_page.dart';
import 'package:omi/local_next/local_memory.dart';
import 'package:omi/local_next/paired_library.dart';

class _MemoryLibrary extends PairedLibrary {
  _MemoryLibrary() : super('100.64.0.1', List.filled(43, 'A').join()) {
    verified = true;
    memoriesAvailable = true;
  }
  final extractions = <String>[];
  final reviews = <String>[];
  final facts = <LocalMemory>[];
  bool changed = false;
  @override
  Future<LocalMemoryProvider?> memoryProvider(String id) async =>
      const LocalMemoryProvider(binding: 'binding', model: 'Synthetic model', host: 'model.example');
  @override
  Future<Map<String, dynamic>> extractMemories(String id, String binding, String requestId) async {
    extractions.add(requestId);
    expect(binding, 'binding');
    if (extractions.length == 1) throw LocalMemoryFailure.unavailable;
    facts.add(
      const LocalMemory({
        'id': 'fact',
        'revision': 'revision',
        'content': 'Aurora uses SQLite.',
        'state': 'proposed',
        'source_status': 'current',
        'eligible': false,
        'quote': 'Aurora uses SQLite',
        'conversation_id': 'source',
        'segment_id': 'line',
        'start_ms': 5000,
      }),
    );
    return {'created': 1, 'existing': 0, 'context_limited': true};
  }

  @override
  Future<LocalMemoryPage> listMemories({
    String state = 'accepted',
    String? sourceId,
    String query = '',
    String? after,
  }) async => (
    items: facts
        .where((fact) => fact.state == state && (query.isEmpty || !changed))
        .map(
          (fact) => LocalMemory({
            ...fact.wire,
            if (changed) ...{'source_status': 'changed', 'eligible': false, 'quote': null},
          }),
        )
        .toList(),
    next: null,
  );
  @override
  Future<void> reviewMemory(LocalMemory fact, String action, String requestId, {String? content}) async {
    reviews.add(requestId);
    if (reviews.length == 1) throw LocalMemoryFailure.unavailable;
    facts.removeWhere((item) => item.id == fact.id);
    if (action != 'delete') {
      facts.add(
        LocalMemory({
          ...fact.wire,
          'state': action == 'reject' ? 'rejected' : 'accepted',
          'revision': 'next',
          'eligible': action != 'reject',
          if (content != null) 'content': content,
        }),
      );
    }
  }
}

void main() {
  testWidgets(
    'memory requires model consent and fact review; uncertain writes reuse IDs and changed sources block approval',
    (tester) async {
      final library = _MemoryLibrary();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LocalMemoriesPage(library: library, sourceId: 'source'),
        ),
      );
      await tester.pumpAndSettle();
      expect(library.extractions, isEmpty);
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.ensureVisible(find.text('Propose facts from recording'));
        await tester.tap(find.text('Propose facts from recording'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Synthetic model\nmodel.example'), findsOneWidget);
        expect(library.extractions, hasLength(attempt));
        await tester.tap(find.widgetWithText(FilledButton, 'Propose facts from recording').last);
        await tester.pumpAndSettle();
      }
      expect(library.extractions, [library.extractions.first, library.extractions.first]);
      expect(library.reviews, isEmpty);
      expect(find.text('Aurora uses SQLite.'), findsOneWidget);
      expect(find.text('Only part of this recording was used for these proposals.'), findsOneWidget);
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.ensureVisible(find.text('Confirm fact'));
        await tester.tap(find.text('Confirm fact'));
        await tester.pumpAndSettle();
      }
      expect(library.reviews, [library.reviews.first, library.reviews.first]);
      await tester.ensureVisible(find.byType(DropdownButton<String>));
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirmed').last);
      await tester.pumpAndSettle();
      expect(find.text('Aurora uses SQLite.'), findsOneWidget);
      library.changed = true;
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('Source changed or unavailable — needs review'), findsOneWidget);
      expect(find.text('Edit and confirm'), findsNothing);
      expect(find.text('“Aurora uses SQLite”'), findsNothing);
      await tester.ensureVisible(find.text('Delete'));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(library.facts, isEmpty);
    },
  );
}
