import 'dart:typed_data';

/// Reassembles raw, ordered CV1 audio notifications from one subscription.
///
/// Firmware push_to_gatt puts a little-endian 16-bit counter and an 8-bit
/// fragment index before each payload. The counter advances per notification.
/// Fragment zero starts a new Opus packet. There is no end marker or length.
class Cv1OpusFrameAssembler {
  // The pinned CV1 firmware bounds its encoder and TX queue by this value
  // (omi/firmware/omi/src/lib/core/config.h, CODEC_OUTPUT_MAX_BYTES).
  static const _maxFrameBytes = 160;
  static const _headerBytes = 3;

  final _payload = BytesBuilder();
  int? _expectedCounter;
  int _expectedFragment = 0;
  int _discardedCandidates = 0;

  /// Counts buffered packets discarded before their end could be confirmed.
  int get discardedCandidates => _discardedCandidates;

  /// Returns the preceding, headerless packet once the next start proves its end.
  Uint8List? add(Uint8List notification) {
    final payloadLength = notification.length - _headerBytes;
    if (payloadLength <= 0 || payloadLength > _maxFrameBytes) {
      discardPending();
      return null;
    }

    final counter = notification[0] | (notification[1] << 8);
    final fragment = notification[2];
    if (counter != _expectedCounter || (fragment != 0 && fragment != _expectedFragment)) {
      discardPending();
    }

    Uint8List? complete;
    if (fragment == 0) {
      if (_payload.isNotEmpty) complete = _payload.takeBytes();
    } else if (_payload.isEmpty) {
      return null; // Joined mid-frame or lost a fragment. Wait for a start.
    }

    if (_payload.length + payloadLength > _maxFrameBytes) {
      discardPending();
      return complete;
    }
    _payload.add(Uint8List.sublistView(notification, _headerBytes));
    _expectedCounter = (counter + 1) & 0xffff;
    _expectedFragment = fragment + 1;
    return complete;
  }

  /// Ends continuity on stop, mute or disconnect. The return value counts
  /// buffered bytes with no confirmed end; none can be submitted to the decoder.
  int discardPending() {
    final count = _payload.length;
    if (count > 0) _discardedCandidates++;
    _payload.clear();
    _expectedCounter = null;
    _expectedFragment = 0;
    return count;
  }
}
