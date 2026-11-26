import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/ui/omi_theme.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'archive.dart';
import 'category_backfill.dart';
import 'server_connection_indicator.dart';
import 'conversation_categories.dart';
import 'daily_recaps_page.dart';
import 'folder_picker.dart';
import 'local_goals_page.dart';
import 'local_tasks_page.dart';
import 'recording_edit.dart';
import 'archive_search_page.dart';
import 'capture_panel.dart';
import 'cv1_capture.dart';
import 'device_diagnostics_page.dart';
import 'home_shortcuts.dart';
import 'offline_recordings_page.dart';
import 'task_editor.dart';
import 'task_reminder_sync.dart';
import 'paired_library.dart';
import 'recording_page.dart';
import 'server_catalog.dart';
import 'server_session.dart';
import 'servers_page.dart';
import 'settings_labels.dart';

class LocalNextApp extends StatelessWidget {
  const LocalNextApp({super.key, this.session, this.shortcuts});
  final NextServerSession? session;
  final NextHomeShortcuts? shortcuts;

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
    home: _Pairing(session: session, shortcuts: shortcuts),
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

enum _ArchiveAction { refresh, offline, tasks, recaps, goals, select }

enum _ArchiveSelectionActivity { move, classify }

class _Pairing extends StatefulWidget {
  const _Pairing({this.session, this.shortcuts});
  final NextServerSession? session;
  final NextHomeShortcuts? shortcuts;
  @override
  State<_Pairing> createState() => _PairingState();
}

class _PairingState extends State<_Pairing> {
  late final NextServerSession session;
  final _reminders = TaskReminderSync();
  PairedLibrary? _shown;

  @override
  void initState() {
    super.initState();
    session = widget.session ?? NextServerSession(NextServerCatalog());
    _shown = session.active;
    _reminders.bind(_shown);
    session.addListener(_changed);
    session.initialize();
  }

  void _changed() {
    if (_shown != session.active) {
      _shown = session.active;
      _reminders.bind(_shown);
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    setState(() {});
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    _reminders.dispose();
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
      shortcuts: widget.shortcuts,
      library: active,
      reminders: _reminders,
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
    this.shortcuts,
    this.reminders,
  });
  final VoidCallback? openServers;
  final String? serverName;
  final bool pairingBusy;
  final NextHomeShortcuts? shortcuts;
  final TaskReminderSync? reminders;
  final PairedLibrary library;
  @override
  State<LocalNextLibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LocalNextLibraryPage> with WidgetsBindingObserver {
  var _panel = GlobalKey<NextCapturePanelState>();
  Timer? _heartbeat;
  void _watchServer() {
    _heartbeat?.cancel();
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    final paired = widget.library;
    Future<void> check() async {
      try {
        await paired.verify();
      } catch (_) {
        return; // The profile check publishes its own connection status.
      }
      if (!mounted || paired != widget.library) return;
      if (widget.reminders case final reminders?) {
        final title = pairedSettingsLabel(context, 'localReminderTitle');
        unawaited(reminders.sync(paired, title));
      }
      if (_canRefreshRecordings()) await _archive.recoverAfterServerCheck();
    }

    unawaited(check());
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(check()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _watchServer();

  late PairedArchiveProvider _archive;
  Map<String, String?>? _selection;
  _ArchiveSelectionActivity? _selectionActivity;
  bool get _selectionBusy => _selectionActivity != null;

  Future<void> _moveSelected() async {
    final library = widget.library;
    final archive = _archive;
    final selected = _selection;
    if (_selectionBusy || selected == null || selected.isEmpty) return;
    setState(() => _selectionActivity = _ArchiveSelectionActivity.move);
    try {
      final destination = await pickLocalFolder(context, library, moving: true);
      if (!mounted || widget.library != library || destination == null) return;
      await library.bulkMoveFolders(selected, destination.folder?.id);
      if (!mounted || widget.library != library) return;
      setState(() => _selection = null);
      archive.refreshAfterArchiveEdit();
    } catch (error) {
      if (mounted && widget.library == library) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(recordingEditError(context, error))));
      }
    } finally {
      if (mounted && widget.library == library) setState(() => _selectionActivity = null);
    }
  }

  Future<void> _classifySelected() async {
    final library = widget.library;
    final selected = _selection;
    if (_selectionBusy || selected == null || selected.isEmpty || selected.length > 8) return;
    setState(() => _selectionActivity = _ArchiveSelectionActivity.classify);
    try {
      final submitted = await runCategoryBackfill(context, library, selected.keys.toList());
      if (mounted && widget.library == library && submitted) {
        setState(() => _selection = null);
        _archive.refreshAfterArchiveEdit();
      }
    } finally {
      if (mounted && widget.library == library) setState(() => _selectionActivity = null);
    }
  }

