/// Phone-side capture evidence, not a claim that the Mac saved or transcribed it.
enum LocalCapturePhase { idle, starting, waitingAudio, recording, paused, stopping, failed }

/// Values emitted by the Omi button BLE characteristic. Firmware may omit edges.
enum OmiButtonEvent {
  singleTap(1),
  doubleTap(2),
  longPress(3),
  pressed(4),
  released(5);

  const OmiButtonEvent(this.code);
  final int code;

  static OmiButtonEvent? fromCode(int code) {
    for (final event in values) {
      if (event.code == code) return event;
    }
    return null;
  }
}
