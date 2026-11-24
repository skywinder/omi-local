import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/folder.dart';
import 'package:omi/backend/schema/conversation_v3.dart';
import 'package:omi/pages/conversations/widgets/conversation_state_tile.dart';
import 'package:omi/pages/conversations/widgets/date_list_item.dart';
import 'package:omi/ui/components/omi_page_states.dart';
import 'package:omi/ui/components/omi_partial_notice.dart';
import 'package:omi/ui/format/omi_date_format.dart';
import 'package:omi/ui/format/omi_duration.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'paired_library.dart';
import 'recording_page.dart';

/// Feed and cursor belong to a single verified pairing. Its raw page count
/// advances past duplicates and malformed records on accepted partial pages.
class PairedArchiveProvider extends ChangeNotifier {
  PairedArchiveProvider(this._library);
  final PairedLibrary _library;
  final _rows = <String, ServerConversation>{};
  final _editsDuringRead = <String, ServerConversation>{};
  List<({DateTime day, ServerConversation? row})> entries = const [];
  bool busy = false, more = false, partial = false;
  Object? failure;
  int _offset = 0;
  bool _disposed = false;
  bool _retryAppend = false;
  bool _starredOnly = false;
  bool _refreshStarred = false;
  Folder? folder;

  bool get starredOnly => _starredOnly;
  Future<void> refresh() => _load(append: false);
  Future<void> loadMore() => _load(append: true);
  Future<void> retry() => _load(append: _retryAppend);
  ServerConversation? rowById(String id) => _rows[id];

  void refreshAfterFolderChange({String? deletedId}) {
    if (_disposed) return;
    if (deletedId != null && folder?.id == deletedId) folder = null;
    if (busy) {
      _refreshStarred = true;
    } else {
      unawaited(refresh());
    }
  }

  Future<void> filterStarred(bool value) async {
    if (_disposed || busy || _starredOnly == value) return;
    _starredOnly = value;
    await _refreshFilter();
  }

  Future<void> filterFolder(Folder? value) async {
    if (_disposed || busy) return;
    final changed = folder?.id != value?.id;
    folder = value;
    if (changed) {
      await _refreshFilter();
    } else {
      notifyListeners();
    }
  }

  void renameFolder(Folder value) {
    if (_disposed || folder?.id != value.id) return;
    folder = value;
    notifyListeners();
  }

  bool _matches(ServerConversation row) =>
      (!_starredOnly || row.starred) && (folder == null || row.folderId == folder!.id);

  Future<void> _refreshFilter() async {
    _rows.clear();
    entries = const [];
    more = false;
    await refresh();
  }

  void applyEdit(ServerConversation row) {
    if (_disposed) return;
    if ((_starredOnly || folder != null) && _matches(row) != _rows.containsKey(row.id)) {
      if (busy) {
        _editsDuringRead[row.id] = row;
        _refreshStarred = true;
      } else {
        unawaited(refresh());
      }
      return;
    }
    if (!_rows.containsKey(row.id)) return;
    if (busy) _editsDuringRead[row.id] = row;
    _rows[row.id] = row;
    entries = List.unmodifiable(entries.map((entry) => entry.row?.id == row.id ? (day: entry.day, row: row) : entry));
    notifyListeners();
  }

