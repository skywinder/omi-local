import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/local_next/local_next_app.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/server_catalog.dart';
import 'package:omi/local_next/server_session.dart';

class _Pair extends PairedLibrary {
  _Pair(super.address, super.appKey, this.probe);
  final Future<void> Function(String host) probe;
  @override
  Future<void> verify() async {
    await probe(origin.host);
    verified = true;
  }

  @override
  Future<({List<ServerConversation> rows, int consumed, bool partial, bool more})> list(
    int offset, {
    bool starredOnly = false,
    String? folderId,
  }) async => (
    rows: [
      ServerConversation.fromJson({
        'id': '00000000-0000-4000-8000-000000000001',
        'created_at': '2026-01-02T13:00:00Z',
        'started_at': null,
        'finished_at': null,
        'structured': {'title': 'Archive ${origin.host}', 'overview': ''},
      }),
    ],
    consumed: 1,
    partial: false,
    more: false,
  );
}

Future<void> _click(WidgetTester tester, String key) async {
  final control = find.byKey(ValueKey(key));
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, NextServerSession session) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(640, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(LocalNextApp(session: session));
  await tester.pump();
  expect(session.busy, isFalse, reason: 'The mocked installer and Keychain should finish at startup');
  await tester.pumpAndSettle();
}

Future<void> _confirmDelete(WidgetTester tester) async {
  await _click(tester, 'server-delete');
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Delete')));
  await tester.pumpAndSettle();
}

