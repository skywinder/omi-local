import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/backend/schema/transcript_segment.dart';

void main() {
  Map<String, dynamic> row({String? speaker, int? speakerId}) => {
        'id': 'synthetic-segment',
        'text': 'Example speech',
        'start': 1.25,
        'end': 2.75,
        'is_user': false,
        'speaker': speaker,
        if (speakerId != null) 'speaker_id': speakerId,
      };

  test('explicit unknown speakers survive wire decoding and round-trip serialization', () {
    for (final json in [row(), row(speakerId: -1), row(speaker: 'SPEAKER_00', speakerId: -1)]) {
      final segment = TranscriptSegment.fromJson(json);
      expect(segment.speaker, isNull);
      expect(segment.speakerId, -1);
      final roundTrip = TranscriptSegment.fromJson(segment.toJson());
      expect(roundTrip.speaker, isNull);
      expect(roundTrip.speakerId, -1);
      expect(roundTrip.start, 1.25);
      expect(roundTrip.end, 2.75);
    }
  });

  test('unknown rows do not shift known speaker numbers and legacy default remains supported', () {
    final unknown = TranscriptSegment.fromJson(row());
    final first = TranscriptSegment.fromJson(row(speaker: 'SPEAKER_00'));
    final second = TranscriptSegment.fromJson(row(speaker: 'SPEAKER_01'));
    final segments = [unknown, first, second];
    expect(TranscriptSegment.getDisplaySpeakerId(first.speakerId, segments), 1);
    expect(TranscriptSegment.getDisplaySpeakerId(second.speakerId, segments), 2);
    expect(TranscriptSegment.getDisplaySpeakerId(unknown.speakerId, segments), -1);
    final legacy = row()..remove('speaker');
    expect(TranscriptSegment.fromJson(legacy).speakerId, 0);
  });

  test('snapshot parser keeps draft metadata transient and rejects invalid revisions', () {
    final envelope = {
      'type': 'local_transcript_snapshot',
      'preview_id': 'local-preview-synthetic',
      'revision': 1,
      'segments': [
        {...row(), 'is_draft': true}
      ],
    };
    final snapshot = MessageEvent.fromJson(envelope) as LocalTranscriptSnapshotEvent;
    expect(snapshot.segments.single.isDraft, isTrue);
    expect(snapshot.segments.single.toJson().containsKey('is_draft'), isFalse);
    expect(() => MessageEvent.fromJson({...envelope, 'revision': 0}), throwsFormatException);
    expect(() => MessageEvent.fromJson({...envelope, 'segments': null}), throwsFormatException);
    expect(() => MessageEvent.fromJson({...envelope, 'preview_id': 'unscoped'}), throwsFormatException);
  });
}
