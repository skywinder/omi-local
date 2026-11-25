import 'dart:async';
import 'dart:io';

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
import 'archive_cache.dart';
import 'settings_labels.dart';
import 'recording_page.dart';
import 'conversation_categories.dart';

/// Feed and cursor belong to a single verified pairing. Its raw page count
/// advances past duplicates and malformed records on accepted partial pages.
class PairedArchiveProvider extends ChangeNotifier {
  PairedArchiveProvider(this._library, {bool Function()? canRefreshRecordings})
    : _canRefreshRecordings = canRefreshRecordings;
  final PairedLibrary _library;
  final bool Function()? _canRefreshRecordings;
  late final _cache = NextArchiveCache(_library.audioOwnerId);
  bool showingCached = false;
  final _rows = <String, ServerConversation>{};
  final _editsDuringRead = <String, ServerConversation>{};
  final _publicationsDuringRead = <String, ServerConversation>{};
  List<({DateTime day, ServerConversation? row})> entries = const [];
  bool busy = false, more = false, partial = false;
  Object? failure;
  int _offset = 0;
  bool _disposed = false;
  bool _retryAppend = false;
  bool _starredOnly = false;
  bool _refreshAfterRead = false;
  bool _paged = false;
  int _deliveryRevision = 0;
  int _refreshedDelivery = 0;
  Timer? _localRefresh;
  Folder? folder;
  String? category;

  bool get starredOnly => _starredOnly;
  Future<void> refresh() => _load(append: false);
  Future<void> loadMore() => _load(append: true);
  Future<void> retry() => _load(append: _retryAppend);

  Future<void> recoverAfterServerCheck() async {
    if (!_isConnectionFailure(failure)) return;
    await _load(append: _retryAppend, automatic: true);
  }

  static bool _isConnectionFailure(Object? error) =>
      error == LibraryFailure.unavailable ||
      error is SocketException ||
      error is TimeoutException ||
      error is HttpException;

  ServerConversation? rowById(String id) => _rows[id];

  // A durable receipt is independent of the Live socket and survives retries.
  // Keep a user's position after loading older pages until an explicit refresh.
  void refreshAfterRecording() {
    if (_disposed) return;
    _deliveryRevision++;
    _scheduleLocalRefresh(now: true);
  }

  void _scheduleLocalRefresh({bool now = false}) {
    final canRefresh = _canRefreshRecordings;
    if (_disposed || canRefresh == null || _paged || busy || (!now && _localRefresh != null)) return;
    final awaitingProcessing = _rows.values.any(
      (row) => const {'saved', 'pending', 'processing'}.contains(row.externalIntegration?.localRecording?['status']),
    );
    if (_refreshedDelivery == _deliveryRevision && !awaitingProcessing) return;
    _localRefresh?.cancel();
    _localRefresh = Timer(now ? Duration.zero : const Duration(seconds: 5), () {
      _localRefresh = null;
      if (canRefresh()) {
        unawaited(_load(append: false, automatic: true));
      } else {
        _scheduleLocalRefresh();
      }
    });
  }

