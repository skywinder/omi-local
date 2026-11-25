import 'recording_chat.dart';

enum RecordingSummaryFailure implements Exception { conflict, tooLarge, noTranscript, unavailable }

typedef SummaryProvider = ({String name, RecordingChatProvider endpoint});
typedef SummaryTemplate = ({String id, String name, String prompt, String digest});

class RecordingSummaryOptions {
  const RecordingSummaryOptions({
    required this.sourceRevision,
    required this.providers,
    required this.templates,
    required this.defaultBinding,
    required this.defaultTemplate,
  });

  factory RecordingSummaryOptions.fromJson(Map<String, dynamic> json) => RecordingSummaryOptions(
    sourceRevision: json['source_revision'] as String,
    providers: (json['providers'] as List)
        .cast<Map<String, dynamic>>()
        .map((row) => (name: row['name'] as String, endpoint: RecordingChatProvider.fromJson(row)))
        .toList(),
    templates: (json['templates'] as List).cast<Map<String, dynamic>>().map((row) {
      return (
        id: row['id'] as String,
        name: row['name'] as String,
        prompt: row['prompt'] as String,
        digest: row['digest'] as String,
      );
    }).toList(),
    defaultBinding: json['default_provider_binding'] as String?,
    defaultTemplate: json['default_template_id'] as String,
  );

  final String sourceRevision;
  final List<SummaryProvider> providers;
  final List<SummaryTemplate> templates;
  final String? defaultBinding;
  final String defaultTemplate;
}

typedef SummaryRegeneration = ({
  String requestId,
  String sourceRevision,
  String binding,
  String templateId,
  String templateDigest,
  String prompt,
});
