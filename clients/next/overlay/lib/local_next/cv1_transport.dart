import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:omi/services/devices/ring_protocol.dart';
import 'package:permission_handler/permission_handler.dart';

import 'cv1_capture.dart';
import 'cv1_resume.dart';
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

typedef Cv1StorageStatus = ({int unreadBytes, int freeBytes, bool clockValid});

enum Cv1StorageProtocol { legacy, receiverAcknowledgement, unconfirmed }

typedef Cv1StorageInfo = ({int oldest, int unreadPackets, int overwrittenPackets, Cv1StorageProtocol protocol});

extension Cv1StorageCapacity on Cv1StorageStatus {
  bool get almostFull => freeBytes * 100 <= unreadBytes + freeBytes;
}

class Cv1Diagnostics {
  const Cv1Diagnostics({
    this.name,
    this.firmware,
    this.hardware,
    this.model,
    this.manufacturer,
    this.battery,
    this.storage,
    this.storageInfo,
    this.ringId,
    this.rssi,
    this.led,
    this.gain,
    this.charging,
    this.ledWritable = false,
    this.gainWritable = false,
  });

  final String? name, firmware, hardware, model, manufacturer;
  final int? battery, rssi, led, gain;
  final Cv1StorageStatus? storage;
  final Cv1StorageInfo? storageInfo;
  final int? ringId;
  final bool? charging;
  final bool ledWritable, gainWritable;

  // The CV1 SD ring reports four LE words. Earlier file-list firmware uses
  // different units. An uninitialized card has no usable capacity.
  static Cv1StorageStatus? _storageStatus(Object? raw) {
    if (raw is! Uint8List || raw.length != 16) return null;
    final data = ByteData.sublistView(raw);
    final used = data.getUint32(0, Endian.little);
    final packets = data.getUint32(4, Endian.little);
    final free = data.getUint32(8, Endian.little);
    final clockValid = data.getUint32(12, Endian.little);
    const packetBytes = RingProtocol.recordSize;
    if (used != packets * packetBytes || free % packetBytes != 0 || used + free == 0 || clockValid > 1) return null;
    return (unreadBytes: used, freeBytes: free, clockValid: clockValid == 1);
  }

  // INFO is big-endian, unlike the status characteristic. The 31-byte legacy
  // reply has no custody contract. A partial extension cannot establish one.
  static Cv1StorageInfo? _storageInfo(Object? raw) {
    if (raw is! Uint8List || (raw.length != 31 && raw.length != 41)) return null;
    final info = RingProtocol.parseInfoNotification(raw);
    if (info == null ||
        info.packetSize != RingProtocol.recordSize ||
        info.readSeq < 0 ||
        info.writeSeq < info.readSeq ||
        info.capacityPackets == 0 ||
        info.unreadPackets > info.capacityPackets ||
        info.droppedPackets < 0) {
      return null;
    }
    var protocol = Cv1StorageProtocol.legacy;
    if (info.infoBytes == 41) {
      final supported = info.capAppAckReclaim && info.capAdvanceIdempotent && info.capRingId;
      protocol = supported ? Cv1StorageProtocol.receiverAcknowledgement : Cv1StorageProtocol.unconfirmed;
    }
    return (
      oldest: info.readSeq,
      unreadPackets: info.unreadPackets,
      overwrittenPackets: info.droppedPackets,
      protocol: protocol,
    );
  }

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
      storage: _storageStatus(values['storageStatus']),
      storageInfo: _storageInfo(values['storageInfo']),
      ringId: values['storageInfo'] is Uint8List
          ? RingProtocol.parseInfoNotification(values['storageInfo'])?.ringId
          : null,
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

typedef Cv1StorageTarget = ({int generation, String deviceId});

enum Cv1ClearResult { empty, unavailable, unconfirmed }

typedef Cv1ArchiveBatch = ({Uint8List bytes, int start, bool complete});

abstract interface class Cv1ArchiveTransport {
  Future<void> setArchiveAwake(bool enabled);
  Future<Cv1ArchiveBatch> readOldest(Cv1StorageTarget target, int expectedStart, int maxRecords, {int? ringId});
}

abstract interface class Cv1MuteTransport {
  Future<bool?> captureMute(int generation, bool? value);
}

abstract interface class Cv1AcknowledgedArchiveTransport {
  Future<bool> advanceArchive(Cv1StorageTarget target, int end);
}

abstract interface class Cv1StorageTransport {
  Future<bool> clearStorage(Cv1StorageTarget target);
}

abstract interface class Cv1DiagnosticsTransport {
  Future<void> sampleDiagnostics();
  Future<void> sampleSignal();
  Future<void> writeSetting(int generation, String field, int value);
}

class Cv1PermissionDenied implements Exception {}

class ChannelCv1Transport
    implements
        Cv1Transport,
        Cv1DiagnosticsTransport,
        Cv1StorageTransport,
        Cv1ArchiveTransport,
        Cv1AcknowledgedArchiveTransport,
        Cv1MuteTransport {
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

  Future<void> setCaptureActive(bool active) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    const channel = MethodChannel('org.omilocal.next/capture');
    await channel.invokeMethod<void>(active ? 'startCv1' : 'stopCv1');
  }

