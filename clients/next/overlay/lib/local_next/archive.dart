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

import 'accents.dart';
import 'paired_library.dart';
import 'archive_cache.dart';
import 'archive_visibility.dart';
import 'recording_edit.dart';
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
  ArchiveVisibility visibility = const ArchiveVisibility();
  bool _visibilityRequested = false;
  bool _visibilityChanged = false;

  Future<void> _restoreVisibility() async {
    final saved = await ArchiveVisibility.read(_library.audioOwnerId);
    if (_disposed || _visibilityChanged || !saved.active) return;
    visibility = saved;
    _groupEntries();
    notifyListeners();
  }

  Future<void> changeVisibility(BuildContext context) async {
    final choice = await showDialog<ArchiveVisibility>(
      context: context,
      builder: (_) => ArchiveVisibilityDialog(visibility),
    );
    if (choice == null || _disposed || !context.mounted) return;
    try {
      if (!await choice.save(_library.audioOwnerId)) throw StateError('Archive preferences unavailable');
      if (_disposed) return;
      visibility = choice;
      _visibilityChanged = true;
      _groupEntries();
      notifyListeners();
    } catch (_) {
      if (!_disposed && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.failedToSaveCheckConnection)));
      }
    }
  }

  final _rows = <String, ServerConversation>{};
  final _editsDuringRead = <String, ServerConversation>{};
  final _publicationsDuringRead = <String, List<ServerConversation>>{};
  List<({DateTime day, ServerConversation? row})> entries = const [];
  bool busy = false, more = false, partial = false;
  Object? failure;
  int _offset = 0;
  bool _disposed = false;
  bool _retryAppend = false;
  bool _starredOnly = false;
  bool _archivedOnly = false;
  bool _refreshAfterRead = false;
  bool _paged = false;
  int _deliveryRevision = 0;
  int _refreshedDelivery = 0;
  Timer? _localRefresh;
  Folder? folder;
  String? category;

  bool get starredOnly => _starredOnly;
  bool get archivedOnly => _archivedOnly;
  Future<void> refresh() => _load(append: false);
  Future<void> loadMore() => _load(append: true);
  Future<void> retry() => _load(append: _retryAppend);

  Future<void> refreshAfterServerCheck({required bool periodic}) async {
    if (_isConnectionFailure(failure)) {
      await _load(append: _retryAppend, automatic: true);
    } else if (periodic && failure == null && !_paged && _localRefresh == null) {
      // A receipt may precede publication. Another phone's delivery has no local receipt at all.
      await _load(append: false, automatic: true);
    }
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
      (row) => const {
        'saved',
        'pending',
        'processing',
        'waiting_for_parts',
      }.contains(row.externalIntegration?.localRecording?['status']),
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

  void refreshAfterArchiveEdit({String? deletedFolderId}) {
    if (_disposed) return;
    if (deletedFolderId != null && folder?.id == deletedFolderId) folder = null;
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

  Future<void> filterArchived(bool value) async {
    if (_disposed || busy || !_library.recordingArchive || _archivedOnly == value) return;
    _archivedOnly = value;
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
      (!_library.recordingArchive || row.archived == _archivedOnly) &&
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
    if ((_library.recordingArchive || _starredOnly || folder != null || category != null) &&
        _matches(row) != _rows.containsKey(row.id)) {
      if (_rows.remove(row.id) != null) {
        _groupEntries();
        notifyListeners();
      }
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
    _groupEntries();
    notifyListeners();
  }

  void replacePending(String previousId, List<ServerConversation> rows) {
    if (_disposed) return;
    if (busy) _publicationsDuringRead[previousId] = rows;
    if (_rows.remove(previousId) == null) return;
    for (final row in rows.where(_matches)) {
      _rows.putIfAbsent(row.id, () => row);
    }
    _groupEntries();
    notifyListeners();
  }

  void _groupEntries() {
    final sorted =
        _rows.values
            .where(
              (row) => visibility.includes(row, cachedAudioFile: showingCached && _cache.audioFileIds.contains(row.id)),
            )
            .toList()
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
      if (!_visibilityRequested) {
        _visibilityRequested = true;
        unawaited(_restoreVisibility());
      }
      if (!_library.verified) await _library.verify();
      if (_disposed) return;
      if (!_library.recordingArchive) _archivedOnly = false;
      final result = await _library.list(
        append ? _offset : 0,
        starredOnly: _starredOnly,
        archivedOnly: _archivedOnly,
        folderId: folder?.id,
      );
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
        for (final published in _publicationsDuringRead[row.id] ?? [row]) {
          final fresh = _editsDuringRead[published.id] ?? published;
          if (_matches(fresh)) _rows[fresh.id] = fresh;
        }
      }
      _offset += result.consumed;
      more = result.more && result.consumed > 0;
      partial |= result.partial;
      showingCached = false;
      _groupEntries();
      if (!append && !result.partial && !_archivedOnly && !_starredOnly && folder == null && category == null) {
        unawaited(_cache.write(_rows.values.toList()));
      }
    } catch (error) {
      if (_disposed) return;
      if (_isConnectionFailure(error) &&
          entries.isEmpty &&
          !append &&
          !_archivedOnly &&
          !_starredOnly &&
          folder == null &&
          category == null) {
        final cached = await _cache.read();
        if (_disposed) return;
        for (final row in cached.where(_matches)) {
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

  Future<void> _quickActions(BuildContext context, ServerConversation row) async {
    final messenger = ScaffoldMessenger.of(context);
    final edit = await showModalBottomSheet<RecordingEdit>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(row.starred ? Icons.star : Icons.star_outline),
              title: Text(pairedSettingsLabel(sheet, row.starred ? 'recordingUnstar' : 'recordingStar')),
              onTap: () => Navigator.pop(sheet, RecordingEdit.starred(row.starred, !row.starred)),
            ),
            if (archive._library.recordingArchive)
              ListTile(
                leading: Icon(row.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
                title: Text(
                  pairedSettingsLabel(sheet, row.archived ? 'recordingRestoreFromArchive' : 'recordingMoveToArchive'),
                ),
                onTap: () => Navigator.pop(sheet, RecordingEdit.archived(row.archived, !row.archived)),
              ),
          ],
        ),
      ),
    );
    if (edit == null || archive._disposed || !context.mounted) return;
    try {
      final updated = await archive._library.editRecording(row.id, edit);
      archive.applyEdit(updated);
    } catch (error) {
      if (archive._disposed || !context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(recordingEditError(context, error))));
      if (error == RecordingEditFailure.conflict) archive.refreshAfterArchiveEdit();
    }
  }

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
      return OmiEmptyState(
        icon: Icons.forum_rounded,
        title: archive.visibility.active
            ? pairedSettingsLabel(context, 'archiveVisibilityEmpty')
            : archive.archivedOnly
            ? pairedSettingsLabel(context, 'recordingArchiveEmpty')
            : l.noConversationsYet,
      );
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
                  onHold:
                      selection == null &&
                          !archive.showingCached &&
                          archive._library.recordingEdits &&
                          !row.isLocked &&
                          row.externalIntegration?.localRecording == null &&
                          row.status == ConversationStatus.completed
                      ? () => _quickActions(context, row)
                      : null,
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
  const _ArchiveRow({super.key, required this.row, required this.onOpen, this.onHold, this.selected});
  final ServerConversation row;
  final ValueChanged<String> onOpen;
  final bool? selected;
  final VoidCallback? onHold;

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
    final status = local == null ? row.status.name : local['status'];
    final (stageAccent, stageIcon) = switch (status) {
      'failed' => (NextAccent.red, Icons.error_outline),
      'processing' => (NextAccent.blue, Icons.graphic_eq),
      'pending' || 'waiting_for_parts' => (NextAccent.amber, Icons.schedule),
      'receiving' => (NextAccent.teal, Icons.downloading_outlined),
      'no_speech' => (NextAccent.slate, Icons.mic_off_outlined),
      _ => (NextAccent.slate, Icons.inventory_2_outlined),
    };
    final meta = [
      OmiDateFormat.of(context).time(started),
      if (recordingInput(context, row).isNotEmpty) recordingInput(context, row),
      if (duration > 0) OmiDuration.compact(duration, context.l10n),
      if (showCategory) conversationCategoryName(context, category),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: OmiColors.surface1,
        borderRadius: OmiRadius.xlAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onOpen(row.id),
          onLongPress: onHold,
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
                      if (local != null || row.status != ConversationStatus.completed)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: stageAccent.tint(context), borderRadius: OmiRadius.smAll),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(stageIcon, size: 16, color: stageAccent.of(context)),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      recordingStatus(context, row),
                                      style: OmiType.footnote.copyWith(color: stageAccent.of(context)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (selected != null)
                  Icon(selected! ? Icons.check_box : Icons.check_box_outline_blank)
                else if (row.starred)
                  Icon(Icons.star, size: 17, color: NextAccent.amber.of(context), semanticLabel: context.l10n.starred),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
