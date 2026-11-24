import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'paired_library.dart';

typedef _Fields = ({String name, String address, String key});
typedef NextOpenPair = PairedLibrary Function(String address, String key);
typedef NextBeforeReplace = Future<void> Function(String ownerId);

class NextSavedServer {
  const NextSavedServer._(this.id, this._fields, this._openPair, this._original, this._activeAtRead);
  final String id;
  final _Fields _fields;
  final NextOpenPair _openPair;
  final _Fields? _original;
  final int _activeAtRead;

  String get name => _fields.name;
  String get address => _fields.address;
  String get ownerId => PairedLibrary(address, _fields.key).audioOwnerId;
  PairedLibrary open() => _openPair(address, _fields.key);
}

class NextServerSnapshot {
  const NextServerSnapshot._(this.servers, this.activeId, this.startupDefaultId, this._delivery, this._groups);
  final List<NextSavedServer> servers;
  final String? activeId;
  final String? startupDefaultId;
  final bool _delivery;
  final bool _groups;
  NextSavedServer? get _active => servers.where((s) => s.id == activeId).firstOrNull;
  String? get activeOwnerId => _active?.ownerId;

  // A previous v2 receipt protocol permits offline journaling. All sends still re-verify.
  PairedLibrary? restoreActive() {
    final active = _active?.open();
    if (active != null) {
      active.audioDelivery = _delivery;
      active.conversationGroups = _groups;
    }
    return active;
  }
}

class _Catalog {
  final servers = <String, _Fields>{};
  final seenPresets = <String>{};
  String? activeId;
  String? startupDefaultId;
  bool delivery = false;
  bool groups = false;
  int activeRevision = 0;

  String? get activeOwner {
    final id = activeId;
    if (id == null) return null;
    final entry = servers[id]!;
    return PairedLibrary(entry.address, entry.key).audioOwnerId;
  }

  String encode() => jsonEncode({
    'version': 1,
    'servers': [
      for (final entry in servers.entries)
        {'id': entry.key, 'name': entry.value.name, 'url': entry.value.address, 'key': entry.value.key},
    ],
    'seen_presets': seenPresets.toList(),
    'active': activeId,
    if (startupDefaultId != null) 'startup_default': startupDefaultId,
    'active_revision': activeRevision,
    'delivery_version': delivery ? 2 : 0,
    if (groups) 'group_delivery_version': 1,
  });
}

class NextServerCatalog {
  NextServerCatalog({FlutterSecureStorage? storage, NextOpenPair? openPair})
    : _storage = storage ?? PairedLibrary.pairingStorage,
      _openPair = openPair ?? PairedLibrary.new;

  static const storageKey = 'server-catalog.v1';
  static final _presetId = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');
  static final _manualId = RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$');
  final FlutterSecureStorage _storage;
  final NextOpenPair _openPair;
  bool _legacyCleared = false;

