class LocalTaskDue {
  const LocalTaskDue(this.wire);

  factory LocalTaskDue.day(String date, String timezone) =>
      LocalTaskDue({'kind': 'date', 'date': date, 'timezone': timezone});

  factory LocalTaskDue.time(DateTime instant, String timezone) =>
      LocalTaskDue({'kind': 'instant', 'instant': instant.toUtc().toIso8601String(), 'timezone': timezone});

  final Map<String, dynamic> wire;
  String get kind => wire['kind'] as String;
  DateTime? get date => kind == 'date' ? DateTime.tryParse(wire['date'] as String? ?? '') : null;
  DateTime? get instant => kind == 'instant' ? DateTime.tryParse(wire['instant'] as String? ?? '') : null;
  String? get timezone => wire['timezone'] as String?;

  static LocalTaskDue? fromTask(Map<String, dynamic> task) {
    if (task['due'] case final Map<String, dynamic> due when due['kind'] is String) {
      return LocalTaskDue(Map.unmodifiable(due));
    }
    if (task['due_at'] case final String legacy) {
      final instant = DateTime.tryParse(legacy);
      if (instant != null) return LocalTaskDue.time(instant, 'UTC');
    }
    return null;
  }
}

typedef LocalTaskReminder = ({String id, String description, DateTime at, bool exact});
