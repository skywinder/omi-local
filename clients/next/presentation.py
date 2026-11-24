"""Adapt pinned Omi presentation code for a paired, read-only archive."""

from pathlib import Path
import subprocess

WIDGETS = Path('lib/pages/conversation_detail/widgets')
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
        ('  final bool followLatest;', '  final bool followLatest;\n  final bool showTranslationNotice;'),
        ('    this.followLatest = false,', '    this.followLatest = false,\n    this.showTranslationNotice = true,'),
        ('_buildTranslationNotice(),', 'if (widget.showTranslationNotice) _buildTranslationNotice(),', 2),
        ('final people = context.watch<PeopleProvider?>()?.people ?? SharedPreferencesUtil().cachedPeople;',
         'const people = <Person>[];'),
        # No editing or hosted analytics in the read-only transcript.
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
