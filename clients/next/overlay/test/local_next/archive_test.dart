import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/local_next_app.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_page.dart';
import 'package:omi/pages/conversations/widgets/conversation_state_tile.dart';
import 'package:omi/pages/conversations/widgets/date_list_item.dart';
import 'package:omi/ui/components/omi_partial_notice.dart';

const _firstId = '00000000-0000-4000-8000-000000000001';
const _secondId = '00000000-0000-4000-8000-000000000002';
const _thirdId = '00000000-0000-4000-8000-000000000003';

typedef _Page = ({List<ServerConversation> rows, int consumed, bool partial, bool more});

class _ArchiveLibrary extends PairedLibrary {
  _ArchiveLibrary(this.page, this.record, {String address = '100.64.0.1'})
    : super(address, List.filled(43, 'A').join()) {
    verified = true;
  }
  final Future<_Page> Function(int) page;
  final ServerConversation record;
  final offsets = <int>[];
  final opened = <String>[];

  @override
  Future<_Page> list(int offset) {
    offsets.add(offset);
    return page(offset);
  }

  @override
  Future<ServerConversation> detail(String id) async {
    opened.add(id);
    return record;
  }
}

ServerConversation _row(String id, String title, DateTime start, {String? localState, DateTime? created}) =>
    ServerConversation.fromJson({
      'id': id,
      'created_at': (created ?? start).toUtc().toIso8601String(),
      'started_at': start.toUtc().toIso8601String(),
      'finished_at': start.add(const Duration(minutes: 8)).toUtc().toIso8601String(),
      'structured': {'title': title, 'overview': 'Local archive detail', 'emoji': '📌'},
      'status': localState == null ? 'completed' : 'processing',
      'external_data': localState == null
          ? {'local_transcript': <String, dynamic>{}}
          : {
              'local_recording': {'status': localState},
            },
    });

Future<void> _show(WidgetTester tester, PairedLibrary library) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: LocalNextLibraryPage(library: library, disconnect: () async {}),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('paired feed groups by local start date and opens a selected archive row after an older-page retry', (
    tester,
  ) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 9);
    final yesterday = DateTime(now.year, now.month, now.day - 1, 22);
    final early = _row(_firstId, 'Earlier today', today);
    final late = _row(_secondId, 'Later today', today.add(const Duration(hours: 2)));
    final pending = _row(
      _thirdId,
      'Wire placeholder',
      yesterday,
      localState: 'pending',
      created: today.add(const Duration(hours: 3)),
    );
    var firstAppend = true;
    final library = _ArchiveLibrary((offset) async {
      if (offset == 0) return (rows: [pending, early], consumed: 3, partial: true, more: true);
      if (firstAppend) {
        firstAppend = false;
        throw LibraryFailure.unavailable;
      }
      return (rows: [early, late], consumed: 2, partial: false, more: false);
    }, late);
    addTearDown(library.close);
    await _show(tester, library);
    await tester.pumpAndSettle();
    expect(tester.widgetList<DateListItem>(find.byType(DateListItem)).map((h) => h.date), [
      DateTime(today.year, today.month, today.day),
      DateTime(yesterday.year, yesterday.month, yesterday.day),
    ]);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.byType(ConversationStateTile), findsNWidgets(2));
    expect(find.text('📌'), findsNWidgets(2));
    expect(find.text('Recording'), findsOneWidget);
    expect(find.textContaining(' · Pending'), findsOneWidget);
    expect(find.text('Wire placeholder'), findsNothing);
    expect(find.byType(OmiPartialNotice), findsOneWidget);
    await tester.tap(find.text('show more ↓'));
    await tester.pumpAndSettle();
    expect(library.offsets, [0, 3]);
    expect(find.text('Earlier today'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search_partial_retry')));
    await tester.pumpAndSettle();
    expect(library.offsets, [0, 3, 3]);
    expect(find.byType(DateListItem), findsNWidgets(2));
    expect(find.text('Earlier today'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Later today')).dy, lessThan(tester.getTopLeft(find.text('Earlier today')).dy));
    expect(find.text('show more ↓'), findsNothing);
    await tester.drag(find.text('Later today'), const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsNothing);
    expect(library.opened, isEmpty);
    await tester.tap(find.text('Later today'));
    await tester.pumpAndSettle();
    expect(find.byType(RecordingPage), findsOneWidget);
    expect(library.opened, [_secondId]);
    expect(find.text('Local archive detail', findRichText: true), findsOneWidget);
  });

  testWidgets('a delayed prior pairing cannot repopulate the displayed archive and revoked access clears its rows', (
    tester,
  ) async {
    final stale = _row(_firstId, 'Old server', DateTime(2026, 1, 1));
    final current = _row(_secondId, 'Current server', DateTime(2026, 1, 2));
    final oldPage = Completer<_Page>();
    final old = _ArchiveLibrary((_) => oldPage.future, stale);
    var revoked = false;
    final next = _ArchiveLibrary(
      (_) async {
        if (revoked) throw LibraryFailure.key;
        return (rows: [current], consumed: 1, partial: false, more: false);
      },
      current,
      address: '100.64.0.2',
    );
    addTearDown(old.close);
    addTearDown(next.close);
    await _show(tester, old);
    await _show(tester, next);
    oldPage.complete((rows: [stale], consumed: 1, partial: false, more: false));
    await tester.pumpAndSettle();
    expect(find.text('Current server'), findsOneWidget);
    expect(find.text('Old server'), findsNothing);
    revoked = true;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Current server'), findsNothing);
    expect(find.text('Invalid key'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
