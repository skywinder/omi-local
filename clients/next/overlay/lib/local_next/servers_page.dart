import 'package:flutter/material.dart';
import 'package:omi/ui/omi_tokens.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'paired_library.dart';
import 'processing_page.dart';
import 'server_catalog.dart';
import 'server_session.dart';
import 'server_status_page.dart';
import 'settings_labels.dart';

String pairingFailureText(BuildContext context, Object? failure) => switch (failure) {
  ServerSelectionFailure.recording => pairedSettingsLabel(context, 'serverCaptureBusy'),
  ServerSelectionFailure.retained => pairedSettingsLabel(context, 'serverAudioRetained'),
  ServerSelectionFailure.activeEdit => pairedSettingsLabel(context, 'serverActiveEdit'),
  LibraryFailure.address => context.l10n.invalidUrlError,
  LibraryFailure.key => context.l10n.invalidKey,
  LibraryFailure.storage => context.l10n.failedToSaveCheckConnection,
  LibraryFailure.malformed || FormatException() => context.l10n.couldNotLoadPage,
  _ => context.l10n.connectionFailed,
};

enum _ServerAction { edit, reconnect, disconnect }

class NextServersPage extends StatefulWidget {
  const NextServersPage({super.key, required this.session, this.manager = false});
  final NextServerSession session;
  final bool manager;
  @override
  State<NextServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<NextServersPage> {
  final _name = TextEditingController(), _address = TextEditingController(), _keyField = TextEditingController();
  NextSavedServer? _selection;
  bool _draft = false, _editing = false, _saved = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    _sync();
  }

  void _sync() {
    final entries = widget.session.servers;
    if (_selection != null && !entries.any((e) => e.id == _selection!.id)) _select(null);
    if (!_draft && _selection == null && entries.isNotEmpty) {
      _select(entries.where((e) => e.id == widget.session.activeId).firstOrNull ?? entries.first);
    }
  }

  void _changed() => setState(_sync);

  void _select(NextSavedServer? entry) {
    _selection = entry;
    _name.text = entry?.name ?? '';
    _address.text = entry?.address ?? '';
    _keyField.clear();
    _saved = false;
  }

  void _choose(NextSavedServer? entry, {bool edit = false}) {
    widget.session.clearFailure();
    setState(() {
      _draft = entry == null;
      _editing = edit;
      _select(entry);
    });
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    _name.dispose();
    _address.dispose();
    _keyField.dispose();
    super.dispose();
  }

