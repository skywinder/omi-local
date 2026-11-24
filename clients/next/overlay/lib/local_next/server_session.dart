import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'paired_library.dart';
import 'server_catalog.dart';

enum ServerSelectionFailure { recording, retained, activeEdit }

class NextServerSession extends ChangeNotifier {
  NextServerSession(
    this.catalog, {
    this.readPresets = _launchPresets,
    this.retainedAudio = PairedLibrary.retainedAudioFor,
  });
  final Future<bool> Function(String ownerId) retainedAudio;
  final NextServerCatalog catalog;
  final Future<String?> Function() readPresets;
  PairedLibrary? active;
  String? activeId;
  List<NextSavedServer> servers = const [];
  Object? failure;
  bool _working = false, _revoking = false, _disposed = false;
  Completer<void>? _publishing;
  bool get busy => _working || _revoking;

  static Future<String?> _launchPresets() async {
    try {
      final settings = await const MethodChannel(
        'org.omilocal.next/environment',
      ).invokeMapMethod<String, String>('takeLocalMacSettings');
      if (settings == null) return null;
      final encoded = settings['server_presets_b64'];
      if (encoded == null) throw LibraryFailure.malformed;
      return encoded;
    } on MissingPluginException {
      return null;
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void clearFailure() {
    if (busy || failure == null) return;
    failure = null;
    _changed();
  }

  Future<T?> _run<T>(Future<T> Function() operation) async {
    if (busy || _disposed) return null;
    _working = true;
    failure = null;
    _changed();
    try {
      return await operation();
    } catch (error) {
      failure = error is LibraryFailure || error is ServerSelectionFailure ? error : LibraryFailure.storage;
      return null;
    } finally {
      _working = false;
      _changed();
    }
  }

  Future<void> initialize() async {
    await _run(() async {
      // An invalid optional installer handoff must not hide an existing pairing.
      try {
        final encoded = await readPresets();
        if (encoded != null) await catalog.importPresets(encoded);
      } catch (error) {
        failure = error is LibraryFailure ? error : LibraryFailure.storage;
      }
      final snapshot = await catalog.load();
      if (_disposed) return;
      servers = snapshot.servers;
      final restored = snapshot.restoreActive();
      if (restored != null) _publish(restored, snapshot.activeId!);
    });
  }

  void _publish(PairedLibrary next, String id) {
    final old = active;
    active = next;
    activeId = id;
    next.onKeyRejected = () => unawaited(_revoke(next));
    if (old != null) {
      old.onKeyRejected = null;
      old.close();
    }
    _changed();
  }

  Future<void> _revoke(PairedLibrary rejected) async {
    if (active != rejected || _disposed) return;
    active = null;
    activeId = null;
    rejected.onKeyRejected = null;
    rejected.close();
    _revoking = true;
    failure = LibraryFailure.key;
    _changed();
    try {
      // A response from the old client may arrive during a same-owner reconnect.
      // Retire its routes immediately, but keep a subsequently verified session.
      final publishing = _publishing;
      if (publishing != null) await publishing.future;
      if (active?.audioOwnerId != rejected.audioOwnerId) await catalog.deactivate(rejected.audioOwnerId);
      await _reload();
    } catch (_) {
      failure = LibraryFailure.storage;
    } finally {
      _revoking = false;
      _changed();
    }
  }

  int _read = 0;
  Future<void> _reload() async {
    final sequence = ++_read;
    final snapshot = await catalog.load();
    if (!_disposed && _read == sequence) servers = snapshot.servers;
  }

  Future<void> _checkOutbox(String ownerId) async {
    if (await retainedAudio(ownerId)) throw ServerSelectionFailure.retained;
  }

  Future<NextSavedServer?> save({String? id, required String name, required String address, required String key}) =>
      _run(() async {
        final draft = await catalog.prepare(id: id, name: name, address: address, key: key);
        final prior = servers.where((e) => e.id == id).firstOrNull;
        if (prior != null && prior.id == activeId && prior.ownerId != draft.ownerId) {
          throw ServerSelectionFailure.activeEdit;
        }
        final entry = await catalog.save(id: id, name: name, address: address, key: key, beforeReplace: _checkOutbox);
        await _reload();
        return entry;
      });

  Future<void> connect({String? id, required String name, required String address, required String key}) async {
    await _run(() async {
      final entry = await catalog.prepare(id: id, name: name, address: address, key: key);
      final candidate = entry.open();
      PairedLibrary? held;
      try {
        try {
          await candidate.verify();
        } on LibraryFailure {
          rethrow;
        } catch (_) {
          throw LibraryFailure.unavailable;
        }
        if (_disposed) return;
        final old = active;
        if (old != null) {
          if (!old.ownerChange.tryHold()) throw ServerSelectionFailure.recording;
          held = old;
        }
        final publishing = _publishing = Completer<void>();
        try {
          await catalog.activate(entry, candidate, beforeReplace: _checkOutbox);
          if (_disposed) return;
          failure = null;
          _publish(candidate, entry.id);
        } finally {
          _publishing = null;
          publishing.complete();
        }
        await _reload();
      } finally {
        if (active != candidate) candidate.close();
        if (active == held) held?.ownerChange.release();
      }
    });
  }

  Future<void> disconnect() async {
    await _run(() async {
      final old = active;
      if (old == null) return;
      if (!old.ownerChange.tryHold()) throw ServerSelectionFailure.recording;
      try {
        await catalog.deactivate(old.audioOwnerId);
        if (active == old) {
          active = null;
          activeId = null;
          old.onKeyRejected = null;
          old.close();
          _changed();
        }
      } finally {
        if (active == old) old.ownerChange.release();
      }
      await _reload();
    });
  }

  Future<void> remove(NextSavedServer expected) async {
    await _run(() async {
      if (expected.id == activeId) throw ServerSelectionFailure.activeEdit;
      await catalog.delete(
        expected.id,
        beforeReplace: (owner) {
          if (owner != expected.ownerId) throw LibraryFailure.storage;
          return _checkOutbox(owner);
        },
      );
      await _reload();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    active?.onKeyRejected = null;
    active?.close();
    super.dispose();
  }
}
