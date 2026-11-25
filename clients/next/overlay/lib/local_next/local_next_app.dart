import 'package:flutter/material.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/ui/omi_theme.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'archive.dart';
import 'conversation_categories.dart';
import 'daily_recaps_page.dart';
import 'folder_picker.dart';
import 'local_goals_page.dart';
import 'local_tasks_page.dart';
import 'recording_edit.dart';
import 'archive_search_page.dart';
import 'capture_panel.dart';
import 'paired_library.dart';
import 'recording_page.dart';
import 'server_catalog.dart';
import 'server_session.dart';
import 'servers_page.dart';
import 'settings_labels.dart';

class LocalNextApp extends StatelessWidget {
  const LocalNextApp({super.key, this.session});
  final NextServerSession? session;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Omi Local Next',
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: _nextTheme(Brightness.light),
    darkTheme: _nextTheme(Brightness.dark),
    builder: (context, child) {
      OmiColors.active = OmiColors.forBrightness(Theme.of(context).brightness);
      return child!;
    },
    home: _Pairing(session: session),
  );
}

ThemeData _nextTheme(Brightness brightness) {
  final palette = OmiColors.forBrightness(brightness);
  final theme = buildOmiTheme(brightness: brightness);
  final disabled = Color.alphaBlend(palette.textPrimary.withValues(alpha: .58), palette.surface0);
  final outline = Color.alphaBlend(palette.textPrimary.withValues(alpha: .56), palette.surface0);
  return theme.copyWith(
    disabledColor: disabled,
    textTheme: theme.textTheme.copyWith(
      bodySmall: theme.textTheme.bodySmall?.copyWith(color: palette.textTertiary),
      labelMedium: theme.textTheme.labelMedium?.copyWith(color: palette.textTertiary),
    ),
    iconTheme: IconThemeData(color: palette.textPrimary),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: palette.textPrimary, disabledForegroundColor: disabled),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.textPrimary,
        disabledForegroundColor: disabled,
        side: BorderSide(color: outline),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
        disabledBackgroundColor: palette.surface3,
        disabledForegroundColor: palette.textTertiary,
      ),
    ),
    inputDecorationTheme: theme.inputDecorationTheme.copyWith(
      labelStyle: TextStyle(color: palette.textTertiary),
      hintStyle: TextStyle(color: palette.textTertiary),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: palette.textPrimary,
      unselectedLabelColor: palette.textTertiary,
      indicatorColor: palette.accent,
    ),
  );
}

enum _ArchiveAction { refresh, tasks, recaps, goals, select }

class _Pairing extends StatefulWidget {
  const _Pairing({this.session});
  final NextServerSession? session;
  @override
  State<_Pairing> createState() => _PairingState();
}

class _PairingState extends State<_Pairing> {
  late final NextServerSession session;
  PairedLibrary? _shown;

  @override
  void initState() {
    super.initState();
    session = widget.session ?? NextServerSession(NextServerCatalog());
    session.addListener(_changed);
    session.initialize();
  }

  void _changed() {
    if (_shown != session.active) {
      _shown = session.active;
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    setState(() {});
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = session.active;
    if (active == null) return NextServersPage(session: session);
    final named = session.servers.where((entry) => entry.id == session.activeId).firstOrNull;
    return LocalNextLibraryPage(
      key: ObjectKey(active),
      library: active,
      serverName: named?.name ?? active.origin.authority,
      pairingBusy: session.busy,
      openServers: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => NextServersPage(session: session, manager: true))),
    );
  }
}

