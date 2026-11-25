import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:quick_actions/quick_actions.dart';

enum NextHomeAction { device, task, mute, unmute }

/// A launcher can keep old shortcuts after the user changes servers.
class NextHomeShortcuts extends ChangeNotifier {
  NextHomeShortcuts([this._platform = const QuickActions()]);
  final QuickActions _platform;
  String? _pending;
  Future<void> _publication = Future.value();
  List<String>? _published;

  Future<void> initialize() async {
    await _platform.initialize((type) {
      _pending = type;
      notifyListeners();
    });
  }

  NextHomeAction? take(String owner, Set<NextHomeAction> available) {
    final type = _pending;
    _pending = null;
    return available.where((action) => type == '${action.name}.$owner').firstOrNull;
  }

  void publish(String owner, Map<NextHomeAction, String> labels) {
    final items = [
      for (final entry in labels.entries) ShortcutItem(type: '${entry.key.name}.$owner', localizedTitle: entry.value),
    ];
    final signature = [for (final item in items) '${item.type} ${item.localizedTitle}'];
    if (listEquals(_published, signature)) return;
    _published = signature;
    _publication = _publication.then((_) async {
      if (!identical(_published, signature)) return;
      try {
        await _platform.setShortcutItems(items);
      } on PlatformException {
        if (identical(_published, signature)) _published = null;
      }
    });
  }
}
