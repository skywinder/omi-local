import 'dart:convert';

import 'package:omi/backend/schema/conversation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only the first page of card metadata is retained, scoped to the URL and pairing key.
class NextArchiveCache {
  NextArchiveCache(String owner) : _key = 'next.archive.v1.$owner';
  final String _key;
  final audioFileIds = <String>{};

  Future<void> write(Iterable<ServerConversation> rows) async {
    final cards = <Map<String, dynamic>>[];
    for (final row in rows.take(30)) {
      final external = row.externalIntegration;
      final local = external?.localRecording ?? external?.localTranscript;
      cards.add({
        'id': row.id,
        'created_at': row.createdAt.toUtc().toIso8601String(),
        'started_at': row.startedAt?.toUtc().toIso8601String(),
        'finished_at': row.finishedAt?.toUtc().toIso8601String(),
        'source': row.source?.name,
        'status': row.status.name,
        'starred': row.starred,
        if (row.hasAudio()) 'has_audio_file': true,
        'structured': {
          'title': row.structured.title,
          'emoji': row.structured.emoji,
          'category': row.structured.category,
          'overview': '',
        },
        if (local != null)
          'external_data': {
            (external?.localRecording != null ? 'local_recording' : 'local_transcript'): {
              for (final key in ['origin', 'status', 'duration_seconds', 'failure', 'group'])
                if (local.containsKey(key)) key: local[key],
              if (local['results'] != null) 'results': [],
            },
          },
      });
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = jsonEncode(cards);
      if (cards.isEmpty || value.length > 256 * 1024) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, value);
      }
    } on Exception {
      // A device storage failure must not turn a successful server read into an error.
    }
  }

  Future<List<ServerConversation>> read() async {
    audioFileIds.clear();
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null || raw.length > 256 * 1024) return [];
      final data = jsonDecode(raw);
      if (data is! List || data.length > 30) return [];
      final result = <ServerConversation>[];
      for (final card in data.whereType<Map<String, dynamic>>()) {
        final row = ServerConversation.fromJson(card);
        if (card['has_audio_file'] == true) audioFileIds.add(row.id);
        result.add(row);
      }
      return result;
    } on Exception {
      return [];
    } on TypeError {
      return [];
    }
  }
}