  @override
  Future<void> setArchiveAwake(bool enabled) => _methods.invokeMethod<void>('setArchiveAwake', {'enabled': enabled});

  @override
  Future<Cv1ArchiveBatch> readOldest(Cv1StorageTarget target, int expectedStart, int maxRecords, {int? ringId}) async {
    final reply = await _methods.invokeMapMethod<String, dynamic>('readOldest', {
      'expectedStart': expectedStart,
      if (ringId != null) 'ringId': ringId,
      'maxRecords': maxRecords,
      'generation': target.generation,
      'deviceId': target.deviceId,
    });
    if (reply?['bytes'] is! Uint8List || reply?['start'] is! int || reply?['complete'] is! bool) {
      throw const FormatException('Invalid CV1 transfer reply');
    }
    return (bytes: reply!['bytes'] as Uint8List, start: reply['start'] as int, complete: reply['complete'] as bool);
  }

  @override
  Future<bool?> captureMute(int generation, bool? value) =>
      _methods.invokeMethod<bool>('captureMute', {'generation': generation, 'muted': value});

  @override
  Future<bool> advanceArchive(Cv1StorageTarget target, int end) async =>
      await _methods.invokeMethod<bool>('advanceArchive', {
        'generation': target.generation,
        'deviceId': target.deviceId,
        'end': end,
      }) ==
      true;

  @override
  Future<bool> clearStorage(Cv1StorageTarget target) async =>
      await _methods.invokeMethod<bool>('clearStorage', {
        'generation': target.generation,
        'deviceId': target.deviceId,
      }) ==
      true;

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
  Cv1Connection(this._transport, this._capture, {Cv1History? history, this.makeAudioRetry = Timer.new})
    : history = history ?? Cv1History() {
    if (_transport is Cv1MuteTransport) _capture.requestHardwareMute = _requestMute;
    _capture.addListener(_demandChanged);
    _subscription = _transport.events.listen(_onEvent, onError: (Object _) => _linkEnded(), onDone: _linkEnded);
  }

  Future<void> Function()? prepareArchive;
  int? _preparing;
  bool get preparingLink => _preparing != null;
  Future<void> _muteWrites = Future.value();
  int _muteRevision = 0;

  void _requestMute(bool value) {
    final rev = ++_muteRevision;
    final gen = _generation;
    _capture.hardwareMuteConfirmed = false;
    if (phase != Cv1LinkPhase.ready) return;
    _muteWrites = _muteWrites.then((_) async {
      if (_closing || gen != _generation || rev != _muteRevision) return;
      bool confirmed = false;
      try {
        confirmed =
            await (_transport as Cv1MuteTransport).captureMute(gen, value).timeout(const Duration(seconds: 5)) == value;
      } catch (_) {
        /* Keep the device status unconfirmed. */
      }
      if (!_closing && gen == _generation && rev == _muteRevision) {
        _capture.hardwareMuteConfirmed = confirmed;
        notifyListeners();
      }
    });
  }

  Future<void> _prepareLink(int gen, int format) async {
    _preparing = gen;
    final rev = _muteRevision;
    bool current() => !_closing && gen == _generation && phase == Cv1LinkPhase.ready;
    try {
      if (_transport case final Cv1MuteTransport mute) {
        final mode = _capture.resumeSettings?.mode;
        final stopped = mode == Cv1ResumeMode.stopped || mode == Cv1ResumeMode.muted;
        final state = await mute.captureMute(gen, stopped ? true : null).timeout(const Duration(seconds: 5));
        if (!current()) return;
        if (rev == _muteRevision) {
          if (stopped) _capture.hardwareMuteConfirmed = state == true;
          if (!stopped && state == true) _capture.restoreHardwareMute();
        }
      }
      if (current() && _capture.resumeSettings?.mode == Cv1ResumeMode.armed) {
        await prepareArchive?.call();
      }
    } catch (_) {
      if (current()) {
        _capture.hardwareMuteConfirmed = false;
        // A read error cannot establish that this device permits unattended capture.
        if (_capture.resumeSettings?.mode == Cv1ResumeMode.armed) _capture.suspendForUnconfirmedMute();
      }
    } finally {
      if (current()) {
        _preparing = null;
        _capture.handle(Cv1LinkReady(gen, format));
        _demandChanged();
        notifyListeners();
      }
    }
  }

