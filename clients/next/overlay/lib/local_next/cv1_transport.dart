import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'cv1_capture.dart';
import 'cv1_history.dart';

export 'cv1_history.dart';

sealed class Cv1TransportEvent {
  const Cv1TransportEvent();

  static Cv1TransportEvent? fromMessage(Object? message) {
    if (message is! Map) return null;
    // StandardMessageCodec delivers typed bytes without changing the GATT frame.
    switch (message) {
      case {'type': 'diagnostics', 'generation': final int generation, 'values': final Map values} when generation > 0:
        return Cv1DiagnosticsEvent(generation, Cv1Diagnostics.fromWire(values), measurement: message['measurement']);
      case {'type': 'device', 'id': final String id, 'name': final String name} when id.isNotEmpty:
        return Cv1DeviceFound(id, name);
      case {'type': 'state', 'phase': final String phaseName, 'generation': final int gen} when gen >= 0:
        for (final phase in Cv1LinkPhase.values) {
          if (phase.name != phaseName) continue;
          final codec = message['codec'];
          if (phase == Cv1LinkPhase.ready && (codec != 20 && codec != 21)) {
            return Cv1TransportState(Cv1LinkPhase.failed, gen, reason: Cv1LinkReason.incompatible);
          }
          final code = message['code'];
          final deviceId = message['deviceId'];
          final reason = Cv1LinkReason.values.where((reason) => reason.name == message['reason']).firstOrNull;
          return Cv1TransportState(
            phase,
            gen,
            codec: codec is int ? codec : null,
            reason: reason,
            code: code is int && code >= 0 && code <= 65535 ? code : null,
            deviceId: deviceId is String && deviceId.isNotEmpty ? deviceId : null,
          );
        }
      case {
            'type': 'audio',
            'generation': final int gen,
            'subscription': final int subscription,
            'bytes': final Uint8List bytes,
          }
          when gen > 0 && subscription > 0:
        return Cv1RawAudio(gen, subscription, bytes);
      case {'type': 'button', 'generation': final int gen, 'code': final int code} when gen > 0 && code >= 0:
        return Cv1RawButton(gen, code);
    }
    return null;
  }
}

class Cv1Diagnostics {
  const Cv1Diagnostics({
    this.name,
    this.firmware,
    this.hardware,
    this.model,
    this.manufacturer,
    this.battery,
    this.rssi,
    this.led,
    this.gain,
    this.charging,
    this.ledWritable = false,
    this.gainWritable = false,
  });

  final String? name, firmware, hardware, model, manufacturer;
  final int? battery, rssi, led, gain;
  final bool? charging;
  final bool ledWritable, gainWritable;

  factory Cv1Diagnostics.fromWire(Map values) {
    int? number(String key, int min, int max) {
      final value = values[key];
      return value is int && value >= min && value <= max ? value : null;
    }

    String? text(String key) {
      final value = values[key];
      return value is String && value.isNotEmpty && value.length <= 80 ? value : null;
    }

    return Cv1Diagnostics(
      name: text('name'),
      firmware: text('firmware'),
      hardware: text('hardware'),
      model: text('model'),
      manufacturer: text('manufacturer'),
      battery: number('battery', 0, 100),
      rssi: number('rssi', -127, -1),
      led: number('led', 0, 100),
      gain: number('gain', 0, 100),
      charging: values['charging'] is bool ? values['charging'] as bool : null,
      ledWritable: values['ledWritable'] == true,
      gainWritable: values['gainWritable'] == true,
    );
  }
}

final class Cv1DiagnosticsEvent extends Cv1TransportEvent {
  const Cv1DiagnosticsEvent(this.generation, this.values, {this.measurement});

  final int generation;
  final Cv1Diagnostics values;
  final Object? measurement;
}

final class Cv1DeviceFound extends Cv1TransportEvent {
  const Cv1DeviceFound(this.id, this.name);

  final String id;
  final String name;
}

final class Cv1TransportState extends Cv1TransportEvent {
  const Cv1TransportState(this.phase, this.generation, {this.codec, this.reason, this.code, this.deviceId});

  final Cv1LinkPhase phase;
  final int generation;
  final int? codec, code;
  final Cv1LinkReason? reason;
  final String? deviceId;
}

final class Cv1RawAudio extends Cv1TransportEvent {
  const Cv1RawAudio(this.generation, this.subscription, this.bytes);

  final int generation;
  final int subscription;
  final Uint8List bytes;
}

final class Cv1RawButton extends Cv1TransportEvent {
  const Cv1RawButton(this.generation, this.code);

  final int generation;
  final int code;
}

abstract interface class Cv1Transport {
  Stream<Cv1TransportEvent> get events;

