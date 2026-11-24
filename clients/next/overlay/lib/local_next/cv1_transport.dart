import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cv1_capture.dart';

enum Cv1LinkPhase { idle, unavailable, scanning, connecting, ready, reconnecting, failed }

sealed class Cv1TransportEvent {
  const Cv1TransportEvent();

  static Cv1TransportEvent? fromMessage(Object? message) {
    if (message is! Map) return null;
    // StandardMessageCodec delivers typed bytes without changing the GATT frame.
    switch (message) {
      case {'type': 'device', 'id': final String id, 'name': final String name} when id.isNotEmpty:
        return Cv1DeviceFound(id, name);
      case {'type': 'state', 'phase': final String phaseName, 'generation': final int gen} when gen >= 0:
        for (final phase in Cv1LinkPhase.values) {
          if (phase.name != phaseName) continue;
          final codec = message['codec'];
          if (phase == Cv1LinkPhase.ready && (codec != 20 && codec != 21)) {
            return Cv1TransportState(Cv1LinkPhase.failed, gen);
          }
          return Cv1TransportState(phase, gen, codec: codec is int ? codec : null);
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

final class Cv1DeviceFound extends Cv1TransportEvent {
  const Cv1DeviceFound(this.id, this.name);

  final String id;
  final String name;
}

final class Cv1TransportState extends Cv1TransportEvent {
  const Cv1TransportState(this.phase, this.generation, {this.codec});

  final Cv1LinkPhase phase;
  final int generation;
  final int? codec;
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

class IosCv1Transport implements Cv1Transport {
  static const _methods = MethodChannel('org.omilocal.next/cv1');
  static const _events = EventChannel('org.omilocal.next/cv1.events');

  @override
  late final Stream<Cv1TransportEvent> events = _events
      .receiveBroadcastStream()
      .map(Cv1TransportEvent.fromMessage)
      .where((event) => event != null)
      .cast<Cv1TransportEvent>();

  @override
  Future<void> scan() => _methods.invokeMethod<void>('scan');

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

/// Owns the single native event subscription and reconciles audio notification
/// demand for the live link. Capture admission and journal custody stay with
/// [NextCv1Capture], even if CoreBluetooth is still disabling notifications.
class Cv1Connection extends ChangeNotifier {
  Cv1Connection(this._transport, this._capture) {
    _capture.addListener(_demandChanged);
    _subscription = _transport.events.listen(_onEvent, onError: (Object _) => _linkEnded(), onDone: _linkEnded);
  }

  final Cv1Transport _transport;
  final NextCv1Capture _capture;
  late final StreamSubscription<Cv1TransportEvent> _subscription;
  final _devices = <String, Cv1DeviceFound>{};
  Cv1LinkPhase phase = Cv1LinkPhase.idle;
  bool operationFailed = false;
  bool audioFailed = false;
  int _generation = 0;
  bool _closing = false;
  Future<void>? _close;
  bool _updatingAudio = false;
  int? _nativeSubscription;
  int _subscriptionSerial = 0;
  bool _wantsAudio = false;

  List<Cv1DeviceFound> get devices => List.unmodifiable(_devices.values);

  Future<void> scan() => _command(() {
    _devices.clear();
    return _transport.scan();
  });

  Future<void> connect(String id) => _command(() => _transport.connect(id));

  Future<void> disconnect() => _command(_transport.disconnect);

  Future<void> _command(Future<void> Function() command) async {
    if (_closing) return;
    operationFailed = false;
    try {
      final pending = command();
      notifyListeners();
      await pending;
    } catch (_) {
      if (_closing) return;
      operationFailed = true;
      notifyListeners();
    }
  }

  void _linkEnded() {
    if (_closing) return;
    _onEvent(Cv1TransportState(Cv1LinkPhase.failed, _generation));
  }

  void _onEvent(Cv1TransportEvent event) {
    if (_closing) return;
    switch (event) {
      case Cv1DeviceFound():
        _devices[event.id] = event;
        notifyListeners();
      case Cv1TransportState():
        if (event.generation < _generation) return;
        final wasReady = phase == Cv1LinkPhase.ready && event.generation == _generation;
        phase = event.phase;
        _generation = event.generation;
        if (phase == Cv1LinkPhase.ready && event.codec != null) {
          if (!wasReady) {
            // Native starts with audio notifications disabled on every link.
            _nativeSubscription = null;
            _wantsAudio = false;
            audioFailed = false;
          }
          _capture.handle(Cv1LinkReady(_generation, event.codec!));
        } else {
          _nativeSubscription = null;
          audioFailed = false;
          _capture.handle(Cv1LinkLost(_generation));
        }
        _demandChanged();
        notifyListeners();
      case Cv1RawAudio():
        if (phase == Cv1LinkPhase.ready &&
            event.generation == _generation &&
            event.subscription == _desiredSubscription) {
          _capture.handle(Cv1Audio(event.generation, event.bytes));
        }
      case Cv1RawButton():
        if (phase == Cv1LinkPhase.ready && event.generation == _generation) {
          _capture.handle(Cv1Button(event.generation, event.code));
        }
    }
  }

  int? get _desiredSubscription => _wantsAudio ? _subscriptionSerial : null;

  void _demandChanged() {
    if (_closing) return;
    final wants = phase == Cv1LinkPhase.ready && _capture.wantsAudio;
    if (wants != _wantsAudio) {
      _wantsAudio = wants;
      if (wants) _subscriptionSerial++;
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
    _capture.removeListener(_demandChanged);
    try {
      await _subscription.cancel();
    } finally {
      try {
        await _transport.close();
      } on MissingPluginException {
        // There are no callbacks to stop on a build without the channel.
      }
    }
  }
}
