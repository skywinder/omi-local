import 'package:flutter_test/flutter_test.dart';
import 'package:omi/local_next/home_shortcuts.dart';
import 'package:quick_actions/quick_actions.dart';

class _Launcher extends QuickActions {
  late void Function(String) launch;
  List<ShortcutItem> items = [];

  @override
  Future<void> initialize(void Function(String) handler) async {
    launch = handler;
  }

  @override
  Future<void> setShortcutItems(List<ShortcutItem> items) async {
    this.items = items;
  }
}

void main() {
  test('launcher reconfiguration and pending actions stay with their pairing and capability', () async {
    final launcher = _Launcher();
    final shortcuts = NextHomeShortcuts(launcher);
    await shortcuts.initialize();
    shortcuts.publish('first', {NextHomeAction.task: 'Add task'});
    shortcuts.publish('second', {NextHomeAction.device: 'Device', NextHomeAction.mute: 'Mute'});
    await Future<void>.delayed(Duration.zero);
    expect(launcher.items.map((item) => item.type), ['device.second', 'mute.second']);

    launcher.launch('task.first');
    expect(shortcuts.take('second', {NextHomeAction.task}), isNull);
    launcher.launch('mute.second');
    expect(shortcuts.take('second', {NextHomeAction.unmute}), isNull);
    launcher.launch('device.second');
    expect(shortcuts.take('second', {NextHomeAction.device}), NextHomeAction.device);
    expect(shortcuts.take('second', {NextHomeAction.device}), isNull);
    shortcuts.dispose();
  });
}