class LocalNextLibraryPage extends StatefulWidget {
  const LocalNextLibraryPage({
    super.key,
    required this.library,
    this.openServers,
    this.serverName,
    this.pairingBusy = false,
  });
  final VoidCallback? openServers;
  final String? serverName;
  final bool pairingBusy;
  final PairedLibrary library;
  @override
  State<LocalNextLibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LocalNextLibraryPage> {
  late PairedArchiveProvider _archive;
  Map<String, String?>? _selection;
  bool _moving = false;

  Future<void> _moveSelected() async {
    final library = widget.library;
    final archive = _archive;
    final selected = _selection;
    if (_moving || selected == null || selected.isEmpty) return;
    setState(() => _moving = true);
    try {
      final destination = await pickLocalFolder(context, library, moving: true);
      if (!mounted || widget.library != library || destination == null) return;
      await library.bulkMoveFolders(selected, destination.folder?.id);
      if (!mounted || widget.library != library) return;
      setState(() => _selection = null);
      archive.refreshAfterFolderChange();
    } catch (error) {
      if (mounted && widget.library == library) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(recordingEditError(context, error))));
      }
    } finally {
      if (mounted && widget.library == library) setState(() => _moving = false);
    }
  }

  void _select(String id) {
    final selection = _selection;
    final row = _archive.rowById(id);
    if (_moving || selection == null || row == null || row.status != ConversationStatus.completed || row.isLocked) {
      return;
    }
    setState(() {
      if (selection.containsKey(id)) {
        selection.remove(id);
      } else if (selection.length < 100) {
        selection[id] = row.folderId;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _archive = PairedArchiveProvider(widget.library, canRefreshRecordings: _canRefreshRecordings)
      ..addListener(_changed);
    _archive.refresh();
  }

  bool _canRefreshRecordings() {
    final state = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        _selection == null &&
        (state == null || state == AppLifecycleState.resumed) &&
        ModalRoute.isCurrentOf(context) == true;
  }

  void _changed() => setState(() {});

  @override
  void didUpdateWidget(LocalNextLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      _selection = null;
      _moving = false;
      _archive.dispose();
      _attach();
    }
  }

  @override
  void dispose() {
    _archive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final library = widget.library;
    final archive = _archive;
    final selection = _selection;
    final serverName = widget.serverName ?? library.origin.authority;
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: InkWell(
          key: const ValueKey('archive-servers'),
          onTap: widget.pairingBusy ? null : widget.openServers,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.conversations, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (widget.openServers != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          serverName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: OmiColors.textTertiary),
                        ),
                      ),
                      const Icon(Icons.expand_more, size: 16),
                    ],
                  ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: l.searchConversations,
            icon: const Icon(Icons.search),
            onPressed: () => open(ArchiveSearchPageView(library: library, onEdited: archive.applyEdit)),
          ),
          PopupMenuButton<_ArchiveAction>(
            tooltip: l.moreOptions,
            onSelected: (action) {
              switch (action) {
                case _ArchiveAction.refresh:
                  archive.refresh();
                case _ArchiveAction.tasks:
                  open(LocalTasksPage(library: library));
                case _ArchiveAction.recaps:
                  open(DailyRecapsPage(library: library));
                case _ArchiveAction.goals:
                  open(LocalGoalsPage(library: library));
                case _ArchiveAction.select:
                  setState(() => _selection = {});
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: _ArchiveAction.refresh, enabled: !archive.busy, child: Text(l.refresh)),
              if (library.tasksAvailable) PopupMenuItem(value: _ArchiveAction.tasks, child: Text(l.tasks)),
              if (library.dailyRecapsAvailable) PopupMenuItem(value: _ArchiveAction.recaps, child: Text(l.dailyRecaps)),
              if (library.goalsAvailable) PopupMenuItem(value: _ArchiveAction.goals, child: Text(l.goals)),
              if (library.folderManagementAvailable && selection == null)
                PopupMenuItem(
                  value: _ArchiveAction.select,
                  child: Text(pairedSettingsLabel(context, 'localFolderSelect')),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (library.audioDelivery)
            LocalNextCapturePanel(
              key: ValueKey(library.audioOwnerId),
              library: library,
              serverName: serverName,
              onDelivered: _archive.refreshAfterRecording,
              openServers: widget.openServers,
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: OmiSpacing.md),
              child: Wrap(
                spacing: OmiSpacing.sm,
                children: selection != null
                    ? [
                        ActionChip(
                          label: Text(l.cancel),
                          onPressed: _moving ? null : () => setState(() => _selection = null),
                        ),
                        ActionChip(
                          label: Text('${l.moveToFolder} · ${selection.length}/100'),
                          onPressed: selection.isEmpty || _moving ? null : _moveSelected,
                        ),
                      ]
                    : [
                        FilterChip(
                          label: Text(l.starred),
                          selected: archive.starredOnly,
                          onSelected: archive.busy ? null : archive.filterStarred,
                        ),
                        FilterChip(
                          key: const ValueKey('archive-category'),
                          label: Text(
                            archive.category == null
                                ? l.categories
                                : conversationCategoryLabel(context, archive.category!),
                          ),
                          selected: archive.category != null,
                          onSelected: archive.busy
                              ? null
                              : (_) async {
                                  final category = await pickConversationCategory(
                                    context,
                                    current: archive.category,
                                    filter: true,
                                  );
                                  if (mounted && identical(archive, _archive) && category != null) {
                                    await archive.filterCategory(
                                      category == allConversationCategories ? null : category,
                                    );
                                  }
                                },
                        ),
                        if (library.foldersAvailable)
                          ActionChip(
                            avatar: const Icon(Icons.folder_outlined),
                            label: Text(archive.folder?.name ?? pairedSettingsLabel(context, 'localFolders')),
                            onPressed: archive.busy
                                ? null
                                : () async {
                                    final choice = await pickLocalFolder(
                                      context,
                                      library,
                                      moving: false,
                                      onRename: archive.renameFolder,
                                      onDelete: (id) => archive.refreshAfterFolderChange(deletedId: id),
                                    );
                                    if (choice != null) await archive.filterFolder(choice.folder);
                                  },
                          ),
                      ],
              ),
            ),
          ),
          Expanded(
            child: PairedArchiveFeed(
              archive: _archive,
              errorText: pairingFailureText,
              selection: selection?.keys.toSet(),
              onOpen: selection != null
                  ? _select
                  : (id) => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RecordingPage(library: library, id: id, onEdited: archive.applyEdit),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