  Future<void> _connect({NextSavedServer? reconnect}) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final selected = reconnect ?? _selection;
    final editing = reconnect == null && (_editing || selected == null);
    await widget.session.connect(
      id: selected?.id,
      name: editing ? _name.text : selected!.name,
      address: editing ? _address.text : selected!.address,
      key: editing ? _keyField.text : '',
    );
    if (!mounted || widget.session.failure != null || widget.session.active == null) return;
    _keyField.clear();
    if (widget.manager && ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context);
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final saved = await widget.session.save(
      id: _selection?.id,
      name: _name.text,
      address: _address.text,
      key: _keyField.text,
    );
    if (!mounted || saved == null) return;
    setState(() {
      _select(saved);
      _draft = false;
      _editing = false;
      _saved = true;
    });
  }

  Future<void> _remove(NextSavedServer entry) async {
    final l = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.delete),
        content: Text(l.deleteItemConfirmation(entry.name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l.delete)),
        ],
      ),
    );
    if (mounted && confirmed == true) await widget.session.remove(entry);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final session = widget.session;
    final selection = _selection;
    final title = pairedSettingsLabel(context, 'localMacServers');
    final active = session.active;
    final activeEntry = session.servers.where((entry) => entry.id == session.activeId).firstOrNull;
    final showForm = _editing || session.servers.isEmpty;
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    void edited(String _) {
      session.clearFailure();
      if (_saved) setState(() => _saved = false);
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.manager ? title : 'Omi Local Next')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            if (active != null && activeEntry != null)
              Card(
                color: OmiColors.surface1,
                margin: const EdgeInsets.only(bottom: OmiSpacing.md),
                child: Column(
                  children: [
                    ListTile(
                      key: ValueKey('server-entry-${activeEntry.id}'),
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(activeEntry.name),
                      subtitle: Text(l.active),
                      trailing: PopupMenuButton<_ServerAction>(
                        tooltip: l.moreOptions,
                        enabled: !session.busy,
                        onSelected: (action) {
                          switch (action) {
                            case _ServerAction.edit:
                              _choose(activeEntry, edit: true);
                            case _ServerAction.reconnect:
                              _connect(reconnect: activeEntry);
                            case _ServerAction.disconnect:
                              session.disconnect();
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(value: _ServerAction.edit, child: Text(l.edit)),
                          PopupMenuItem(value: _ServerAction.reconnect, child: Text(l.reconnect)),
                          PopupMenuItem(
                            key: const ValueKey('server-disconnect'),
                            value: _ServerAction.disconnect,
                            child: Text(l.disconnect),
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.monitor_heart_outlined),
                      title: Text(pairedSettingsLabel(context, 'serverStatus')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: session.busy
                          ? null
                          : () => open(NextServerStatusPage(library: active, serverName: activeEntry.name)),
                    ),
                    ListTile(
                      leading: const Icon(Icons.tune),
                      title: Text(l.processing),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: session.busy
                          ? null
                          : () => open(
                              LocalNextProcessingPage(
                                client: active.processingClient(
                                  permitsActivation: () =>
                                      active.ownerChange.permitsCapture && !active.ownerChange.captureBusy,
                                ),
                                serverLabel: activeEntry.name,
                                isRecording: () => active.ownerChange.captureBusy,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            for (final entry in session.servers.where((entry) => entry.id != session.activeId))
              ListTile(
                key: ValueKey('server-entry-${entry.id}'),
                selected: selection?.id == entry.id,
                selectedTileColor: OmiColors.surface2,
                enabled: !session.busy,
                leading: const Icon(Icons.dns_outlined),
                title: Text(entry.name),
                trailing: selection?.id == entry.id ? const Icon(Icons.check) : null,
                onTap: () => _choose(entry),
              ),
            if (session.servers.isNotEmpty)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('server-add'),
                  icon: const Icon(Icons.add),
                  label: Text(l.add),
                  onPressed: session.busy ? null : () => _choose(null, edit: true),
                ),
              ),
            if (showForm) ...[
              TextField(
                key: const ValueKey('server-address'),
                controller: _address,
                enabled: !session.busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: l.serverUrl, hintText: '100.64.0.1:20000'),
                onChanged: edited,
              ),
              TextField(
                key: const ValueKey('server-name'),
                controller: _name,
                enabled: !session.busy,
                maxLength: 80,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: l.name, counterText: ''),
                onChanged: edited,
              ),
              TextField(
                key: const ValueKey('server-key'),
                controller: _keyField,
                enabled: !session.busy,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(labelText: l.apiKey),
                onChanged: edited,
                onSubmitted: (_) => _connect(),
              ),
              if (selection != null) Text(pairedSettingsLabel(context, 'serverKeyHelp')),
            ],
            if (session.failure != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(pairingFailureText(context, session.failure)),
              ),
            if (_saved && session.failure == null) Text(l.saved),
            if (session.busy) const LinearProgressIndicator(),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                if (showForm || (selection != null && selection.id != session.activeId))
                  FilledButton(
                    key: const ValueKey('server-connect'),
                    onPressed: session.busy ? null : _connect,
                    child: Text(l.connect),
                  ),
                if (showForm)
                  OutlinedButton(
                    key: const ValueKey('server-save'),
                    onPressed: session.busy ? null : _save,
                    child: Text(l.save),
                  ),
                if (!showForm && selection != null && selection.id != session.activeId)
                  TextButton(
                    key: const ValueKey('server-edit'),
                    onPressed: session.busy ? null : () => _choose(selection, edit: true),
                    child: Text(l.edit),
                  ),
                if (showForm && session.servers.isNotEmpty)
                  TextButton(
                    onPressed: session.busy ? null : () => _choose(selection ?? activeEntry),
                    child: Text(l.cancel),
                  ),
                if (selection != null && selection.id != session.activeId)
                  TextButton(
                    key: const ValueKey('server-delete'),
                    onPressed: session.busy ? null : () => _remove(selection),
                    child: Text(l.delete),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
