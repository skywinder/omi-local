import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum Cv1LinkPhase { idle, unavailable, scanning, connecting, ready, reconnecting, failed }

enum Cv1LinkReason { manual, radio, permission, timeout, incompatible, dropped, remote, connect, audio }

typedef Cv1Sample = ({DateTime at, int value, int series});
typedef Cv1Transition = ({
  DateTime at,
  Cv1LinkPhase phase,
  Cv1LinkReason? reason,
  int? code,
  int? battery,
  int? rssi,
  Duration? uptime,
  Duration? downtime,
});

/// History of CV1 links observed by this installation. Series are local chart
/// boundaries. Wearable names, Bluetooth identifiers and audio never enter it.
class Cv1History {
  Cv1History({SharedPreferences? preferences, DateTime Function()? now})
    : _preferences = preferences,
      now = now ?? DateTime.now {
    _restore();
  }

  static const storageKey = 'next.cv1.history.v1';
  static const retention = Duration(days: 7);
  static const _batteryLimit = 2200;
  static const _eventLimit = 300;
  static const _signalLimit = 240;

  final SharedPreferences? _preferences;
  final DateTime Function() now;
  final _battery = <Cv1Sample>[];
  final _signal = <Cv1Sample>[];
  final _events = <Cv1Transition>[];
  Timer? _saveTimer;
  Future<void> _saving = Future.value();
  var _series = 0;
  bool _dirty = false;

  List<Cv1Sample> get battery => List.unmodifiable(_battery);
  List<Cv1Sample> get signal => List.unmodifiable(_signal);
  List<Cv1Transition> get events => List.unmodifiable(_events);

  void beginLink() {
    final timestamp = now().millisecondsSinceEpoch;
    _series = timestamp > _series ? timestamp : _series + 1;
  }

  void measureBattery(int value) {
    final at = now();
    final last = _battery.lastOrNull;
    if (last != null &&
        last.series == _series &&
        last.value == value &&
        at.difference(last.at) < const Duration(minutes: 5)) {
      return;
    }
    _battery.add((at: at, value: value, series: _series));
    _trim(at);
    _changed();
  }

  void measureSignal(int value) {
    final at = now();
    _signal.add((at: at, value: value, series: _series));
    _signal.removeWhere((sample) => at.difference(sample.at) > const Duration(minutes: 10));
    if (_signal.length > _signalLimit) _signal.removeAt(0);
  }

  void addEvent(Cv1Transition event) {
    _events.add(event);
    _trim(event.at);
    _changed();
  }

  void _trim(DateTime at) {
    final cutoff = at.subtract(retention);
    _battery.removeWhere((sample) => sample.at.isBefore(cutoff));
    _events.removeWhere((event) => event.at.isBefore(cutoff));
    if (_battery.length > _batteryLimit) _battery.removeRange(0, _battery.length - _batteryLimit);
    if (_events.length > _eventLimit) _events.removeRange(0, _events.length - _eventLimit);
  }

  void _changed() {
    if (_preferences == null) return;
    _dirty = true;
    _saveTimer ??= Timer(const Duration(seconds: 5), () => unawaited(flush()));
  }

  Map<String, Object> _eventData(Cv1Transition event) => {
    'at': event.at.millisecondsSinceEpoch,
    'phase': event.phase.name,
    if (event.reason case final reason?) 'reason': reason.name,
    if (event.code case final code?) 'code': code,
    if (event.battery case final battery?) 'battery': battery,
    if (event.rssi case final rssi?) 'rssi': rssi,
    if (event.uptime case final uptime?) 'uptime_ms': uptime.inMilliseconds,
    if (event.downtime case final downtime?) 'downtime_ms': downtime.inMilliseconds,
  };

  Map<String, Object> _snapshot() {
    _trim(now());
    return {
      'battery': [
        for (final sample in _battery) [sample.at.millisecondsSinceEpoch, sample.value, sample.series],
      ],
      'events': _events.map(_eventData).toList(),
    };
  }

  String exportLog() {
    final report = _snapshot();
    report['signal'] = [
      for (final sample in _signal)
        if (now().difference(sample.at) <= const Duration(minutes: 10))
          [sample.at.millisecondsSinceEpoch, sample.value, sample.series],
    ];
    return const JsonEncoder.withIndent('  ').convert(report);
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final preferences = _preferences;
    if (preferences == null || !_dirty) return _saving;
    _dirty = false;
    final snapshot = jsonEncode(_snapshot());
    return _saving = _saving.then((_) async {
      try {
        await preferences.setString(storageKey, snapshot);
      } catch (_) {
        // A storage failure must not disrupt recording or discard in-memory observations.
        _dirty = true;
      }
    });
  }

  void _restore() {
    try {
      final encoded = _preferences?.getString(storageKey);
      if (encoded == null || encoded.length > 220000) return;
      final map = jsonDecode(encoded);
      if (map is! Map || map['battery'] is! List || map['events'] is! List) return;
      final at = now();
      final oldest = at.subtract(retention).millisecondsSinceEpoch;
      final latest = at.millisecondsSinceEpoch;
      for (final row in (map['battery'] as List).take(_batteryLimit)) {
        if (row case [
          final int time,
          final int value,
          final int series,
        ] when time >= oldest && time <= latest && value >= 0 && value <= 100 && series > 0 && series <= latest) {
          _battery.add((at: DateTime.fromMillisecondsSinceEpoch(time), value: value, series: series));
          if (series > _series) _series = series;
        }
      }
      for (final row in (map['events'] as List).take(_eventLimit)) {
        if (row is! Map || row['at'] is! int) continue;
        final time = row['at'] as int;
        final phase = Cv1LinkPhase.values.where((phase) => phase.name == row['phase']).firstOrNull;
        if (phase == null || time < oldest || time > latest) continue;
        int? integer(String name, int min, int max) {
          final value = row[name];
          return value is int && value >= min && value <= max ? value : null;
        }

        Duration? duration(String name) {
          final value = integer(name, 0, retention.inMilliseconds);
          return value == null ? null : Duration(milliseconds: value);
        }

        _events.add((
          at: DateTime.fromMillisecondsSinceEpoch(time),
          phase: phase,
          reason: Cv1LinkReason.values.where((reason) => reason.name == row['reason']).firstOrNull,
          code: integer('code', 0, 65535),
          battery: integer('battery', 0, 100),
          rssi: integer('rssi', -127, -1),
          uptime: duration('uptime_ms'),
          downtime: duration('downtime_ms'),
        ));
      }
      _battery.sort((a, b) => a.at.compareTo(b.at));
      _events.sort((a, b) => a.at.compareTo(b.at));
    } catch (_) {
      // A malformed local preference cannot block a new connection.
    }
  }
}