  // All instances in the app isolate share one Keychain record. A failed write leaves
  // the next operation free to reload the last committed version.
  static Future<void>? _edits;
  Future<T> _serial<T>(Future<T> Function() operation) {
    final previous = _edits;
    final result = previous == null ? Future<T>.microtask(operation) : previous.then((_) => operation());
    late final Future<void> tail;
    tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {}).whenComplete(() {
      if (identical(_edits, tail)) _edits = null;
    });
    _edits = tail;
    return result;
  }

  static _Fields _fields(String name, String address, String rawKey) {
    final key = rawKey.replaceAll(RegExp(r'\s'), '');
    final canonical = PairedLibrary(address, key).origin.origin;
    final label = name.trim().isEmpty ? canonical : name.trim();
    if ((label != canonical && label.runes.length > 80) || label.runes.any((r) => r < 32 || r == 127)) {
      throw LibraryFailure.malformed;
    }
    return (name: label, address: canonical, key: key);
  }

  static _Catalog _decode(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['version'] != 1 ||
          value['servers'] is! List ||
          value['seen_presets'] is! List ||
          !value.containsKey('active') ||
          !(value['active'] == null || value['active'] is String) ||
          !const [0, 2].contains(value['delivery_version'])) {
        throw LibraryFailure.storage;
      }
      final catalog = _Catalog();
      for (final s in value['servers']) {
        final id = s['id'] as String;
        if ((!_presetId.hasMatch(id) && !_manualId.hasMatch(id)) || catalog.servers.containsKey(id)) {
          throw LibraryFailure.storage;
        }
        catalog.servers[id] = _fields(s['name'] as String, s['url'] as String, s['key'] as String);
      }
      for (final id in value['seen_presets']) {
        if (id is! String || !_presetId.hasMatch(id)) throw LibraryFailure.storage;
        catalog.seenPresets.add(id);
      }
      catalog.activeId = value['active'] as String?;
      catalog.startupDefaultId = value['startup_default'] as String?;
      catalog.activeRevision = (value['active_revision'] as int?) ?? 0;
      if (catalog.activeRevision < 0) throw LibraryFailure.storage;
      catalog.delivery = value['delivery_version'] == 2;
      catalog.groups = catalog.delivery && value['group_delivery_version'] == 1;
      if (catalog.activeId == null ? catalog.delivery : !catalog.servers.containsKey(catalog.activeId)) {
        throw LibraryFailure.storage;
      }
      if (catalog.startupDefaultId != null &&
          (catalog.activeId != null || !catalog.servers.containsKey(catalog.startupDefaultId))) {
        throw LibraryFailure.storage;
      }
      return catalog;
    } catch (_) {
      throw LibraryFailure.storage;
    }
  }

  Future<void> _write(_Catalog catalog) => _storage.write(key: storageKey, value: catalog.encode());

  Future<_Catalog> _load() async {
    final raw = await _storage.read(key: storageKey);
    final legacy = _legacyCleared ? null : await _storage.read(key: PairedLibrary.legacyPairingKey);
    final catalog = raw == null ? _Catalog() : _decode(raw);
    if (raw == null) {
      if (legacy != null) {
        try {
          final old = jsonDecode(legacy);
          final fields = _fields('', old['address'] as String, old['key'] as String);
          final id = const Uuid().v4();
          catalog.servers[id] = fields;
          catalog.activeId = id;
          catalog.delivery = old['deliveryVersion'] == 2;
        } catch (_) {
          throw LibraryFailure.storage;
        }
      }
      await _write(catalog);
    }
    // On an interrupted migration an existing catalog always wins, including an empty one.
    if (legacy != null) await _storage.delete(key: PairedLibrary.legacyPairingKey);
    _legacyCleared = true;
    return catalog;
  }

  NextSavedServer _entry(_Catalog catalog, String id, _Fields fields) =>
      NextSavedServer._(id, fields, _openPair, catalog.servers[id], catalog.activeRevision);

  Future<NextServerSnapshot> load() => _serial(() async {
    final catalog = await _load();
    return NextServerSnapshot._(
      List.unmodifiable(catalog.servers.entries.map((e) => _entry(catalog, e.key, e.value))),
      catalog.activeId,
      catalog.startupDefaultId,
      catalog.delivery,
      catalog.groups,
    );
  });

  NextSavedServer _prepare(_Catalog catalog, String? id, String name, String address, String key) {
    final previous = catalog.servers[id];
    if (id != null && previous == null) throw LibraryFailure.unavailable;
    if (key.trim().isEmpty) {
      if (previous == null || PairedLibrary.normalizeAddress(address).origin != previous.address) {
        throw LibraryFailure.key;
      }
      key = previous.key;
    }
    return _entry(catalog, id ?? const Uuid().v4(), _fields(name, address, key));
  }

  Future<NextSavedServer> prepare({String? id, required String name, required String address, required String key}) =>
      _serial(() async => _prepare(await _load(), id, name, address, key));

  static bool _replaces(NextSavedServer entry) {
    final previous = entry._original;
    return previous != null && (entry.address != previous.address || entry._fields.key != previous.key);
  }

  static Future<void> _checkReplacedOwner(NextSavedServer entry, NextBeforeReplace? beforeReplace) async {
    final previous = entry._original;
    if (previous != null && _replaces(entry)) {
      await _checkRelease(PairedLibrary(previous.address, previous.key).audioOwnerId, beforeReplace);
    }
  }

  static Future<void> _checkRelease(String owner, NextBeforeReplace? beforeReplace) async {
    if (beforeReplace != null) {
      await beforeReplace(owner);
    } else if (await PairedLibrary.retainedAudioFor(owner)) {
      throw LibraryFailure.storage;
    }
  }

  Future<NextSavedServer> save({
    String? id,
    required String name,
    required String address,
    required String key,
    NextBeforeReplace? beforeReplace,
  }) => _serial(() async {
    final catalog = await _load();
    final entry = _prepare(catalog, id, name, address, key);
    if (entry.id == catalog.activeId && _replaces(entry)) throw LibraryFailure.unavailable;
    await _checkReplacedOwner(entry, beforeReplace);
    catalog.servers[entry.id] = entry._fields;
    await _write(catalog);
    return _entry(catalog, entry.id, entry._fields);
  });

  Future<void> activate(NextSavedServer entry, PairedLibrary verified, {NextBeforeReplace? beforeReplace}) =>
      _serial(() async {
        final catalog = await _load();
        if (catalog.activeRevision != entry._activeAtRead || catalog.servers[entry.id] != entry._original) {
          throw LibraryFailure.unavailable;
        }
        if (!verified.isSignedIn || verified.audioOwnerId != entry.ownerId) throw LibraryFailure.key;
        await _checkReplacedOwner(entry, beforeReplace);
        if (!verified.isSignedIn) throw LibraryFailure.key;
        catalog.servers[entry.id] = entry._fields;
        catalog.activeId = entry.id;
        catalog.startupDefaultId = null;
        catalog.activeRevision++;
        catalog.delivery = verified.audioDelivery;
        catalog.groups = verified.conversationGroups;
        await _write(catalog);
      });

  Future<void> deactivate(String ownerId) => _serial(() async {
    final catalog = await _load();
    if (catalog.activeOwner != ownerId) return;
    catalog.activeId = null;
    catalog.activeRevision++;
    catalog.delivery = false;
    catalog.groups = false;
    await _write(catalog);
  });

  Future<void> delete(String id, {NextBeforeReplace? beforeReplace}) => _serial(() async {
    final catalog = await _load();
    final fields = catalog.servers[id];
    if (fields == null) return;
    if (id == catalog.activeId) throw LibraryFailure.unavailable;
    await _checkRelease(PairedLibrary(fields.address, fields.key).audioOwnerId, beforeReplace);
    catalog.servers.remove(id);
    if (catalog.startupDefaultId == id) catalog.startupDefaultId = null;
    if (_presetId.hasMatch(id)) catalog.seenPresets.add(id);
    await _write(catalog);
  });

  Future<void> importPresets(String encoded) async {
    final presets = <String, _Fields>{};
    String? defaultId;
    try {
      if (encoded.length > 44 * 1024) throw LibraryFailure.malformed;
      final bytes = base64Decode(encoded);
      if (bytes.length > 32 * 1024) throw LibraryFailure.malformed;
      final doc = jsonDecode(utf8.decode(bytes));
      if (doc is! Map ||
          doc.keys.any((key) => !const {'version', 'servers', 'default'}.contains(key)) ||
          doc['version'] != 1 ||
          doc['servers'] is! List) {
        throw LibraryFailure.malformed;
      }
      defaultId = doc['default'] as String?;
      final rows = doc['servers'] as List;
      if (rows.isEmpty || rows.length > 16) throw LibraryFailure.malformed;
      for (final row in rows) {
        if (row is! Map || row.length != 4 || row['name'] is! String) throw LibraryFailure.malformed;
        final name = (row['name'] as String).trim();
        if (name.isEmpty || name.runes.length > 80) {
          throw LibraryFailure.malformed;
        }
        final id = row['id'] as String;
        if (!_presetId.hasMatch(id) || presets.containsKey(id)) throw LibraryFailure.malformed;
        presets[id] = _fields(name, row['url'] as String, row['key'] as String);
      }
      if (defaultId != null && !presets.containsKey(defaultId)) throw LibraryFailure.malformed;
    } catch (_) {
      throw LibraryFailure.malformed;
    }
    await _serial(() async {
      final catalog = await _load();
      var changed = false;
      for (final entry in presets.entries) {
        if (!catalog.seenPresets.add(entry.key)) continue;
        if (!catalog.servers.containsKey(entry.key) &&
            !catalog.servers.values.any((v) => v.address == entry.value.address)) {
          catalog.servers[entry.key] = entry.value;
          if (entry.key == defaultId && catalog.activeId == null) catalog.startupDefaultId = entry.key;
        }
        changed = true;
      }
      if (changed) await _write(catalog);
    });
  }
}