  Future<void> scan();
  Future<void> connect(String id);
  Future<void> disconnect();
  Future<void> setAudio(int generation, int subscription, bool enabled);
  Future<void> close();
}

abstract interface class Cv1DiagnosticsTransport {
  Future<void> sampleDiagnostics();
  Future<void> sampleSignal();
  Future<void> writeSetting(int generation, String field, int value);
}

class Cv1PermissionDenied implements Exception {}

class ChannelCv1Transport implements Cv1Transport, Cv1DiagnosticsTransport {
  static const _methods = MethodChannel('org.omilocal.next/cv1');
  static const _events = EventChannel('org.omilocal.next/cv1.events');

  @override
  late final Stream<Cv1TransportEvent> events = _events
      .receiveBroadcastStream()
      .map(Cv1TransportEvent.fromMessage)
      .where((event) => event != null)
      .cast<Cv1TransportEvent>();

  @override
  Future<void> scan() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final legacy = await _methods.invokeMethod<bool>('usesLegacyScanPermission') == true;
      final permissions = legacy
          ? [Permission.locationWhenInUse]
          : [Permission.bluetoothScan, Permission.bluetoothConnect];
      final choices = await permissions.request();
      if (choices.values.any((value) => !value.isGranted)) throw Cv1PermissionDenied();
    }
    await _methods.invokeMethod<void>('scan');
  }

  @override
  Future<void> sampleDiagnostics() => _methods.invokeMethod<void>('sampleDiagnostics');

  @override
  Future<void> sampleSignal() => _methods.invokeMethod<void>('sampleSignal');

  @override
  Future<void> writeSetting(int generation, String field, int value) =>
      _methods.invokeMethod<void>('writeSetting', {'generation': generation, 'field': field, 'value': value});

  @override
  Future<void> connect(String id) => _methods.invokeMethod<void>('connect', {'id': id});

  @override
  Future<void> disconnect() => _methods.invokeMethod<void>('disconnect');

  @override
  Future<void> setAudio(int generation, int subscription, bool enabled) => _methods.invokeMethod<void>('setAudio', {
    'generation': generation,
    'subscription': subscription,
    'enabled': enabled,
  });

  @override
  Future<void> close() => _methods.invokeMethod<void>('close');
}

class UnavailableCv1Transport implements Cv1Transport {
  const UnavailableCv1Transport();

  @override
  Stream<Cv1TransportEvent> get events => const Stream.empty();

  @override
  Future<void> scan() async {}

  @override
  Future<void> connect(String id) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> setAudio(int generation, int subscription, bool enabled) async {}

  @override
  Future<void> close() async {}
}

/// Owns the single native event subscription and reconciles audio notification
/// demand for the live link. Capture admission and journal custody stay with
/// [NextCv1Capture], even if CoreBluetooth is still disabling notifications.
class Cv1Connection extends ChangeNotifier {
  Cv1Connection(this._transport, this._capture, {Cv1History? history}) : history = history ?? Cv1History() {
    _capture.addListener(_demandChanged);
    _subscription = _transport.events.listen(_onEvent, onError: (Object _) => _linkEnded(), onDone: _linkEnded);
  }

  final Cv1Transport _transport;
  final NextCv1Capture _capture;
  late final StreamSubscription<Cv1TransportEvent> _subscription;
  final _devices = <String, Cv1DeviceFound>{};
  Cv1LinkPhase phase = Cv1LinkPhase.idle;
  bool operationFailed = false;
  bool permissionDenied = false;
  bool audioFailed = false;
  Cv1TransportState? linkState;
  String? _firstPairAttempt;
  Timer? _pairRetry;
  int? codec;
  Cv1Diagnostics? diagnostics;
  DateTime? connectedAt;
  int reconnections = 0;
  bool _wasConnected = false;
  String? _selected;
  String? _linkedDeviceId;
  String? get linkedDeviceId => _linkedDeviceId;
  final Cv1History history;
  DateTime? _lostAt;
  DateTime? batteryMeasuredAt;
  DateTime? signalMeasuredAt;

  List<Cv1Sample> get batteryHistory => history.battery;
  List<Cv1Sample> get rssiHistory => history.signal;
  List<Cv1Transition> get transitions => history.events;

  int _generation = 0;
  bool _closing = false;
  Future<void>? _close;
  bool _updatingAudio = false;
  int? _nativeSubscription;
  int _subscriptionSerial = 0;
  bool _wantsAudio = false;
  ValueChanged<Uint8List>? _calibration;
  bool get calibrating => _calibration != null;

  List<Cv1DeviceFound> get devices => List.unmodifiable(_devices.values);

