import 'package:flutter/material.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/ui/omi_theme.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'archive.dart';
import 'archive_search_page.dart';
import 'capture_panel.dart';
import 'paired_library.dart';
import 'processing_page.dart';
import 'recording_page.dart';
import 'server_catalog.dart';
import 'server_session.dart';
import 'server_status_page.dart';
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
    theme: buildOmiTheme(brightness: Brightness.light),
    darkTheme: buildOmiTheme(),
    builder: (context, child) {
      OmiColors.active = OmiColors.forBrightness(Theme.of(context).brightness);
      return child!;
    },
    home: _Pairing(session: session),
  );
}

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

  Future<void> _disconnect() async {
    await session.disconnect();
    if (mounted && session.active != null && session.failure != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(pairingFailureText(context, session.failure))));
    }
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
      disconnect: _disconnect,
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
    required this.disconnect,
    this.openServers,
    this.serverName,
    this.pairingBusy = false,
  });
  final VoidCallback? openServers;
  final String? serverName;
  final bool pairingBusy;
  final PairedLibrary library;
  final Future<void> Function() disconnect;
  @override
  State<LocalNextLibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LocalNextLibraryPage> {
  late PairedArchiveProvider _archive;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _archive = PairedArchiveProvider(widget.library)..addListener(_changed);
    _archive.refresh();
  }

  void _changed() => setState(() {});

  @override
  void didUpdateWidget(LocalNextLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
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
    final serverName = widget.serverName ?? library.origin.authority;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.conversations),
            if (widget.serverName case final name?)
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
        actions: [
          IconButton(
            tooltip: l.searchConversations,
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => ArchiveSearchPageView(library: library))),
          ),
          IconButton(
            tooltip: pairedSettingsLabel(context, 'serverStatus'),
            icon: const Icon(Icons.monitor_heart_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => NextServerStatusPage(library: library, serverName: serverName),
              ),
            ),
          ),
          if (!library.audioDelivery)
            IconButton(
              tooltip: l.processing,
              icon: const Icon(Icons.tune),
              onPressed: () {
                final client = library.processingClient();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LocalNextProcessingPage(
                      client: client,
                      serverLabel: library.origin.authority,
                      isRecording: () => false,
                    ),
                  ),
                );
              },
            ),
          IconButton(
            tooltip: l.refresh,
            onPressed: _archive.busy ? null : _archive.refresh,
            icon: const Icon(Icons.refresh),
          ),
          if (widget.openServers != null)
            IconButton(
              tooltip: pairedSettingsLabel(context, 'localMacServers'),
              icon: const Icon(Icons.dns_outlined),
              onPressed: widget.pairingBusy ? null : widget.openServers,
            ),
          IconButton(
            tooltip: l.disconnect,
            onPressed: widget.pairingBusy ? null : widget.disconnect,
            icon: const Icon(Icons.link_off),
          ),
        ],
      ),
      body: Column(
        children: [
          if (library.audioDelivery) LocalNextCapturePanel(key: ValueKey(library.audioOwnerId), library: library),
          Expanded(
            child: PairedArchiveFeed(
              archive: _archive,
              errorText: pairingFailureText,
              onOpen: (id) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RecordingPage(library: library, id: id),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