  void _select(String id) {
    final selection = _selection;
    final row = _archive.rowById(id);
    if (_selectionBusy ||
        selection == null ||
        row == null ||
        row.status != ConversationStatus.completed ||
        row.isLocked) {
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
    WidgetsBinding.instance.addObserver(this);
    widget.shortcuts?.addListener(_queueShortcuts);
    _attach();
  }

  NextCaptureInputs? _inputs;
  bool _shortcutQueued = false;

  void _bindInputs(NextCaptureInputs next) {
    _inputs?.cv1.removeListener(_queueShortcuts);
    setState(() => _inputs = next);
    next.cv1.addListener(_queueShortcuts);
    _queueShortcuts();
  }

  void _queueShortcuts() {
    if (widget.shortcuts == null || _shortcutQueued || !mounted) return;
    _shortcutQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _shortcutQueued = false;
      if (mounted) _syncShortcuts();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _syncShortcuts() {
    final actions = widget.shortcuts!;
    final library = widget.library;
    final inputs = _inputs;
    if (widget.pairingBusy || (!library.verified && _archive.failure == null)) return;
    if (library.audioDelivery && inputs == null) return;
    final l = context.l10n;
    final labels = {
      if (inputs != null) NextHomeAction.device: l.deviceSettings,
      if (library.tasksAvailable) NextHomeAction.task: l.addTask,
      if (inputs?.cv1.intent == Cv1CaptureIntent.recording) NextHomeAction.mute: l.mute,
      if (inputs?.cv1.intent == Cv1CaptureIntent.muted) NextHomeAction.unmute: l.unmute,
    };
    actions.publish(library.audioOwnerId, labels);
    switch (actions.take(library.audioOwnerId, labels.keys.toSet())) {
      case NextHomeAction.device:
        unawaited(showNextDevices(context, inputs!, library: library));
      case NextHomeAction.task:
        unawaited(createLocalTask(context, library));
      case NextHomeAction.mute || NextHomeAction.unmute:
        inputs!.cv1.toggleMute();
      case null:
        break;
    }
  }

  void _attach() {
    _archive = PairedArchiveProvider(widget.library, canRefreshRecordings: _canRefreshRecordings)
      ..addListener(_changed);
    _archive.refresh();
    _watchServer();
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
      _inputs?.cv1.removeListener(_queueShortcuts);
      _inputs = null;
      _panel = GlobalKey<NextCapturePanelState>();
      _selection = null;
      _selectionActivity = null;
      _archive.dispose();
      _attach();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat?.cancel();
    widget.shortcuts?.removeListener(_queueShortcuts);
    _inputs?.cv1.removeListener(_queueShortcuts);
    widget.shortcuts?.publish('', {});
    _archive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final library = widget.library;
    _queueShortcuts();
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
                Cv1HeaderTitle(
                  title: l.conversations,
                  link: _inputs?.connection,
                  openDevices: _inputs == null
                      ? null
                      : () => unawaited(showNextDevices(context, _inputs!, library: library)),
                ),
                if (widget.openServers != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: NextServerIndicator(library: library, name: serverName),
                      ),
                      const Icon(Icons.expand_more, size: 16),
                    ],
                  ),
              ],
            ),
          ),
        ),
        actions: [
          if (library.audioDelivery)
            IconButton(
              key: const ValueKey('next-mobile-settings'),
              tooltip: pairedSettingsLabel(context, 'nextMobileSettings'),
              icon: const Icon(Icons.settings_outlined),
              onPressed: _inputs == null ? null : () => _panel.currentState?.openSettings(),
            ),
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
                case _ArchiveAction.offline:
                  open(OfflineRecordingsPage(library: library));
                case _ArchiveAction.tasks:
                  open(LocalTasksPage(library: library, reminders: widget.reminders));
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
              PopupMenuItem(
                value: _ArchiveAction.offline,
                child: Text(pairedSettingsLabel(context, 'nextOfflineRecordings')),
              ),
              if (library.tasksAvailable) PopupMenuItem(value: _ArchiveAction.tasks, child: Text(l.tasks)),
              if (library.dailyRecapsAvailable) PopupMenuItem(value: _ArchiveAction.recaps, child: Text(l.dailyRecaps)),
              if (library.goalsAvailable) PopupMenuItem(value: _ArchiveAction.goals, child: Text(l.goals)),
              if ((library.folderManagementAvailable || library.categoryBackfill) && selection == null)
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
              key: _panel,
              library: library,
              serverName: serverName,
              onDelivered: _archive.refreshAfterRecording,
              onInputsReady: _bindInputs,
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
                          onPressed: _selectionBusy ? null : () => setState(() => _selection = null),
                        ),
                        if (library.folderManagementAvailable)
                          ActionChip(
                            label: Text('${l.moveToFolder} · ${selection.length}/100'),
                            onPressed: selection.isEmpty || _selectionBusy ? null : _moveSelected,
                          ),
                        if (library.categoryBackfill)
                          ActionChip(
                            label: Text(
                              '${pairedSettingsLabel(context, 'categoryBackfillAction')} · ${selection.length}/8',
                            ),
                            onPressed: selection.isEmpty || selection.length > 8 || _selectionBusy
                                ? null
                                : _classifySelected,
                          ),
                      ]
                    : [
                        if (library.recordingArchive)
                          FilterChip(
                            key: const ValueKey('archive-archived'),
                            label: Text(pairedSettingsLabel(context, 'recordingArchive')),
                            selected: archive.archivedOnly,
                            onSelected: archive.busy ? null : archive.filterArchived,
                          ),
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
                                      onDelete: (id) => archive.refreshAfterArchiveEdit(deletedFolderId: id),
                                    );
                                    if (choice != null) await archive.filterFolder(choice.folder);
                                  },
                          ),
                      ],
              ),
            ),
          ),
          if (_selectionActivity == _ArchiveSelectionActivity.classify && selection != null)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: PairedArchiveFeed(
              archive: _archive,
              errorText: pairingFailureText,
              selection: selection?.keys.toSet(),
              onOpen: selection != null
                  ? _select
                  : (id) => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RecordingPage(
                          library: library,
                          id: id,
                          fromSavedRecording: switch (archive.rowById(id)) {
                            final row? => canFollowSavedRecording(row),
                            null => false,
                          },
                          onEdited: archive.applyEdit,
                          onPublished: archive.replacePending,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