  bool beginCalibration(ValueChanged<Uint8List> accept) {
    if (_closing || phase != Cv1LinkPhase.ready || _capture.active || _capture.sealing || calibrating) return false;
    _calibration = accept;
    _demandChanged();
    notifyListeners();
    return true;
  }

  void endCalibration(ValueChanged<Uint8List> accept) {
    if (_closing || !identical(accept, _calibration)) return;
    _calibration = null;
    _demandChanged();
    notifyListeners();
  }

  Future<void> scan() => _command(() {
    _cancelPairRetry();
    _devices.clear();
    return _transport.scan();
  });

  Future<void> connect(String id) => _command(() {
    _cancelPairRetry();
    _firstPairAttempt = id;
    if (_selected != id) {
      _selected = id;
      _wasConnected = false;
      reconnections = 0;
      _lostAt = null;
    }
    return _transport.connect(id);
  });

  Future<void> sampleDiagnostics() async {
    final transport = _transport;
    if (_closing || phase != Cv1LinkPhase.ready || transport is! Cv1DiagnosticsTransport) return;
    try {
      await (transport as Cv1DiagnosticsTransport).sampleDiagnostics();
    } catch (_) {
      // The next refresh may succeed. A read failure does not change capture ownership.
    }
  }

  Future<bool> writeSetting(String field, int value) async {
    final transport = _transport;
    if (_closing || calibrating || phase != Cv1LinkPhase.ready || transport is! Cv1DiagnosticsTransport) return false;
    final generation = _generation;
    try {
      await (transport as Cv1DiagnosticsTransport).writeSetting(generation, field, value);
      return !_closing && generation == _generation;
    } catch (_) {
      return false;
    }
  }

  Future<void> sampleSignal() async {
    final transport = _transport;
    if (_closing || phase != Cv1LinkPhase.ready || transport is! Cv1DiagnosticsTransport) return;
    try {
      await (transport as Cv1DiagnosticsTransport).sampleSignal();
    } catch (_) {
      // RSSI is best-effort and never owns the connection.
    }
  }

  void _recordEvent(Cv1LinkPhase next, {Cv1LinkReason? reason, int? code}) {
    final at = history.now();
    if (phase == Cv1LinkPhase.ready && next != Cv1LinkPhase.ready) _lostAt = at;
    final lostAt = _lostAt;
    final connected = connectedAt;
    history.addEvent((
      at: at,
      phase: next,
      reason: reason,
      code: code,
      battery: diagnostics?.battery,
      rssi: diagnostics?.rssi,
      uptime: connected != null ? at.difference(connected) : null,
      downtime: next == Cv1LinkPhase.ready && lostAt != null ? at.difference(lostAt) : null,
    ));
    if (next == Cv1LinkPhase.ready || reason == Cv1LinkReason.manual) _lostAt = null;
  }

  void _cancelPairRetry() {
    _firstPairAttempt = null;
    _pairRetry?.cancel();
    _pairRetry = null;
  }

  Future<void> disconnect() {
    _cancelPairRetry();
    return _command(_transport.disconnect);
  }

  Future<void> _command(Future<void> Function() command) async {
    if (_closing) return;
    operationFailed = false;
    permissionDenied = false;
    try {
      final pending = command();
      notifyListeners();
      await pending;
    } catch (error) {
      if (_closing) return;
      permissionDenied = error is Cv1PermissionDenied;
      if (permissionDenied) _recordEvent(phase, reason: Cv1LinkReason.permission);
      operationFailed = true;
      notifyListeners();
    }
  }

  void _linkEnded() {
    if (_closing) return;
    _onEvent(Cv1TransportState(Cv1LinkPhase.failed, _generation, reason: Cv1LinkReason.dropped));
  }

