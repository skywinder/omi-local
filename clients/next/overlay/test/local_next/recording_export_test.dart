import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/local_next/recording_export.dart';

void main() {
  test('TXT uses the full detail transcript, including overlapping turns', () {
    final row = ServerConversation.fromJson({
      'id': 'fixture',
      'created_at': '2026-11-25T15:00:00Z',
      'started_at': null,
      'finished_at': null,
      'structured': {'title': 'Conversation', 'overview': 'Recap', 'emoji': '🎙️'},
      'transcript_segments': [
        {'id': 'a', 'text': 'First turn', 'is_user': false, 'speaker': 'SPEAKER_00', 'start': 1.0, 'end': 3.0},
        {'id': 'b', 'text': 'Overlapping turn', 'is_user': false, 'speaker': 'SPEAKER_01', 'start': 2.0, 'end': 5.0},
      ],
    });
    final text = localConversationText(row, summaryLabel: 'Summary', transcriptLabel: 'Transcript');
    expect(text, startsWith('Conversation'));
    expect(text, contains('Recap'));
    expect(text, contains('] First turn'));
    expect(text, contains('] Overlapping turn'));
  });
}
