import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/ui/components/omi_search_field.dart';
import 'package:omi/ui/format/omi_date_format.dart';
import 'package:omi/ui/format/omi_duration.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'paired_library.dart';
import 'recording_chat_page.dart';
import 'recording_page.dart';
import 'settings_labels.dart';

class ArchiveSearchPageView extends StatefulWidget {
  const ArchiveSearchPageView({super.key, required this.library});
  final PairedLibrary library;

  @override
  State<ArchiveSearchPageView> createState() => _ArchiveSearchPageViewState();
}

class _ArchiveSearchPageViewState extends State<ArchiveSearchPageView> {
  final _hits = <String, ArchiveSearchHit>{};
  Timer? _debounce;
  int _generation = 0;
  String _query = '';
  String? _cursor;
  bool _loading = false;
  bool _unsupported = false;
  Object? _error;

  void _changed(String input, {bool submit = false}) {
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _query = input.trim();
      _hits.clear();
      _cursor = null;
      _error = null;
      _unsupported = false;
      _loading = _query.isNotEmpty && _query.runes.length <= 240;
    });
    if (!_loading) return;
    final query = _query;
    if (submit) {
      unawaited(_load(query, generation));
    } else {
      _debounce = Timer(const Duration(milliseconds: 320), () => unawaited(_load(query, generation)));
    }
  }

  Future<void> _load(String query, int generation) async {
    var cursor = _cursor;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      do {
        final page = await widget.library.searchArchive(query, after: cursor);
        if (!mounted || generation != _generation) return;
        if (page == null) {
          setState(() => _unsupported = true);
          return;
        }
        cursor = page.nextCursor;
        if (page.hits.isNotEmpty) {
          setState(() {
            for (final hit in page.hits) {
              _hits[hit.id] = hit;
            }
          });
          break;
        }
      } while (cursor != null);
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _cursor = cursor;
          _loading = false;
        });
      }
    }
  }

  void _open(ArchiveSearchHit hit, [TranscriptMatchSnippet? snippet]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordingPage(library: widget.library, id: hit.id, initialMatch: snippet),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final hits = _hits.values.toList()..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return Scaffold(
      appBar: AppBar(
        title: Text(l.searchConversations),
        actions: [
          IconButton(
            tooltip: pairedSettingsLabel(context, 'archiveChatTitle'),
            icon: const Icon(Icons.chat_bubble_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (chatContext) => RecordingChatPage.archive(
                  library: widget.library,
                  onOpenSource: (id, match) => Navigator.of(chatContext).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RecordingPage(
                        library: widget.library,
                        id: id,
                        initialMatch: match,
                        verifyInitialExcerpt: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(OmiSpacing.md),
            child: OmiSearchField(
              placeholder: l.searchConversations,
              autofocus: true,
              onChanged: _changed,
              onSubmitted: (text) => _changed(text, submit: true),
            ),
          ),
          Expanded(
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                for (final hit in hits) ...[
                  ListTile(
                    title: Text(hit.title.isEmpty ? l.untitledConversation : hit.title),
                    subtitle: Text(OmiDateFormat.of(context).date(hit.startedAt.toLocal())),
                    onTap: () => _open(hit),
                  ),
                  for (final snippet in hit.snippets)
                    ListTile(
                      leading: const Icon(Icons.notes),
                      title: Text(snippet.text, maxLines: 3, overflow: TextOverflow.ellipsis),
                      subtitle: snippet.start == null ? null : Text(OmiDuration.offset(snippet.start!)),
                      onTap: () => _open(hit, snippet),
                    ),
                ],
                if (_loading) const LinearProgressIndicator(),
                if (_unsupported)
                  ListTile(title: Text(pairedSettingsLabel(context, 'archiveSearchUnsupported')))
                else if (_error != null)
                  ListTile(
                    title: Text(_error == LibraryFailure.key ? l.invalidKey : l.couldNotLoadPage),
                    trailing: TextButton(onPressed: () => _load(_query, _generation), child: Text(l.retry)),
                  )
                else if (_query.runes.length > 240)
                  ListTile(title: Text(pairedSettingsLabel(context, 'archiveSearchTooLong')))
                else if (!_loading && _cursor != null)
                  TextButton(onPressed: () => _load(_query, _generation), child: Text(l.showMore))
                else if (!_loading && _query.isNotEmpty && hits.isEmpty)
                  ListTile(title: Text(l.noResultsFound)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
