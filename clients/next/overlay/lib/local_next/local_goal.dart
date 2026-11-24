import 'package:omi/backend/schema/gen/goals_wire.g.dart';
import 'package:omi/backend/schema/gen/task_intelligence_wire.g.dart' show GeneratedGoalProgressEvent;

enum LocalGoalFailure implements Exception { conflict, invalid, unavailable }

class LocalGoalDetail {
  const LocalGoalDetail({
    required this.goal,
    required this.revision,
    required this.events,
    required this.legacyHistory,
  });

  factory LocalGoalDetail.fromJson(Map<String, dynamic> json) => LocalGoalDetail(
    goal: GeneratedGoalResponse.fromJson(json['goal'] as Map<String, dynamic>),
    revision: json['revision'] as String,
    events: (json['events'] as List).cast<Map<String, dynamic>>().map(GeneratedGoalProgressEvent.fromJson).toList(),
    legacyHistory: (json['legacy_history'] as List)
        .cast<Map<String, dynamic>>()
        .map(GeneratedGoalHistoryEntryResponse.fromJson)
        .toList(),
  );

  final GeneratedGoalResponse goal;
  final String revision;
  final List<GeneratedGoalProgressEvent> events;
  final List<GeneratedGoalHistoryEntryResponse> legacyHistory;

  bool get acceptsProgress => goal.status == 'background' || goal.status == 'focused';
}
