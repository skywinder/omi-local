import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:share_plus/share_plus.dart';

import 'package:omi/backend/schema/conversation.dart';

/// Build the local export from the full detail response, including overlapping speaker turns.
String localConversationText(
  ServerConversation conversation, {
  required String summaryLabel,
  required String transcriptLabel,
}) {
  final structured = conversation.structured;
  final sections = [
    structured.title.trim(),
    summaryLabel,
    structured.overview.trim(),
    for (final section in structured.sections)
      [section.heading.trim(), section.bodyMarkdown.trim()].where((s) => s.isNotEmpty).join('\n'),
    transcriptLabel,
    conversation.transcriptSegments
        .map((segment) => '[${segment.getTimestampString()}] ${segment.text.trim()}')
        .join('\n'),
  ];
  return sections.where((s) => s.isNotEmpty).join('\n\n');
}

Future<void> shareLocalConversation(
  ServerConversation conversation, {
  required String summaryLabel,
  required String transcriptLabel,
  Rect? origin,
}) async {
  final content = localConversationText(conversation, summaryLabel: summaryLabel, transcriptLabel: transcriptLabel);
  final date = conversation.createdAt.toLocal().toIso8601String().split('.').first.replaceAll(':', '-');
  final filename = 'Omi-$date.txt';
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(Uint8List.fromList(utf8.encode(content)), mimeType: 'text/plain', name: filename)],
      fileNameOverrides: [filename],
      subject: conversation.structured.title,
      sharePositionOrigin: origin,
    ),
  );
}
