import 'package:flutter/material.dart';
import 'package:omi/backend/schema/gen/conversation_wire.g.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/ui/components/omi_page_states.dart';
import 'package:omi/ui/components/omi_partial_notice.dart';
import 'package:omi/ui/format/omi_date_format.dart';
import 'package:omi/ui/omi_theme.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

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
    if (paired != null) return _LibraryPage(key: ObjectKey(paired), library: paired, disconnect: _disconnect);
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

class _LibraryPage extends StatefulWidget {
  const _LibraryPage({super.key, required this.library, required this.disconnect});
  final PairedLibrary library;
  final Future<void> Function() disconnect;
  @override
  State<_LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<_LibraryPage> {
  final rows = <GeneratedConversation>[];
  bool busy = false, more = false, partial = false;
  int offset = 0;
  Object? failure;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool append = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      failure = null;
    });
    try {
      if (!widget.library.verified) {
        await widget.library.verify();
        if (!mounted) return;
      }
      final result = await widget.library.list(append ? offset : 0);
      if (!mounted) return;
      setState(() {
        if (!append) {
          rows.clear();
          offset = 0;
          partial = false;
        }
        final seen = rows.map((c) => c.id).toSet();
        rows.addAll(result.rows.where((c) => seen.add(c.id)));
        offset += result.consumed;
        more = result.more;
        partial |= result.partial;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        failure = error;
        if (error == LibraryFailure.key) {
          rows.clear();
          offset = 0;
          more = false;
        }
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final error = failure;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.conversations),
        actions: [
          if (!widget.library.audioDelivery)
            IconButton(
              tooltip: l.processing,
              icon: const Icon(Icons.tune),
              onPressed: () {
                final client = widget.library.processingClient();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LocalNextProcessingPage(
                      client: client,
                      serverLabel: widget.library.origin.authority,
                      isRecording: () => false,
                    ),
                  ),
                );
              },
            ),
          IconButton(tooltip: l.refresh, onPressed: busy ? null : _load, icon: const Icon(Icons.refresh)),
          IconButton(tooltip: l.disconnect, onPressed: widget.disconnect, icon: const Icon(Icons.link_off)),
        ],
      ),
      body: Column(
        children: [
          if (widget.library.audioDelivery)
            LocalNextCapturePanel(key: ValueKey(widget.library.audioOwnerId), library: widget.library),
          Expanded(
            child: rows.isEmpty
                ? busy
                      ? const OmiLoadingState()
                      : error != null
                      ? OmiErrorState(message: failureText(context, error), onRetry: _load)
                      : partial
                      ? OmiErrorState(message: l.couldNotLoadPage, onRetry: _load)
                      : OmiEmptyState(icon: Icons.forum_rounded, title: l.noConversationsYet)
                : Column(
                    children: [
                      if (busy) const LinearProgressIndicator(),
                      if (partial || error != null)
                        OmiPartialNotice(
                          onRetry: _load,
                          message: error == null ? l.couldNotLoadPage : failureText(context, error),
                        ),
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: rows.length + (more ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index == rows.length) {
                                return TextButton(
                                  onPressed: busy ? null : () => _load(append: true),
                                  child: Text(l.showMore),
                                );
                              }
                              final row = rows[index];
                              return ListTile(
                                title: Text(recordingTitle(context, row)),
                                subtitle: Text(
                                  '${OmiDateFormat.of(context).dateTime((row.startedAt ?? row.createdAt).toLocal())} · ${recordingStatus(context, row)}',
                                ),
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => RecordingPage(library: widget.library, id: row.id),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
