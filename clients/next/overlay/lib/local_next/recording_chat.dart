import 'package:omi/models/chat_evidence_reference.dart';

enum RecordingChatFailure implements Exception { changed, unavailable, noMatches, scanLimited }

class RecordingChatProvider {
  const RecordingChatProvider({required this.binding, required this.host, required this.model});

  factory RecordingChatProvider.fromJson(Map<String, dynamic> json) => RecordingChatProvider(
    binding: json['binding'] as String,
    host: json['host'] as String,
    model: json['model'] as String,
  );

  final String binding;
  final String host;
  final String model;
}

class RecordingChatTurn {
  const RecordingChatTurn({
    required this.id,
    required this.question,
    required this.answer,
    required this.references,
    required this.contextLimited,
    this.scanLimited = false,
    this.sourcesUnavailable = false,
  });

  factory RecordingChatTurn.fromJson(Map<String, dynamic> json, String? recordingId) => RecordingChatTurn(
    id: json['id'] as String,
    question: json['question'] as String,
    answer: json['answer'] as String,
    references: (json['evidence_references'] as List)
        .cast<Map<String, dynamic>>()
        .map(ChatEvidenceReference.fromJson)
        .where(
          (ref) =>
              ref.kind == ChatEvidenceReferenceKind.conversationSegment &&
              ref.state == ChatEvidenceReferenceState.available &&
              ref.conversationId != null &&
              (recordingId == null || ref.conversationId == recordingId),
        )
        .toList(),
    contextLimited: json['context_limited'] as bool,
    scanLimited: json['scan_limited'] == true,
    sourcesUnavailable: json['sources_unavailable'] == true,
  );

  final String id;
  final String question;
  final String answer;
  final List<ChatEvidenceReference> references;
  final bool contextLimited;
  final bool scanLimited;
  final bool sourcesUnavailable;
}

class RecordingChatPageData {
  const RecordingChatPageData({
    required this.turns,
    required this.nextBefore,
    required this.provider,
    required this.hasTranscript,
    this.storedHistory = false,
  });

  factory RecordingChatPageData.fromJson(Map<String, dynamic> json, String? recordingId) => RecordingChatPageData(
    turns: (json['turns'] as List)
        .cast<Map<String, dynamic>>()
        .map((turn) => RecordingChatTurn.fromJson(turn, recordingId))
        .toList(),
    nextBefore: json['next_before'] as int?,
    provider: json['provider'] == null
        ? null
        : RecordingChatProvider.fromJson(json['provider'] as Map<String, dynamic>),
    hasTranscript: json['has_transcript'] as bool,
    storedHistory: json['stored_history'] == true,
  );

  final List<RecordingChatTurn> turns;
  final int? nextBefore;
  final RecordingChatProvider? provider;
  final bool hasTranscript;
  final bool storedHistory;
}
