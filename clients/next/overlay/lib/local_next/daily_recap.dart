import 'package:omi/backend/schema/daily_summary.dart';

import 'recording_chat.dart';

enum DailyRecapFailure implements Exception { changed, unavailable }

Map<String, String> dailyRecapDay(DateTime date) {
  final start = DateTime(date.year, date.month, date.day);
  final end = DateTime(date.year, date.month, date.day + 1);
  return {
    'day': start.toIso8601String().split('T').first,
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
  };
}

class LocalDailyRecap {
  const LocalDailyRecap({required this.summary, this.sourceIds = const [], this.limited = false});

  factory LocalDailyRecap.fromJson(Map<String, dynamic> json) {
    final summary = DailySummary.fromJson(json);
    if (summary.id.isEmpty || summary.date.isEmpty) throw const FormatException('Invalid recap');
    return LocalDailyRecap(
      summary: summary,
      sourceIds: (json['local_source_ids'] as List?)?.cast<String>() ?? const [],
      limited: json['local_coverage_limited'] == true,
    );
  }

  final DailySummary summary;
  final List<String> sourceIds;
  final bool limited;
}

class DailyRecapPreview {
  const DailyRecapPreview({
    required this.revision,
    required this.provider,
    required this.count,
    required this.sourceCount,
    required this.limited,
  });

  factory DailyRecapPreview.fromJson(Map<String, dynamic> json) => DailyRecapPreview(
    revision: json['revision'] as String,
    provider: json['provider'] == null
        ? null
        : RecordingChatProvider.fromJson(json['provider'] as Map<String, dynamic>),
    count: json['count'] as int,
    sourceCount: json['source_count'] as int,
    limited: json['limited'] as bool,
  );

  final String revision;
  final RecordingChatProvider? provider;
  final int count;
  final int sourceCount;
  final bool limited;
}