void main() {
  final keyA = List.filled(43, 'A').join(), keyB = List.filled(43, 'B').join();
  const primary = '100.64.0.1', secondary = '100.64.0.2';
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('startup default retries a failed verification and respects explicit disconnect', () async {
    var available = false, attempts = 0;
    final catalog = NextServerCatalog(
      openPair: (address, key) => _Pair(address, key, (_) async {
        attempts++;
        if (!available) throw LibraryFailure.unavailable;
      }),
    );
    final preset = base64Encode(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'default': 'lab',
          'servers': [
            {'id': 'lab', 'name': 'Lab', 'url': primary, 'key': keyA},
          ],
        }),
      ),
    );
    final first = NextServerSession(catalog, readPresets: () async => preset);
    await first.initialize();
    expect(first.failure, LibraryFailure.unavailable);
    expect(first.active, isNull);
    first.dispose();
    available = true;
    final second = NextServerSession(catalog, readPresets: () async => null);
    await second.initialize();
    expect(second.activeId, 'lab');
    expect(attempts, 2);
    await second.disconnect();
    second.dispose();
    final third = NextServerSession(catalog, readPresets: () async => preset);
    addTearDown(third.dispose);
    await third.initialize();
    expect(third.active, isNull);
    expect(attempts, 2);
  });

  testWidgets(
    'a rejected probe or active capture preserves the old server, then an explicit switch retires its routes and retains both pairings',
    (tester) async {
      final probes = <String>[];
      Completer<void>? waiting;
      final catalog = NextServerCatalog(
        openPair: (address, key) => _Pair(address, key, (host) async {
          probes.add(host);
          if (host == secondary && waiting != null) await waiting.future;
        }),
      );
      final home = await catalog.save(name: 'Home', address: primary, key: keyA);
      final office = await catalog.save(name: 'Office', address: secondary, key: keyB);
      final session = NextServerSession(
        catalog,
        readPresets: () async => null,
        retainedAudio: (_) => throw StateError('Switching must retain both outboxes'),
      );
      await _open(tester, session);
      expect(probes, isEmpty);
      await _click(tester, 'server-entry-${home.id}');
      await _click(tester, 'server-connect');
      expect(find.text('Archive $primary'), findsOneWidget);
      final old = session.active!;
      final rejectedOld = old.onKeyRejected!;
      await tester.tap(find.byKey(const ValueKey('archive-servers')));
      await tester.pumpAndSettle();
      await _click(tester, 'server-entry-${office.id}');
      waiting = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('server-connect')));
      await tester.pump();
      expect(identical(session.active, old), isTrue);
      waiting.completeError(LibraryFailure.key);
      await tester.pumpAndSettle();
      expect(find.text('Invalid key'), findsOneWidget);
      expect((await catalog.load()).activeId, home.id);
      waiting = null;
      var recording = true;
      old.ownerChange.attachCapture(() => recording);
      await _click(tester, 'server-connect');
      expect(find.textContaining('Stop the recording'), findsOneWidget);
      expect(identical(session.active, old), isTrue);
      recording = false;
      await _click(tester, 'server-connect');
      expect(find.text('Archive $secondary'), findsOneWidget);
      expect(find.text('Archive $primary'), findsNothing);
      expect(old.isSignedIn, isFalse);
      rejectedOld();
      await tester.pumpAndSettle();
      expect((await catalog.load()).activeId, office.id);
      expect(find.text('Disconnect'), findsNothing);
      await _click(tester, 'archive-servers');
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      var recordingOnOffice = true;
      session.active!.ownerChange.attachCapture(() => recordingOnOffice);
      await _click(tester, 'server-disconnect');
      expect(find.textContaining('Stop the recording'), findsOneWidget);
      expect((await catalog.load()).activeId, office.id);
      recordingOnOffice = false;
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await _click(tester, 'server-disconnect');
      final disconnected = await catalog.load();
      expect(disconnected.activeId, isNull);
      expect(disconnected.servers.map((s) => s.name), ['Home', 'Office']);
      await _click(tester, 'server-entry-${home.id}');
      await _click(tester, 'server-connect');
      expect(session.active!.audioOwnerId, home.ownerId);
      expect(find.text('Archive $primary'), findsOneWidget);
      final prior = session.active!;
      await tester.tap(find.byKey(const ValueKey('archive-servers')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reconnect'));
      await tester.pumpAndSettle();
      expect(session.active, isNot(same(prior)));
      expect(prior.isSignedIn, isFalse);
      expect((await catalog.load()).activeId, home.id);
    },
  );

  testWidgets('saved credentials stay masked and offline, and an inactive owner with retained audio keeps its entry', (
    tester,
  ) async {
    var retained = true;
    final checked = <String>[];
    final catalog = NextServerCatalog(
      openPair: (address, key) => _Pair(address, key, (_) => throw StateError('Unexpected probe')),
    );
    final session = NextServerSession(
      catalog,
      readPresets: () async => null,
      retainedAudio: (id) async {
        checked.add(id);
        return retained;
      },
    );
    await _open(tester, session);
    await tester.enterText(find.byKey(const ValueKey('server-address')), primary);
    await tester.enterText(find.byKey(const ValueKey('server-name')), 'Lab');
    await tester.enterText(find.byKey(const ValueKey('server-key')), keyA);
    await _click(tester, 'server-save');
    final entry = (await catalog.load()).servers.single;
    expect(session.active, isNull);
    expect(find.byKey(const ValueKey('server-key')), findsNothing);
    await _click(tester, 'server-edit');
    final keyField = tester.widget<TextField>(find.byKey(const ValueKey('server-key')));
    expect(keyField.obscureText, isTrue);
    expect(keyField.controller!.text, isEmpty);
    await tester.enterText(find.byKey(const ValueKey('server-name')), 'Lab 2');
    await _click(tester, 'server-save');
    expect((await catalog.load()).servers.single.name, 'Lab 2');
    expect(checked, isEmpty);
    await _click(tester, 'server-delete');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(checked, isEmpty);
    await _confirmDelete(tester);
    expect(checked, [entry.ownerId]);
    expect(find.textContaining('recordings waiting for this server'), findsOneWidget);
    expect((await catalog.load()).servers.single.id, entry.id);
    retained = false;
    await _confirmDelete(tester);
    expect((await catalog.load()).servers, isEmpty);
    expect(session.active, isNull);
  });
}
