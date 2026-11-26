import 'recording_chat.dart';

enum LocalMemoryFailure implements Exception { changed, unavailable, invalid }

class LocalMemory {
  const LocalMemory(this.wire);
  final Map<String, dynamic> wire;
  String get id => wire['id'] as String;
  String get revision => wire['revision'] as String;
  String get content => wire['content'] as String;
  String get state => wire['state'] as String;
  String get sourceStatus => wire['source_status'] as String;
  bool get eligible => wire['eligible'] == true;
  String get conversationId => wire['conversation_id'] as String;
  String get segmentId => wire['segment_id'] as String;
  int? get startMs => wire['start_ms'] as int?;
  String? get quote => wire['quote'] as String?;
  List<Map<String, dynamic>> get revisions => (wire['revisions'] as List? ?? const []).cast<Map<String, dynamic>>();
}

typedef LocalMemoryPage = ({List<LocalMemory> items, String? next});

typedef LocalMemoryProvider = RecordingChatProvider;