  void _onEvent(Cv1TransportEvent event) {
    if (_closing) return;
    switch (event) {
      case Cv1DeviceFound():
        _devices[event.id] = event;
        notifyListeners();
      case Cv1TransportState():
        if (event.generation < _generation) return;
        linkState = event;
        final pairingTarget = _firstPairAttempt;
        if (event.phase == Cv1LinkPhase.failed && event.reason == Cv1LinkReason.timeout && pairingTarget != null) {
          _firstPairAttempt = null;
          _pairRetry = Timer(const Duration(seconds: 2), () {
            if (!_closing && phase == Cv1LinkPhase.failed && _generation == event.generation) {
              unawaited(_command(() => _transport.connect(pairingTarget)));
            }
          });
        } else if (event.phase == Cv1LinkPhase.ready ||
            event.phase == Cv1LinkPhase.reconnecting ||
            event.phase == Cv1LinkPhase.unavailable ||
            event.phase == Cv1LinkPhase.failed) {
          _cancelPairRetry();
        }
        final wasReady = phase == Cv1LinkPhase.ready && event.generation == _generation;
        if (!wasReady || event.phase != Cv1LinkPhase.ready || codec != event.codec) _calibration = null;
        if (phase != event.phase || event.reason != null || (phase == Cv1LinkPhase.ready && !wasReady)) {
          _recordEvent(event.phase, reason: event.reason, code: event.code);
        }
        phase = event.phase;
        _generation = event.generation;
        _linkedDeviceId = phase == Cv1LinkPhase.ready || phase == Cv1LinkPhase.reconnecting ? event.deviceId : null;
        if (phase == Cv1LinkPhase.ready && event.codec != null) {
          codec = event.codec;
          if (!wasReady) {
            if (_wasConnected) reconnections++;
            _wasConnected = true;
            connectedAt = history.now();
            history.beginLink();
            diagnostics = null;
            batteryMeasuredAt = null;
            signalMeasuredAt = null;
            // Native starts with audio notifications disabled on every link.
            _nativeSubscription = null;
            _wantsAudio = false;
            audioFailed = false;
          }
          _capture.handle(Cv1LinkReady(_generation, event.codec!));
          if (!wasReady) unawaited(sampleDiagnostics());
        } else {
          connectedAt = null;
          batteryMeasuredAt = null;
          signalMeasuredAt = null;
          codec = null;
          diagnostics = null;
          _nativeSubscription = null;
          audioFailed = false;
          _capture.handle(Cv1LinkLost(_generation));
        }
        _demandChanged();
        notifyListeners();
      case Cv1DiagnosticsEvent():
        if (phase == Cv1LinkPhase.ready && event.generation == _generation) {
          final previous = diagnostics;
          diagnostics = event.values;
          if (event.values.battery case final battery?) {
            if (event.measurement == 'battery' || previous?.battery != battery) {
              batteryMeasuredAt = history.now();
              history.measureBattery(battery);
            }
          }
          if (event.values.rssi case final rssi?) {
            if (event.measurement == 'rssi' || previous?.rssi != rssi) {
              signalMeasuredAt = history.now();
              history.measureSignal(rssi);
            }
          }
          notifyListeners();
        }
      case Cv1RawAudio():
        if (phase == Cv1LinkPhase.ready &&
            event.generation == _generation &&
            event.subscription == _desiredSubscription) {
          final calibration = _calibration;
          if (calibration != null) {
            calibration(event.bytes);
          } else {
            _capture.handle(Cv1Audio(event.generation, event.bytes));
          }
        }
      case Cv1RawButton():
        if (phase == Cv1LinkPhase.ready && !calibrating && event.generation == _generation) {
          _capture.handle(Cv1Button(event.generation, event.code));
        }
    }
  }

  int? get _desiredSubscription => _wantsAudio ? _subscriptionSerial : null;

  void _demandChanged() {
    if (_closing) return;
    final wants = phase == Cv1LinkPhase.ready && (_capture.wantsAudio || calibrating);
    if (wants != _wantsAudio) {
      _wantsAudio = wants;
      if (wants) {
        _subscriptionSerial++;
        audioFailed = false;
      }
    }
    if (!_updatingAudio && phase == Cv1LinkPhase.ready && _nativeSubscription != _desiredSubscription) {
      unawaited(_updateAudio());
    }
  }

  Future<void> _updateAudio() async {
    _updatingAudio = true;
    try {
      while (!_closing && phase == Cv1LinkPhase.ready && _nativeSubscription != _desiredSubscription) {
        final generation = _generation;
        final previous = _nativeSubscription;
        final enabled = previous == null;
        final subscription = previous ?? _desiredSubscription!;
        // Disable an old subscription before starting a new one, even when a
        // Stop and a subsequent Start arrived during the same pending await.
        _nativeSubscription = enabled ? subscription : null;
        var failed = false;
        try {
          await _transport.setAudio(generation, subscription, enabled);
        } catch (_) {
          failed = true;
        }
        if (!_closing && phase == Cv1LinkPhase.ready && generation == _generation && audioFailed != failed) {
          audioFailed = failed;
          if (failed) _recordEvent(Cv1LinkPhase.ready, reason: Cv1LinkReason.audio);
          notifyListeners();
        }
      }
    } finally {
      _updatingAudio = false;
    }
  }

  Future<void> close() => _close ??= _shutdown();

  Future<void> _shutdown() async {
    _closing = true;
    _calibration = null;
    _cancelPairRetry();
    _capture.removeListener(_demandChanged);
    try {
      await _subscription.cancel();
    } finally {
      await history.flush();
      try {
        await _transport.close();
      } on MissingPluginException {
        // There are no callbacks to stop on a build without the channel.
      }
    }
  }
}
