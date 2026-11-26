import 'package:flutter_test/flutter_test.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/structured.dart';
import 'package:omi/backend/schema/transcript_segment.dart';

TranscriptSegment _segment({required double start, required double end}) {
  return TranscriptSegment(
    id: 'seg',
    text: 'hello',
    speaker: 'SPEAKER_0',
    isUser: true,
    personId: null,
    start: start,
    end: end,
    translations: [],
  );
}

ServerConversation _conversation({
  List<TranscriptSegment> segments = const [],
  DateTime? startedAt,
  DateTime? finishedAt,
  Map<String, dynamic>? localTranscript,
}) {
  return ServerConversation(
    id: 'test-id',
    createdAt: DateTime.now(),
    structured: Structured('Test', 'Test'),
    transcriptSegments: segments,
    startedAt: startedAt,
    finishedAt: finishedAt,
    externalIntegration: localTranscript == null
        ? null
        : ConversationExternalData(text: '', localTranscript: localTranscript),
  );
}

void main() {
  group('ServerConversation.getDurationInSeconds()', () {
    test('local WAV duration survives the list preview and full transcript load', () {
      final start = DateTime.utc(2026, 11, 20, 16, 9);
      for (final preview in [true, false]) {
        final conversation = _conversation(
          startedAt: start,
          finishedAt: start.add(const Duration(minutes: 76, seconds: 45, milliseconds: 700)),
          segments: [_segment(start: 0, end: 14), if (!preview) _segment(start: 4580, end: 4590)],
          localTranscript: {'segment_storage': 'result-file', 'segment_preview': preview},
        );
        expect(conversation.getDurationInSeconds(), 4606);
      }
    });

    test('a local import without a valid recording interval uses the available transcript', () {
      final start = DateTime.utc(2026, 11, 20);
      for (final end in [null, start.subtract(const Duration(seconds: 1))]) {
        expect(
          _conversation(
            startedAt: start,
            finishedAt: end,
            segments: [_segment(start: 0, end: 14)],
            localTranscript: {'version': 1},
          ).getDurationInSeconds(),
          14,
        );
      }
    });

    test('uses transcript span when segments exist, not the inflated session timestamp delta', () {
      // started_at is the streaming-session origin: finishedAt - startedAt is 600s,
      // but only 12s of speech was transcribed. Duration should reflect the speech.
      final conv = _conversation(
        segments: [_segment(start: 0, end: 12)],
        startedAt: DateTime.utc(2026, 1, 1, 12, 0, 0),
        finishedAt: DateTime.utc(2026, 1, 1, 12, 10, 0),
      );
      expect(conv.getDurationInSeconds(), 12);
    });

    test('uses the last segment end across multiple segments', () {
      final conv = _conversation(
        segments: [_segment(start: 0, end: 8), _segment(start: 8, end: 27)],
        startedAt: DateTime.utc(2026, 1, 1, 12, 0, 0),
        finishedAt: DateTime.utc(2026, 1, 1, 12, 30, 0),
      );
      expect(conv.getDurationInSeconds(), 27);
    });

    test('falls back to finishedAt - startedAt when there are no segments', () {
      final conv = _conversation(
        startedAt: DateTime.utc(2026, 1, 1, 12, 0, 0),
        finishedAt: DateTime.utc(2026, 1, 1, 12, 0, 45),
      );
      expect(conv.getDurationInSeconds(), 45);
    });

    test('returns 0 when there are neither segments nor timestamps', () {
      expect(_conversation().getDurationInSeconds(), 0);
    });

    // Regression: behavior for these paths is unchanged by the fix.
    test('with segments but no timestamps, still returns the transcript span', () {
      final conv = _conversation(segments: [_segment(start: 0, end: 15)]);
      expect(conv.getDurationInSeconds(), 15);
    });

    test('with no segments and only one timestamp set, returns 0', () {
      final conv = _conversation(startedAt: DateTime.utc(2026, 1, 1, 12, 0, 0));
      expect(conv.getDurationInSeconds(), 0);
    });
  });
}