  final Cv1Transport _transport;
  final Timer Function(Duration, void Function()) makeAudioRetry;
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
  bool _captureServiceRequested = false;
  Future<void> _serviceUpdate = Future.value();
  Timer? _audioRetry;
  int _audioBytesReceived = 0;

  /// Raw audio notification bytes for the current subscription, including the CV1 header.
  ({int subscription, int bytes})? get audioTraffic =>
      !_wantsAudio || calibrating ? null : (subscription: _subscriptionSerial, bytes: _audioBytesReceived);

  ValueChanged<Uint8List>? _calibration;
  bool get calibrating => _calibration != null;

  List<Cv1DeviceFound> get devices => List.unmodifiable(_devices.values);

  bool beginCalibration(ValueChanged<Uint8List> accept) {
    if (_closing ||
        importingStorage ||
        clearingStorage ||
        phase != Cv1LinkPhase.ready ||
        _capture.active ||
        _capture.sealing ||
        calibrating) {
      return false;
    }
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

  Future<void> scan() => _command(() async {
    if (importingStorage) return;
    _cancelPairRetry();
    _devices.clear();
    await _transport.scan();
  });

  Future<void> connect(String id) => _command(() async {
    if (importingStorage) return;
    _cancelPairRetry();
    _firstPairAttempt = id;
    if (_selected != id) {
      _selected = id;
      _wasConnected = false;
      reconnections = 0;
      _lostAt = null;
    }
    await _transport.connect(id);
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

  bool clearingStorage = false;
  bool importingStorage = false;

  Cv1StorageTarget? get importTarget =>
      _transport is Cv1ArchiveTransport &&
          !clearingStorage &&
          !importingStorage &&
          (diagnostics?.storageInfo?.protocol == Cv1StorageProtocol.legacy ||
              (diagnostics?.storageInfo?.protocol == Cv1StorageProtocol.receiverAcknowledgement &&
                  _transport is Cv1AcknowledgedArchiveTransport))
      ? storageTarget
      : null;

  /// The full import owns the selected reader across Bluetooth generations.
  /// The initial end and the last position saved on the phone bound every read.
  Future<void> readArchive(
    Cv1StorageTarget target, {
    required int? windows,
    required bool Function() shouldStop,
    required Future<void> Function(Cv1ArchiveBatch) persist,
    void Function(int first, int end)? onRange,
    void Function()? beforeRead,
    Future<void> Function()? onReconnectWait,
    void Function(int missingRecords)? onReconnect,
  }) async {
    final transport = _transport;
    if (transport is! Cv1ArchiveTransport ||
        target != importTarget ||
        (windows != null && (windows < 1 || windows > 32))) {
      throw PlatformException(code: 'storage_busy');
    }
    final reader = transport as Cv1ArchiveTransport;
    final originalCodec = codec;
    final ringId = diagnostics!.ringId;
    final protocol = diagnostics!.storageInfo!.protocol;
    var activeTarget = target;
    var next = diagnostics!.storageInfo!.oldest;
    final availableThrough = next + diagnostics!.storageInfo!.unreadPackets;
    int? previousStart;
    var completeWindows = 0;
    importingStorage = true;
    notifyListeners();
    try {
      onRange?.call(next, windows == null ? availableThrough : (next + windows * 32).clamp(next, availableThrough));
      if (windows == null) await reader.setArchiveAwake(true);
      while ((windows == null || completeWindows < windows) && next < availableThrough && !shouldStop()) {
        Cv1ArchiveBatch? batch;
        try {
          batch = await _readArchiveWindow(
            reader,
            activeTarget,
            next,
            availableThrough,
            previousStart,
            ringId,
            shouldStop,
            beforeRead,
          );
          if (batch == null) return;
        } on PlatformException catch (error) {
          if (windows != null || error.code != 'link_changed') rethrow;
        }
        if (batch != null) {
          await persist(batch);
          final end = batch.start + batch.bytes.length ~/ RingProtocol.recordSize;
          if (end > next) next = end;
          if (batch.complete && batch.bytes.isNotEmpty) {
            if (protocol == Cv1StorageProtocol.receiverAcknowledgement &&
                !await (transport as Cv1AcknowledgedArchiveTransport).advanceArchive(activeTarget, end)) {
              throw PlatformException(code: 'cursor_changed');
            }
            previousStart = batch.start;
            completeWindows++;
            if (next < availableThrough && (windows == null || completeWindows < windows) && !shouldStop()) {
              await sampleDiagnostics();
            }
            continue;
          }
          if (windows != null) return;
        }
        if (shouldStop()) return;
        // A short native reply can arrive just before the link-loss event. Flush
        // its complete records before waiting for a new generation.
        if (next >= availableThrough) return;
        await onReconnectWait?.call();
        final resumed = await _waitForArchiveLink(activeTarget, originalCodec, protocol, ringId, shouldStop);
        if (resumed == null) return;
        final info = diagnostics!.storageInfo!;
        if (info.oldest + info.unreadPackets < availableThrough || info.oldest < next - 32) {
          throw PlatformException(code: 'cursor_changed');
        }
        final resumeAt = info.oldest.clamp(next, availableThrough);
        onReconnect?.call(resumeAt - next);
        next = resumeAt;
        activeTarget = resumed;
        previousStart = null;
      }
    } finally {
      try {
        if (windows == null) await reader.setArchiveAwake(false);
      } finally {
        importingStorage = false;
        if (!_closing) {
          notifyListeners();
          unawaited(sampleDiagnostics());
        }
      }
    }
  }

  Future<Cv1ArchiveBatch?> _readArchiveWindow(
    Cv1ArchiveTransport reader,
    Cv1StorageTarget target,
    int next,
    int end,
    int? previousStart,
    int? ringId,
    bool Function() shouldStop,
    void Function()? beforeRead,
  ) async {
    final wait = Stopwatch()..start();
    var refreshAt = 1000;
    while (!shouldStop()) {
      if (_closing ||
          phase != Cv1LinkPhase.ready ||
          _generation != target.generation ||
          linkedDeviceId != target.deviceId) {
        throw PlatformException(code: 'link_changed');
      }
      final info = diagnostics?.storageInfo;
      if (info != null &&
          (diagnostics!.ringId != ringId || info.oldest > next || info.protocol == Cv1StorageProtocol.unconfirmed)) {
        throw PlatformException(code: 'cursor_changed');
      }
      // Legacy DONE can arrive before the last BLE transmit callbacks advance
      // the cursor. Read only from the confirmed oldest sequence.
      if (info != null && (previousStart == null || info.oldest > previousStart)) {
        beforeRead?.call();
        try {
          return await reader.readOldest(target, info.oldest, (end - info.oldest).clamp(1, 32), ringId: ringId);
        } on PlatformException catch (error) {
          // Only storage_busy guarantees the native side never issued READ.
          if (error.code != 'storage_busy') rethrow;
        }
      }
      if (wait.elapsed >= const Duration(seconds: 6)) throw PlatformException(code: 'storage_busy');
      if (wait.elapsedMilliseconds >= refreshAt) {
        refreshAt += 1000;
        await sampleDiagnostics();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  Future<Cv1StorageTarget?> _waitForArchiveLink(
    Cv1StorageTarget previous,
    int? originalCodec,
    Cv1StorageProtocol protocol,
    int? ringId,
    bool Function() shouldStop,
  ) async {
    final wait = Stopwatch()..start();
    var refreshAt = 0;
    while (!_closing && !shouldStop()) {
      if (phase == Cv1LinkPhase.ready && _generation != previous.generation) {
        if (linkedDeviceId != previous.deviceId || codec != originalCodec) {
          throw PlatformException(code: 'cursor_changed');
        }
        if (diagnostics?.storageInfo case final info?) {
          if (info.protocol != protocol || diagnostics!.ringId != ringId) {
            throw PlatformException(code: 'cursor_changed');
          }
          return (generation: _generation, deviceId: previous.deviceId);
        }
        if (wait.elapsedMilliseconds >= refreshAt) {
          refreshAt = wait.elapsedMilliseconds + 1000;
          await sampleDiagnostics();
        }
      } else if (phase == Cv1LinkPhase.ready && wait.elapsed >= const Duration(seconds: 2)) {
        // An invalid reply on a healthy link should not loop as if it were a disconnect.
        throw PlatformException(code: 'link_changed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  Cv1StorageTarget? get storageTarget {
    final id = linkedDeviceId;
    if (_closing ||
        phase != Cv1LinkPhase.ready ||
        id == null ||
        calibrating ||
        (_capture.active && !preparingLink) ||
        _capture.sealing ||
        diagnostics?.storageInfo == null ||
        diagnostics?.storageInfo?.protocol == Cv1StorageProtocol.unconfirmed ||
        (diagnostics?.storage?.unreadBytes ?? 0) == 0) {
      return null;
    }
    return (generation: _generation, deviceId: id);
  }

  Future<Cv1ClearResult> clearStorage(Cv1StorageTarget target) async {
    final transport = _transport;
    if (importingStorage || clearingStorage || storageTarget != target || transport is! Cv1StorageTransport) {
      return Cv1ClearResult.unavailable;
    }
    clearingStorage = true;
    notifyListeners();
    final empty = Completer<bool>();
    void observe() {
      if (empty.isCompleted) return;
      if (_closing || target.generation != _generation || linkedDeviceId != target.deviceId) {
        empty.complete(false);
      } else if (diagnostics?.storage?.unreadBytes == 0 && diagnostics?.storageInfo?.unreadPackets == 0) {
        empty.complete(true);
      }
    }

    try {
      final acknowledged = await (transport as Cv1StorageTransport).clearStorage(target);
      if (_closing || target.generation != _generation || linkedDeviceId != target.deviceId) {
        return Cv1ClearResult.unconfirmed;
      }
      addListener(observe);
      await sampleDiagnostics();
      if (acknowledged && await empty.future.timeout(const Duration(seconds: 6), onTimeout: () => false)) {
        return Cv1ClearResult.empty;
      }
      return Cv1ClearResult.unconfirmed;
    } on PlatformException catch (error) {
      return error.code == 'storage_busy' ? Cv1ClearResult.unavailable : Cv1ClearResult.unconfirmed;
    } catch (_) {
      return Cv1ClearResult.unconfirmed;
    } finally {
      removeListener(observe);
      clearingStorage = false;
      if (!_closing) notifyListeners();
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
    if (importingStorage) return Future.value();
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
          if (!wasReady && (prepareArchive != null || _transport is Cv1MuteTransport)) {
            unawaited(_prepareLink(_generation, event.codec!));
          } else if (_preparing == null) {
            _capture.handle(Cv1LinkReady(_generation, event.codec!));
          }
          if (!wasReady) unawaited(sampleDiagnostics());
        } else {
          connectedAt = null;
          batteryMeasuredAt = null;
          signalMeasuredAt = null;
          codec = null;
          diagnostics = null;
          _nativeSubscription = null;
          audioFailed = false;
          _preparing = null;
          if (_capture.hardwareMuteConfirmed != null) _capture.hardwareMuteConfirmed = false;
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
            _audioBytesReceived += event.bytes.length;
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

  void _updateCaptureService(bool active) {
    final transport = _transport;
    if (transport is! ChannelCv1Transport || _captureServiceRequested == active) return;
    _captureServiceRequested = active;
    _serviceUpdate = _serviceUpdate.then((_) async {
      try {
        await transport.setCaptureActive(active);
      } catch (_) {
        // An Android background start can be rejected until the app is visible.
        if (_captureServiceRequested == active) _captureServiceRequested = !active;
      }
    });
  }

  void recoverDemand() => _demandChanged();

  void _demandChanged() {
    if (_closing) return;
    _updateCaptureService(_capture.intent == Cv1CaptureIntent.recording);
    final wants = !preparingLink && phase == Cv1LinkPhase.ready && (_capture.wantsAudio || calibrating);
    if (!wants) {
      _audioRetry?.cancel();
      _audioRetry = null;
    }
    if (wants != _wantsAudio) {
      _wantsAudio = wants;
      if (wants) {
        _subscriptionSerial++;
        _audioBytesReceived = 0;
        audioFailed = false;
      }
    }
    if (!_updatingAudio &&
        _audioRetry == null &&
        phase == Cv1LinkPhase.ready &&
        _nativeSubscription != _desiredSubscription) {
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
        if (failed && enabled && generation == _generation && _desiredSubscription == subscription && !_closing) {
          // Retire the failed token before enabling a fresh subscription. The
          // native transport can have accepted the token before its BLE write failed.
          _audioRetry = makeAudioRetry(const Duration(seconds: 4), () {
            _audioRetry = null;
            if (generation == _generation && _desiredSubscription == subscription) _subscriptionSerial++;
            _demandChanged();
          });
          break;
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
    _audioRetry?.cancel();
    _updateCaptureService(false);
    await _serviceUpdate;
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
