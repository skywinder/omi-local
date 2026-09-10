import 'package:flutter_test/flutter_test.dart';
import 'package:omi/models/stt_provider.dart';

void main() {
  test('provider labels preserve actual local and external engines', () {
    expect(SttProviderConfig.getDisplayName('WhisperLiveKit'), 'WhisperLiveKit');
    expect(SttProviderConfig.getDisplayName('whisperkit'), 'whisperkit');
    expect(SttProviderConfig.getDisplayName('deepgram'), 'Deepgram');
    expect(SttProviderConfig.getDisplayName(null), 'Unknown');
  });
}
