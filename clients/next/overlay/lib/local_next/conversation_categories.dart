import 'package:flutter/material.dart';
import 'package:omi/ui/components/omi_search_field.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'settings_labels.dart';

typedef ConversationCategory = ({String emoji, String en, String ru});

/// The stored keys are the original Omi Structured categories.
const conversationCategories = <String, ConversationCategory>{
  'personal': (emoji: '👤', en: 'Personal', ru: 'Личное'),
  'education': (emoji: '🎓', en: 'Education', ru: 'Образование'),
  'health': (emoji: '🩺', en: 'Health', ru: 'Здоровье'),
  'finance': (emoji: '💰', en: 'Finance', ru: 'Финансы'),
  'legal': (emoji: '⚖️', en: 'Legal', ru: 'Право'),
  'philosophy': (emoji: '💭', en: 'Philosophy', ru: 'Философия'),
  'spiritual': (emoji: '🕊️', en: 'Spirituality', ru: 'Духовность'),
  'science': (emoji: '🔬', en: 'Science', ru: 'Наука'),
  'entrepreneurship': (emoji: '🚀', en: 'Entrepreneurship', ru: 'Предпринимательство'),
  'parenting': (emoji: '🧸', en: 'Parenting', ru: 'Воспитание'),
  'romantic': (emoji: '❤️', en: 'Romance', ru: 'Романтика'),
  'travel': (emoji: '✈️', en: 'Travel', ru: 'Путешествия'),
  'inspiration': (emoji: '✨', en: 'Inspiration', ru: 'Вдохновение'),
  'technology': (emoji: '💻', en: 'Technology', ru: 'Технологии'),
  'business': (emoji: '📊', en: 'Business', ru: 'Бизнес'),
  'social': (emoji: '👥', en: 'Social', ru: 'Общение'),
  'work': (emoji: '💼', en: 'Work', ru: 'Работа'),
  'sports': (emoji: '🏅', en: 'Sports', ru: 'Спорт'),
  'politics': (emoji: '🏛️', en: 'Politics', ru: 'Политика'),
  'literature': (emoji: '📚', en: 'Literature', ru: 'Литература'),
  'history': (emoji: '📜', en: 'History', ru: 'История'),
  'architecture': (emoji: '🏗️', en: 'Architecture', ru: 'Архитектура'),
  'music': (emoji: '🎵', en: 'Music', ru: 'Музыка'),
  'weather': (emoji: '🌤️', en: 'Weather', ru: 'Погода'),
  'news': (emoji: '📰', en: 'News', ru: 'Новости'),
  'entertainment': (emoji: '🎬', en: 'Entertainment', ru: 'Развлечения'),
  'psychology': (emoji: '🧠', en: 'Psychology', ru: 'Психология'),
  'real': (emoji: '🏠', en: 'Real estate', ru: 'Недвижимость'),
  'design': (emoji: '🎨', en: 'Design', ru: 'Дизайн'),
  'family': (emoji: '🏡', en: 'Family', ru: 'Семья'),
  'economics': (emoji: '📈', en: 'Economics', ru: 'Экономика'),
  'environment': (emoji: '🌿', en: 'Environment', ru: 'Окружающая среда'),
  'other': (emoji: '💬', en: 'Other', ru: 'Другое'),
};

String conversationCategoryKey(String category) => conversationCategories.containsKey(category) ? category : 'other';

String conversationCategoryName(BuildContext context, String key) {
  final category = conversationCategories[conversationCategoryKey(key)]!;
  return Localizations.localeOf(context).languageCode == 'ru' ? category.ru : category.en;
}

String conversationCategoryLabel(BuildContext context, String key) =>
    '${conversationCategories[conversationCategoryKey(key)]!.emoji} ${conversationCategoryName(context, key)}';

const allConversationCategories = '*';

Future<String?> pickConversationCategory(BuildContext context, {required String? current, bool filter = false}) {
  final l = context.l10n;
  var query = '';
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: FractionallySizedBox(
          heightFactor: .78,
          child: Column(
            children: [
              ListTile(title: Text(filter ? l.categories : pairedSettingsLabel(context, 'recordingEditCategory'))),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: OmiSpacing.md),
                child: OmiSearchField(
                  placeholder: l.search,
                  onChanged: (value) => setState(() => query = value.trim().toLowerCase()),
                ),
              ),
              if (filter)
                ListTile(
                  title: Text(pairedSettingsLabel(context, 'allConversationCategories')),
                  selected: current == null,
                  selectedColor: OmiColors.textPrimary,
                  trailing: current == null ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.of(context).pop(allConversationCategories),
                ),
              Expanded(
                child: ListView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  children: [
                    for (final entry in conversationCategories.keys)
                      if (conversationCategoryName(context, entry).toLowerCase().contains(query))
                        ListTile(
                          key: ValueKey('conversation-category-$entry'),
                          title: Text(conversationCategoryLabel(context, entry)),
                          selected: current == entry,
                          selectedColor: OmiColors.textPrimary,
                          trailing: current == entry ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.of(context).pop(entry),
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
