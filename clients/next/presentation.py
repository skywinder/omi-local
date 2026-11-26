"""Adapt pinned Omi presentation code for a paired, read-only archive."""

from pathlib import Path
import subprocess

WIDGETS = Path('lib/pages/conversation_detail/widgets')
LIST_WIDGETS = Path('lib/pages/conversations/widgets')
UI_BARREL = "import 'package:omi/ui/ui.dart';"


def imports(*names):
    return '\n'.join(f"import 'package:omi/ui/{name}.dart';" for name in names)


def replace(source, old, new, count=1):
    if source.count(old) != count:
        raise ValueError(f'Review the pinned presentation source around {old!r}')
    return source.replace(old, new)


def apply_presentation(repository, revision, app):
    # Keep source local to this generated app. Read the original every time so
    # repeated preparation and moving to a different pin use the same inputs.
    def edit(relative, changes):
        source = subprocess.check_output(
            ['git', '-C', repository, 'show', f'{revision}:app/{relative}'],
            text=True,
        )
        for change in changes:
            source = replace(source, *change)
        (app / relative).write_text(source)

    edit(WIDGETS / 'detail_search_bar.dart', [
        (UI_BARREL, imports('components/omi_button', 'components/omi_icon_button',
                            'components/omi_search_field', 'omi_tokens')),
    ])
    edit(LIST_WIDGETS / 'date_list_item.dart', [
        (UI_BARREL, imports('format/omi_date_format', 'omi_tokens')),
    ])
    edit(LIST_WIDGETS / 'conversation_state_tile.dart', [
        ("import 'package:provider/provider.dart';\n\n", ''),
        ("import 'package:omi/providers/conversations_v3_provider.dart';\n", ''),
        (UI_BARREL, imports('components/omi_cross_fade', 'components/omi_live_indicators',
                            'components/omi_spinner', 'omi_tokens')),
        ('required this.conversation});', 'required this.conversation, this.state, this.emojiOverride});'),
        ('  final ServerConversation conversation;',
         '  final ServerConversation conversation;\n  final ConversationTileState? state;\n'
         '  final String? emojiOverride;'),
        ('            conversation.structured.getEmoji(),',
         '            widget.emojiOverride ?? conversation.structured.getEmoji(),'),
        ('    final v3On = context.select<ConversationsV3Provider?, bool>((p) => p?.v3 ?? false);\n'
         '    final state = v3On ? conversation.v3?.tileState : null;',
         '    final state = widget.state;'),
    ])
    edit(WIDGETS / 'conversation_markdown_widget.dart', [
        (UI_BARREL, imports('omi_tokens')),
        # Markdown from the archive must not open filesystem or network images.
        ('    return MarkdownBody(\n', '    return MarkdownBody(\n      sizedImageBuilder: _imageText,\n', 2),
        ('class _LazyConversationMarkdown extends Markdown {',
         "Widget _imageText(MarkdownImageConfig image) => Text(image.alt ?? '');\n\n"
         'class _LazyConversationMarkdown extends Markdown {'),
        ('required super.styleSheet, this.onDoubleTap});',
         'required super.styleSheet, this.onDoubleTap})\n      : super(sizedImageBuilder: _imageText);'),
    ])
    edit(WIDGETS / 'note_sections_sliver.dart', [
        (UI_BARREL, imports('components/omi_icon_button', 'omi_tokens')),
    ])
    edit(WIDGETS / 'conversation_section_sources.dart', [
        (UI_BARREL, imports('components/omi_icon_button', 'components/omi_sheet', 'format/omi_duration', 'omi_tokens')),
    ])
    edit(Path('lib/widgets/speaker_label_badge.dart'), [
        (UI_BARREL, imports('components/omi_filter_chip', 'omi_tokens')),
    ])
    edit(Path('lib/backend/schema/conversation.dart'), [
        ('  bool starred;\n', '  bool starred;\n  final bool archived;\n'),
        ('    this.starred = false,\n', '    this.starred = false,\n    this.archived = false,\n'),
        ('        starred: starred,\n        folderId:', '        starred: starred,\n        archived: archived,\n        folderId:'),
        ("      deleted: json['deleted'] ?? false,\n", "      deleted: json['deleted'] ?? false,\n      archived: json['archived'] == true,\n"),
        ('    bool deleted = false,\n', '    bool deleted = false,\n    bool archived = false,\n'),
        ('      starred: generated.starred,\n', '      starred: generated.starred,\n      archived: archived,\n'),
        ("      'starred': starred,\n", "      'starred': starred,\n      if (archived) 'archived': true,\n"),
        # The generated wire type already decodes external_data. Keep the paired
        # archive fields when the upstream API projects it into its view model.
        ("  ConversationExternalData({required this.text});\n\n"
         "  factory ConversationExternalData.fromJson(Map<String, dynamic> json) =>\n"
         "      ConversationExternalData(text: json['text'] ?? '');\n\n"
         "  Map<String, dynamic> toJson() => {'text': text};",
         "  final Map<String, dynamic>? localRecording;\n"
         "  final Map<String, dynamic>? localTranscript;\n\n"
         "  ConversationExternalData({required this.text, this.localRecording, this.localTranscript});\n\n"
         "  factory ConversationExternalData.fromJson(Map<String, dynamic> json) => ConversationExternalData(\n"
         "        text: json['text'] is String ? json['text'] as String : '',\n"
         "        localRecording: _localMap(json['local_recording']),\n"
         "        localTranscript: _localMap(json['local_transcript']),\n"
         "      );\n\n"
         "  static Map<String, dynamic>? _localMap(Object? value) =>\n"
         "      value is Map<String, dynamic> ? Map.unmodifiable(value) : null;\n\n"
         "  Map<String, dynamic> toJson() => {\n"
         "        'text': text,\n"
         "        if (localRecording != null) 'local_recording': localRecording,\n"
         "        if (localTranscript != null) 'local_transcript': localTranscript,\n"
         "      };"),
    ])
    edit(Path('lib/backend/http/api_fallback.dart'), [
        ("import 'package:omi/utils/analytics/analytics_manager.dart';", "import 'package:flutter/foundation.dart';"),
        ('  final sink = emit ?? (name, fields) => AnalyticsManager().track(name, properties: fields);',
         "  final sink = emit ?? (name, fields) => debugPrint('$name ${fields['reason']} ${fields['outcome']}');"),
    ])
    edit(Path('lib/backend/schema/transcript_segment.dart'), [
        ("import 'package:omi/backend/preferences.dart';\n", ''),
        ('the cached list), Omi', 'an empty list), Omi'),
        ("the user's given name, else the localized", "the localized"),
        ('people: people ?? SharedPreferencesUtil().cachedPeople,', 'people: people ?? const [],'),
        ('ownerName: ownerName ?? SharedPreferencesUtil().givenName,', 'ownerName: ownerName,'),
    ])
    edit(Path('lib/widgets/transcript.dart'), [
        (UI_BARREL, imports('components/omi_button', 'components/omi_icon_button', 'components/omi_spinner',
                            'feedback/omi_dialogs', 'format/omi_date_format', 'format/omi_duration',
                            'format/speaker_names', 'omi_tokens')),
        ("import 'package:omi/backend/preferences.dart';\n", ''),
        ("import 'package:omi/providers/people_provider.dart';\n", ''),
        ("import 'package:provider/provider.dart';\n", ''),
        ("import 'package:omi/utils/platform/platform_manager.dart';\n", ''),
        ('  final bool followLatest;',
         '  final bool followLatest;\n  final bool showTranslationNotice;\n  final List<Person> localPeople;'),
        ('    this.followLatest = false,',
         '    this.followLatest = false,\n    this.showTranslationNotice = true,\n    this.localPeople = const [],'),
        ('Positioned.fill(child: transcriptList),',
         'Positioned.fill(child: Scrollbar(controller: _scrollController, thumbVisibility: true, '
         'interactive: true, child: transcriptList)),'),
        ('_buildTranslationNotice(),', 'if (widget.showTranslationNotice) _buildTranslationNotice(),', 2),
        ('final people = context.watch<PeopleProvider?>()?.people ?? SharedPreferencesUtil().cachedPeople;',
         'final people = widget.localPeople;'),
        # Only the injected paired callback can open speaker editing.
        ('if (data.speakerId == omiSpeakerId && !data.isUser) return ExcludeSemantics(child: child);',
         'if (widget.editSegment == null || (data.speakerId == omiSpeakerId && !data.isUser)) return child;'),
        ('data.speakerId == omiSpeakerId\n                                  ? null',
         'widget.editSegment == null || data.speakerId == omiSpeakerId\n                                  ? null'),
        ('                    decoration: unnamed ? TextDecoration.underline : null,',
         '                    decoration: unnamed && widget.editSegment != null ? TextDecoration.underline : null,'),
        ('      widget.editSegment?.call(data.id, data.speakerId);\n'
         '      PlatformManager.instance.analytics.tagSheetOpened();',
         '      widget.editSegment?.call(data.id, data.speakerId);'),
        ('                                      PlatformManager.instance.analytics.tagSheetOpened();\n', ''),
        ('                                PlatformManager.instance.analytics.tagSheetOpened();\n', ''),
    ])
