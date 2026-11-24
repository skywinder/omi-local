import 'package:flutter/material.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/ui/omi_theme.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'archive.dart';
import 'capture_panel.dart';
import 'paired_library.dart';
import 'processing_page.dart';
import 'recording_page.dart';

class LocalNextApp extends StatelessWidget {
  const LocalNextApp({super.key});

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
    home: const _Pairing(),
  );
}

String failureText(BuildContext context, Object? failure) => switch (failure) {
  LibraryFailure.address => context.l10n.invalidUrlError,
  LibraryFailure.key => context.l10n.invalidKey,
  LibraryFailure.storage => context.l10n.failedToSaveCheckConnection,
  LibraryFailure.malformed || FormatException() => context.l10n.couldNotLoadPage,
  _ => context.l10n.connectionFailed,
};

class _Pairing extends StatefulWidget {
  const _Pairing();
  @override
  State<_Pairing> createState() => _PairingState();
}

class _PairingState extends State<_Pairing> {
  final address = TextEditingController();
  final keyField = TextEditingController();
  PairedLibrary? library;
  bool busy = true;
  Object? failure;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final saved = await PairedLibrary.restore();
      if (saved != null && mounted) {
        address.text = saved.origin.origin;
        _activate(saved);
      }
    } catch (_) {
      failure = LibraryFailure.storage;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _connect() async {
    if (busy) return;
    setState(() {
      busy = true;
      failure = null;
    });
    try {
      final candidate = PairedLibrary(address.text, keyField.text);
      await candidate.verify();
      try {
        await candidate.save();
      } catch (_) {
        throw LibraryFailure.storage;
      }
      if (!mounted) return;
      _activate(candidate);
      keyField.clear();
    } catch (error) {
      failure = error;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _activate(PairedLibrary current) {
    library = current;
    current.onKeyRejected = () {
      if (mounted && library == current) _endSession(rejected: true);
    };
  }

  Future<void> _disconnect() => _endSession();

  Future<void> _endSession({bool rejected = false}) async {
    if (busy) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() {
      library?.close();
      library = null;
      busy = true;
      failure = rejected ? LibraryFailure.key : null;
    });
    try {
      await PairedLibrary.forget();
    } catch (_) {
      failure = LibraryFailure.storage;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    library?.close();
    address.dispose();
    keyField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paired = library;
    if (paired != null) return LocalNextLibraryPage(key: ObjectKey(paired), library: paired, disconnect: _disconnect);
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: const Text('Omi Local Next')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: address,
              enabled: !busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(labelText: l.serverUrl, hintText: '100.64.0.1:20000'),
            ),
            TextField(
              controller: keyField,
              enabled: !busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              onSubmitted: (_) => _connect(),
              decoration: InputDecoration(labelText: l.apiKey),
            ),
            if (failure != null)
              Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(failureText(context, failure))),
            const SizedBox(height: 20),
            FilledButton(onPressed: busy ? null : _connect, child: Text(l.connect)),
            if (busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

class LocalNextLibraryPage extends StatefulWidget {
  const LocalNextLibraryPage({super.key, required this.library, required this.disconnect});
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
    return Scaffold(
      appBar: AppBar(
        title: Text(l.conversations),
        actions: [
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
          IconButton(tooltip: l.disconnect, onPressed: widget.disconnect, icon: const Icon(Icons.link_off)),
        ],
      ),
      body: Column(
        children: [
          if (library.audioDelivery) LocalNextCapturePanel(key: ValueKey(library.audioOwnerId), library: library),
          Expanded(
            child: PairedArchiveFeed(
              archive: _archive,
              errorText: failureText,
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
