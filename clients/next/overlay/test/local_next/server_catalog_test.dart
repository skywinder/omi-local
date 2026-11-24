import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/server_catalog.dart';

void main() {
  final key = List.filled(43, 'A').join();
  final replacement = List.filled(43, 'B').join();
  const first = 'http://127.0.0.1:20000';
  const second = 'http://127.0.0.1:21000';
  const storage = PairedLibrary.pairingStorage;
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('one committed catalog adopts the old verified owner and an interrupted cleanup cannot resurrect it', () async {
    final original = jsonEncode({'address': first, 'key': key, 'deliveryVersion': 2});
    await storage.write(key: PairedLibrary.legacyPairingKey, value: original);
    final catalog = NextServerCatalog();
    final migrated = await catalog.load();
    final old = migrated.restoreActive()!;
    expect(migrated.activeId, migrated.servers.single.id);
    expect(old.audioOwnerId, PairedLibrary(first, key).audioOwnerId);
    expect(old.verified, isFalse);
    expect(old.audioDelivery, isTrue);
    expect(await storage.read(key: PairedLibrary.legacyPairingKey), isNull);
    await catalog.deactivate(old.audioOwnerId);
    await catalog.delete(migrated.activeId!, beforeReplace: (_) async {});
    await storage.write(key: PairedLibrary.legacyPairingKey, value: original);
    final restarted = await NextServerCatalog().load();
    expect(restarted.restoreActive(), isNull);
    expect(restarted.servers, isEmpty);
    expect(await storage.read(key: PairedLibrary.legacyPairingKey), isNull);
  });

  test('a corrupt catalog retains its current and old credentials until it can be read', () async {
    await storage.write(key: NextServerCatalog.storageKey, value: 'broken');
    final original = jsonEncode({'address': first, 'key': key, 'deliveryVersion': 2});
    await storage.write(key: PairedLibrary.legacyPairingKey, value: original);
    await expectLater(
      NextServerCatalog().save(name: 'New', address: second, key: replacement),
      throwsA(LibraryFailure.storage),
    );
    expect(await storage.read(key: NextServerCatalog.storageKey), 'broken');
    expect(await storage.read(key: PairedLibrary.legacyPairingKey), original);
  });

  test('a preset batch validates as a unit, never selects, overwrites or resurrects an entry', () async {
    final catalog = NextServerCatalog();
    Map<String, String> preset(String id, String name, String address) => {
      'id': id,
      'name': name,
      'url': address,
      'key': key,
    };
    String batch(List<Map<String, String>> servers) =>
        base64Encode(utf8.encode(jsonEncode({'version': 1, 'servers': servers})));
    final a = preset('home', 'Home', first);
    final b = preset('travel', 'Travel', second);
    await expectLater(
      catalog.importPresets(
        batch([
          a,
          {...b, 'url': 'http://example.org'},
        ]),
      ),
      throwsA(LibraryFailure.malformed),
    );
    expect(await storage.read(key: NextServerCatalog.storageKey), isNull);
    await catalog.importPresets(batch([a, b]));
    final imported = await catalog.load();
    expect(imported.activeId, isNull);
    expect(imported.servers.map((s) => s.name), ['Home', 'Travel']);
    await catalog.save(id: 'home', name: 'Edited', address: first, key: replacement, beforeReplace: (_) async {});
    await catalog.delete('travel', beforeReplace: (_) async {});
    await NextServerCatalog().importPresets(batch([a, b, preset('renamed', 'Installer duplicate', '$first/')]));
    final saved = (await catalog.load()).servers.single;
    expect(saved.name, 'Edited');
    expect(saved.ownerId, PairedLibrary(first, replacement).audioOwnerId);
  });

  test('only a verified current draft commits active custody; stale probes and prior revocations are fenced', () async {
    final catalog = NextServerCatalog();
    final a = await catalog.prepare(name: 'A', address: first, key: key);
    final b = await catalog.prepare(name: 'B', address: second, key: replacement);
    expect((await catalog.load()).servers, isEmpty);
    await expectLater(catalog.activate(a, a.open()), throwsA(LibraryFailure.key));
    await expectLater(catalog.activate(a, b.open()..verified = true), throwsA(LibraryFailure.key));
    final verified = a.open()
      ..verified = true
      ..audioDelivery = true;
    await catalog.activate(a, verified);
    await expectLater(catalog.activate(b, b.open()..verified = true), throwsA(LibraryFailure.unavailable));
    await expectLater(catalog.delete(a.id), throwsA(LibraryFailure.unavailable));
    await expectLater(
      catalog.save(id: a.id, name: 'B', address: second, key: replacement),
      throwsA(LibraryFailure.unavailable),
    );
    await expectLater(catalog.prepare(id: a.id, name: 'B', address: second, key: ''), throwsA(LibraryFailure.key));
    final stale = await catalog.prepare(id: a.id, name: 'New', address: second, key: replacement);
    await catalog.save(id: a.id, name: 'Renamed', address: '$first/', key: '');
    await expectLater(catalog.activate(stale, stale.open()..verified = true), throwsA(LibraryFailure.unavailable));
    final edited = await catalog.prepare(id: a.id, name: 'New', address: second, key: replacement);
    final candidate = edited.open()..verified = true;
    await expectLater(
      catalog.activate(
        edited,
        candidate,
        beforeReplace: (owner) async {
          expect(owner, a.ownerId);
          throw LibraryFailure.storage;
        },
      ),
      throwsA(LibraryFailure.storage),
    );
    expect((await catalog.load()).restoreActive()?.audioOwnerId, verified.audioOwnerId);
    await catalog.activate(edited, candidate, beforeReplace: (_) async {});
    await catalog.deactivate(verified.audioOwnerId);
    final restored = await NextServerCatalog().load();
    expect(restored.activeOwnerId, candidate.audioOwnerId);
    expect(restored.servers.single.id, a.id);
    expect(restored.restoreActive()!.audioDelivery, isFalse);
    await catalog.deactivate(candidate.audioOwnerId);
    expect((await catalog.load()).activeId, isNull);
    expect((await catalog.load()).servers.single.ownerId, candidate.audioOwnerId);
    // Both the original probe and the current snapshot have no active server.
    await expectLater(catalog.activate(b, b.open()..verified = true), throwsA(LibraryFailure.unavailable));
  });

  test('serialized mutations across catalog handles reload committed state after a refused release', () async {
    final a = NextServerCatalog(), b = NextServerCatalog();
    final original = await a.save(name: 'A', address: first, key: key);
    final entered = Completer<void>(), release = Completer<void>();
    final deleting = a.delete(
      original.id,
      beforeReplace: (owner) async {
        expect(owner, original.ownerId);
        entered.complete();
        await release.future;
        throw LibraryFailure.storage;
      },
    );
    await entered.future;
    final concurrent = b.save(name: 'B', address: second, key: replacement);
    release.complete();
    await expectLater(deleting, throwsA(LibraryFailure.storage));
    await concurrent;
    expect((await a.load()).servers.map((s) => s.name), ['A', 'B']);
  });
}
