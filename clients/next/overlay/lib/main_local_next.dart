import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:omi/local_next/home_shortcuts.dart';
import 'package:omi/local_next/local_next_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final shortcuts = Platform.isAndroid || Platform.isIOS ? NextHomeShortcuts() : null;
  if (shortcuts != null) unawaited(shortcuts.initialize());
  runApp(LocalNextApp(shortcuts: shortcuts));
}
