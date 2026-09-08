import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/env/env.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/conversations/widgets/temporary_recording_controls.dart';
import 'package:omi/pages/home/widgets/battery_info_widget.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/utils/enums.dart';

class _Capture extends CaptureProvider {
  final calls = <String>[];
  bool muted = false;
  bool failStart = false;
  Completer<void>? startGate;

  @override
  bool get havingRecordingDevice => true;
  @override
  bool get isPaused => muted;
  @override
  Future<void> streamDeviceRecording({BtDevice? device, bool userInitiated = false}) async {
    calls.add('start:$userInitiated');
    await startGate?.future;
    if (failStart) throw StateError('Synthetic start failure');
    muted = false;
    updateRecordingState(RecordingState.deviceRecord);
  }

  @override
  Future<void> stopStreamDeviceRecording({bool cleanDevice = false}) async {
    calls.add('stop:$cleanDevice');
    updateRecordingState(RecordingState.stop);
  }

  @override
  Future<void> pauseDeviceRecording() async {
    calls.add('mute');
    muted = true;
    updateRecordingState(RecordingState.pause);
  }

  @override
  Future<void> resumeDeviceRecording() async {
    calls.add('unmute');
    muted = false;
    updateRecordingState(RecordingState.deviceRecord);
  }
}

Widget _app(Widget child) => MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SizedBox(width: 320, child: child)),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    Env.setRuntimeModeForTesting(OmiRuntimeMode.offline);
  });
  tearDown(() => Env.setRuntimeModeForTesting(null));

  testWidgets('start, mute, unmute and stop use existing functions; idle mute is disabled', (tester) async {
    final capture = _Capture();
    addTearDown(capture.dispose);
    await tester.pumpWidget(_app(ListenableBuilder(
      listenable: capture,
      builder: (_, __) => TemporaryRecordingControls(provider: capture),
    )));
    final start = find.byKey(const Key('temporary_start_recording'));
    final stop = find.byKey(const Key('temporary_stop_recording'));
    final mute = find.byKey(const Key('temporary_recording_mute'));
    bool enabled(Finder finder) => tester.widget<IconButton>(finder).onPressed != null;
    expect(enabled(start), isTrue);
    expect(enabled(stop), isFalse);
    expect(enabled(mute), isFalse);
    expect(tester.getCenter(start).dx, lessThan(tester.getCenter(stop).dx));
    expect(tester.getCenter(stop).dx, lessThan(tester.getCenter(mute).dx));
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(enabled(start), isFalse);
    expect(enabled(stop), isTrue);
    expect(enabled(mute), isTrue);
    await tester.tap(mute);
    await tester.pumpAndSettle();
    expect(capture.isPaused, isTrue);
    await tester.tap(mute);
    await tester.pumpAndSettle();
    expect(capture.isPaused, isFalse);
    await tester.tap(mute);
    await tester.pumpAndSettle();
    await tester.tap(stop);
    await tester.pumpAndSettle();
    expect(enabled(start), isTrue);
    expect(enabled(stop), isFalse);
    expect(enabled(mute), isFalse);
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(capture.isPaused, isFalse);
    expect(capture.calls, ['start:true', 'mute', 'unmute', 'mute', 'stop:false', 'start:true']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending start blocks duplicate actions and failed start closes the session', (tester) async {
    final capture = _Capture()..startGate = Completer<void>();
    addTearDown(capture.dispose);
    await tester.pumpWidget(_app(TemporaryRecordingControls(provider: capture)));
    await tester.tap(find.byKey(const Key('temporary_start_recording')));
    await tester.pump();
    expect(tester.widgetList<IconButton>(find.byType(IconButton)).every((button) => button.onPressed == null), isTrue);
    capture.failStart = true;
    capture.startGate!.complete();
    await tester.pumpAndSettle();
    expect(capture.calls, ['start:true', 'stop:false']);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.widget<IconButton>(find.byKey(const Key('temporary_recording_mute'))).onPressed, isNull);
  });

  testWidgets('phone button is gray and offers no tap or long press in local mode', (tester) async {
    await tester.pumpWidget(_app(const HomeRecordButton()));
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('temporary_phone_recording_disabled'));
    expect(tester.widget<Semantics>(button).properties.enabled, isFalse);
    expect(find.descendant(of: button, matching: find.byType(GestureDetector)), findsNothing);
    expect(tester.widget<Icon>(find.descendant(of: button, matching: find.byType(Icon))).color, Colors.grey);
    await tester.tap(button);
    await tester.longPress(button);
    await tester.pumpAndSettle();
    expect(find.byType(RecordOptionsSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