  Future<void> _load({required bool append}) async {
    if (_disposed || busy || (append && !more)) return;
    busy = true;
    failure = null;
    _retryAppend = append;
    notifyListeners();
    try {
      if (!_library.verified) await _library.verify();
      if (_disposed) return;
      final result = await _library.list(append ? _offset : 0, starredOnly: _starredOnly, folderId: folder?.id);
      if (_disposed) return;
      if (!append) {
        _rows.clear();
        partial = false;
        _offset = 0;
      }
      for (final row in result.rows) {
        final fresh = _editsDuringRead[row.id] ?? row;
        if (_matches(fresh)) _rows[fresh.id] = fresh;
      }
      _offset += result.consumed;
      more = result.more && result.consumed > 0;
      partial |= result.partial;
      final sorted = _rows.values.toList()
        ..sort((a, b) {
          final time = (b.startedAt ?? b.createdAt).compareTo(a.startedAt ?? a.createdAt);
          return time != 0 ? time : a.id.compareTo(b.id);
        });
      final grouped = <({DateTime day, ServerConversation? row})>[];
      for (final row in sorted) {
        final start = (row.startedAt ?? row.createdAt).toLocal();
        final day = DateTime(start.year, start.month, start.day);
        if (grouped.isEmpty || grouped.last.day != day) grouped.add((day: day, row: null));
        grouped.add((day: day, row: row));
      }
      entries = List.unmodifiable(grouped);
    } catch (error) {
      if (_disposed) return;
      failure = error;
      if (error == LibraryFailure.key) {
        _rows.clear();
        entries = const [];
        _offset = 0;
        more = false;
        partial = false;
      }
    } finally {
      _editsDuringRead.clear();
      if (!_disposed) {
        busy = false;
        notifyListeners();
        if (_refreshStarred) {
          _refreshStarred = false;
          unawaited(refresh());
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _rows.clear();
    _editsDuringRead.clear();
    entries = const [];
    super.dispose();
  }
}

class PairedArchiveFeed extends StatelessWidget {
  const PairedArchiveFeed({
    super.key,
    required this.archive,
    required this.onOpen,
    required this.errorText,
    this.selection,
  });
  final PairedArchiveProvider archive;
  final ValueChanged<String> onOpen;
  final String Function(BuildContext context, Object? failure) errorText;
  final Set<String>? selection;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final error = archive.failure;
    final entries = archive.entries;
    if (entries.isEmpty && !archive.more) {
      if (archive.busy) return const OmiLoadingState();
      if (error != null || archive.partial) {
        return OmiErrorState(
          message: error == null ? l.couldNotLoadPage : errorText(context, error),
          onRetry: archive.refresh,
        );
      }
      return OmiEmptyState(icon: Icons.forum_rounded, title: l.noConversationsYet);
    }
    return Column(
      children: [
        if (archive.busy) const LinearProgressIndicator(),
        if (archive.partial || error != null)
          OmiPartialNotice(
            onRetry: error == null ? archive.refresh : archive.retry,
            message: error == null ? l.couldNotLoadPage : errorText(context, error),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: archive.refresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: entries.length + (archive.more ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == entries.length) {
                  return TextButton(onPressed: archive.busy ? null : archive.loadMore, child: Text(l.showMore));
                }
                final entry = entries[index], row = entry.row;
                if (row == null) {
                  return DateListItem(key: ValueKey(entry.day), date: entry.day, isFirst: index == 0);
                }
                return _ArchiveRow(
                  key: ValueKey(row.id),
                  row: row,
                  onOpen: onOpen,
                  selected: selection?.contains(row.id),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _ArchiveRow extends StatelessWidget {
  const _ArchiveRow({super.key, required this.row, required this.onOpen, this.selected});
  final ServerConversation row;
  final ValueChanged<String> onOpen;
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final started = (row.startedAt ?? row.createdAt).toLocal();
    final duration = row.getDurationInSeconds();
    final local = row.externalIntegration?.localRecording;
    // Local jobs span multiple processing stages. Their generic status cannot
    // tell the upstream tile whether transcription or summary is in progress.
    final tile = local == null ? row.v3?.tileState : null;
    final failed = local?['status'] == 'failed' || (local == null && row.status == ConversationStatus.failed);
    final meta = [
      OmiDateFormat.of(context).time(started),
      if (duration > 0) OmiDuration.compact(duration, context.l10n),
      recordingStatus(context, row),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: OmiColors.surface1,
        borderRadius: OmiRadius.xlAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onOpen(row.id),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                ExcludeSemantics(
                  // The stock failure glyph announces "summary failed". Local
                  // processing can fail earlier; its exact label is in the subtitle.
                  excluding: local != null || (failed && tile == null),
                  child: ConversationStateTile(conversation: row, state: failed ? ConversationTileState.failed : tile),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        recordingTitle(context, row),
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(meta, style: OmiType.footnote.copyWith(color: OmiColors.textSecondary)),
                    ],
                  ),
                ),
                if (selected != null)
                  Icon(selected! ? Icons.check_box : Icons.check_box_outline_blank)
                else if (row.starred)
                  Icon(Icons.star, size: 17, semanticLabel: context.l10n.starred),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
