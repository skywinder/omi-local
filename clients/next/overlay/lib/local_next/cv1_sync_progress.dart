import 'package:omi/services/devices/ring_protocol.dart';

/// Estimates the time to reach the selected archive boundary from the rate of
/// newly saved records. A replay or missing range can never inflate that rate.
class Cv1SyncProgress {
  Cv1SyncProgress({required int start, required this.end, required Duration elapsed})
    : _cursor = start,
      _lastAdvance = elapsed;

  final int end;
  int _cursor;
  Duration _lastAdvance;
  double? _bytesPerSecond;
  static const staleAfter = Duration(seconds: 12);

  int get remainingRecords => end - _cursor;

  void resume(int missingRecords, Duration elapsed) {
    _cursor = (_cursor + missingRecords).clamp(_cursor, end);
    _lastAdvance = elapsed;
    _bytesPerSecond = null;
  }

  void savedThrough(int sequence, Duration elapsed) {
    final cursor = sequence.clamp(_cursor, end);
    if (cursor == _cursor) return;
    final micros = (elapsed - _lastAdvance).inMicroseconds;
    final bytes = (cursor - _cursor) * RingProtocol.recordSize;
    _cursor = cursor;
    if (micros <= 0) return;
    final rate = bytes * Duration.microsecondsPerSecond / micros;
    final previous = _bytesPerSecond;
    _bytesPerSecond = previous == null ? rate : previous * .75 + rate * .25;
    _lastAdvance = elapsed;
  }

  ({double bytesPerSecond, Duration remaining})? estimate(Duration elapsed) {
    final rate = _bytesPerSecond;
    if (remainingRecords == 0 || rate == null || elapsed - _lastAdvance >= staleAfter) return null;
    return (
      bytesPerSecond: rate,
      remaining: Duration(seconds: (remainingRecords * RingProtocol.recordSize / rate).ceil()),
    );
  }
}
