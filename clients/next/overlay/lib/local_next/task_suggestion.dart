class TaskSuggestion {
  const TaskSuggestion({
    required this.id,
    required this.description,
    required this.segmentId,
    required this.segmentSha256,
    required this.excerpt,
    required this.startMs,
  });

  factory TaskSuggestion.fromJson(Map<String, dynamic> json) => TaskSuggestion(
    id: json['id'] as String,
    description: json['description'] as String,
    segmentId: json['segment_id'] as String,
    segmentSha256: json['segment_sha256'] as String,
    excerpt: json['excerpt'] as String,
    startMs: json['start_ms'] as int?,
  );

  final String id, description, segmentId, segmentSha256, excerpt;
  final int? startMs;
}

class TaskSuggestions {
  const TaskSuggestions({required this.rows, required this.contextLimited});

  factory TaskSuggestions.fromJson(Map<String, dynamic> json) => TaskSuggestions(
    rows: (json['suggestions'] as List).cast<Map<String, dynamic>>().map(TaskSuggestion.fromJson).toList(),
    contextLimited: json['context_limited'] as bool,
  );

  final List<TaskSuggestion> rows;
  final bool contextLimited;
}
