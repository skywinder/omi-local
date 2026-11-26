import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'paired_library.dart';

class TaskReminderSync extends ChangeNotifier {
  static const _native = MethodChannel('org.omilocal.next/reminders');
  static const _ownerPreference = 'next.taskReminderOwner';
  PairedLibrary? _active;
  Future<void> _tail = Future.value();
  bool _disposed = false;
  bool enabled = false;
  bool precise = true;
  bool permissionMissing = false;
  bool syncFailed = false;

  static Future<String> timezone() async {
    final value = await _native.invokeMethod<String>('timezone');
    if (value == null || value.isEmpty) throw LibraryFailure.unavailable;
    return value;
  }

  static String _preference(PairedLibrary library) => 'next.taskReminders.${library.audioOwnerId}';
  bool _current(PairedLibrary library) => !_disposed && identical(library, _active);

  Future<void> _serial(Future<void> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.catchError((Object _) {});
    return next;
  }

  void bind(PairedLibrary? library) {
    final previous = _active;
    if (identical(previous, library)) return;
    _active = library;
    enabled = false;
    precise = true;
    permissionMissing = false;
    syncFailed = false;
    final owner = library?.audioOwnerId;
    unawaited(
      _serial(() async {
        final prefs = await SharedPreferences.getInstance();
        if (_disposed || !identical(_active, library)) return;
        final oldOwner = prefs.getString(_ownerPreference);
        if (oldOwner != null && oldOwner != owner) await _native.invokeMethod<void>('clear');
        if (owner == null) {
          await prefs.remove(_ownerPreference);
        } else {
          await prefs.setString(_ownerPreference, owner);
        }
      }).catchError((Object _) {
        if (library != null && _current(library)) {
          syncFailed = true;
          notifyListeners();
        }
      }),
    );
    if (!_disposed) notifyListeners();
  }

  Future<void> setEnabled(PairedLibrary library, bool wanted, String title) => _serial(() async {
    if (!_current(library)) return;
    final prefs = await SharedPreferences.getInstance();
    if (!_current(library)) return;
    if (wanted) {
      if (defaultTargetPlatform == TargetPlatform.android) {
        await Permission.notification.request();
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _native.invokeMethod('request');
      }
      if (!_current(library)) return;
      final status = await _native.invokeMapMethod<String, bool>('status');
      if (!_current(library)) return;
      permissionMissing = status?['allowed'] != true;
      if (permissionMissing) {
        notifyListeners();
        return;
      }
    }
    await prefs.setBool(_preference(library), wanted);
    if (!_current(library)) return;
    enabled = wanted;
    permissionMissing = false;
    if (!wanted) await _native.invokeMethod<void>('clear');
    if (_current(library)) notifyListeners();
    if (wanted) await _apply(library, title);
  });

  Future<void> exactSettings() => _native.invokeMethod<void>('exactSettings');

  Future<void> sync(PairedLibrary library, String title) => _serial(() async {
    if (!_current(library)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_current(library) || prefs.getString(_ownerPreference) != library.audioOwnerId) return;
      enabled = prefs.getBool(_preference(library)) ?? false;
      if (enabled) {
        await _apply(library, title);
      } else {
        notifyListeners();
      }
    } catch (_) {
      if (!_current(library)) return;
      syncFailed = true;
      notifyListeners();
    }
  });

  Future<void> _apply(PairedLibrary library, String title) async {
    try {
      final status = await _native.invokeMapMethod<String, bool>('status');
      if (!_current(library)) return;
      permissionMissing = status?['allowed'] != true;
      precise = status?['precise'] == true;
      if (!permissionMissing && library.taskRemindersAvailable) {
        final reminders = await library.readTaskReminders();
        if (!_current(library)) return;
        final result = await _native.invokeMapMethod<String, bool>('replace', [
          for (final row in reminders)
            {
              'id': row.id,
              'title': title,
              'body': row.description,
              'at': row.at.millisecondsSinceEpoch,
              'exact': row.exact,
            },
        ]);
        if (!_current(library)) return;
        permissionMissing = result?['allowed'] != true;
        precise = result?['precise'] == true;
      }
      syncFailed = !library.taskRemindersAvailable;
    } catch (_) {
      if (!_current(library)) return;
      // Keep the last locally scheduled reminders during a transient server outage.
      syncFailed = true;
    }
    if (_current(library)) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