  void refreshAfterFolderChange({String? deletedId}) {
    if (_disposed) return;
    if (deletedId != null && folder?.id == deletedId) folder = null;
    if (busy) {
      _refreshAfterRead = true;
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

  Future<void> filterCategory(String? value) async {
    if (_disposed || busy || category == value) return;
    category = value;
    await _refreshFilter();
  }

  void renameFolder(Folder value) {
    if (_disposed || folder?.id != value.id) return;
    folder = value;
    notifyListeners();
  }

  bool _matches(ServerConversation row) =>
      (!_starredOnly || row.starred) &&
      (folder == null || row.folderId == folder!.id) &&
      (category == null || conversationCategoryKey(row.structured.category) == category);

  Future<void> _refreshFilter() async {
    showingCached = false;
    _rows.clear();
    entries = const [];
    more = false;
    await refresh();
  }

  void applyEdit(ServerConversation row) {
    if (_disposed) return;
    if ((_starredOnly || folder != null || category != null) && _matches(row) != _rows.containsKey(row.id)) {
      if (busy) {
        _editsDuringRead[row.id] = row;
        _refreshAfterRead = true;
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

  void replacePending(String previousId, ServerConversation row) {
    if (_disposed) return;
    if (busy) _publicationsDuringRead[previousId] = row;
    if (_rows.remove(previousId) == null) return;
    if (_matches(row)) _rows[row.id] = row;
    _groupEntries();
    notifyListeners();
  }

  void _groupEntries() {
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
  }

  Future<void> _load({required bool append, bool automatic = false}) async {
    if (_disposed || busy || (append && !more)) return;
    _localRefresh?.cancel();
    _localRefresh = null;
    final deliveryAtRead = _deliveryRevision;
    busy = true;
    if (!automatic) {
      failure = null;
      _retryAppend = append;
      notifyListeners();
    }
    try {
      if (!_library.verified) await _library.verify();
      if (_disposed) return;
      final result = await _library.list(append ? _offset : 0, starredOnly: _starredOnly, folderId: folder?.id);
      if (_disposed) return;
      if (!append) {
        _rows.clear();
        if (!result.partial) _refreshedDelivery = deliveryAtRead;
        partial = false;
        _offset = 0;
      }
      _paged = append;
      failure = null;
      for (final row in result.rows) {
        final published = _publicationsDuringRead[row.id] ?? row;
        final fresh = _editsDuringRead[published.id] ?? published;
        if (_matches(fresh)) _rows[fresh.id] = fresh;
      }
      _offset += result.consumed;
      more = result.more && result.consumed > 0;
      partial |= result.partial;
      _groupEntries();
      showingCached = false;
      if (!append && !result.partial && !_starredOnly && folder == null && category == null) {
        unawaited(_cache.write(_rows.values.toList()));
      }
    } catch (error) {
      if (_disposed) return;
      if (_isConnectionFailure(error) &&
          entries.isEmpty &&
          !append &&
          !_starredOnly &&
          folder == null &&
          category == null) {
        final cached = await _cache.read();
        if (_disposed) return;
        for (final row in cached) {
          _rows[row.id] = row;
        }
        showingCached = cached.isNotEmpty;
        more = false;
        _groupEntries();
      }
      if (error == LibraryFailure.key) {
        showingCached = false;
        unawaited(_cache.write([]));
        failure = error;
        _rows.clear();
        entries = const [];
        _offset = 0;
        more = false;
        partial = false;
        _refreshedDelivery = _deliveryRevision;
      } else if (!automatic || failure != null || entries.isEmpty) {
        failure = error;
      }
    } finally {
      _editsDuringRead.clear();
      _publicationsDuringRead.clear();
      if (!_disposed) {
        busy = false;
        notifyListeners();
        if (_refreshAfterRead) {
          _refreshAfterRead = false;
          unawaited(refresh());
        } else {
          _scheduleLocalRefresh(now: deliveryAtRead != _deliveryRevision);
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _localRefresh?.cancel();
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
          message: archive.showingCached
              ? pairedSettingsLabel(context, 'nextCachedArchive')
              : error == null
              ? l.couldNotLoadPage
              : errorText(context, error),
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
            message: archive.showingCached
                ? pairedSettingsLabel(context, 'nextCachedArchive')
                : error == null
                ? l.couldNotLoadPage
                : errorText(context, error),
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
    final duration = recordingDuration(row);
    final local = row.externalIntegration?.localRecording;
    // Local jobs span multiple processing stages. Their generic status cannot
    // tell the upstream tile whether transcription or summary is in progress.
    final tile = local == null ? row.v3?.tileState : null;
    final failed = local?['status'] == 'failed' || (local == null && row.status == ConversationStatus.failed);
    final category = conversationCategoryKey(row.structured.category);
    final showCategory = local == null && row.status == ConversationStatus.completed;
    final useCategoryEmoji =
        showCategory && category != 'other' && const {'', '🧠', '💬', '🎙️'}.contains(row.structured.emoji.trim());
    final meta = [
      OmiDateFormat.of(context).time(started),
      if (recordingInput(context, row).isNotEmpty) recordingInput(context, row),
      if (duration > 0) OmiDuration.compact(duration, context.l10n),
      if (showCategory) conversationCategoryName(context, category),
      if (local != null || row.status != ConversationStatus.completed) recordingStatus(context, row),
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
                  child: ConversationStateTile(
                    conversation: row,
                    state: failed ? ConversationTileState.failed : tile,
                    emojiOverride: useCategoryEmoji ? conversationCategories[category]!.emoji : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        recordingTitle(context, row),
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(meta, style: OmiType.footnote.copyWith(color: OmiColors.textTertiary)),
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
