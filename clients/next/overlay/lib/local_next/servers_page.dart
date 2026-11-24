import 'package:flutter/material.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'paired_library.dart';
import 'server_catalog.dart';
import 'server_session.dart';
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
  bool _draft = false, _saved = false;

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

  void _choose(NextSavedServer? entry) {
    widget.session.clearFailure();
    setState(() {
      _draft = entry == null;
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

  Future<void> _connect() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await widget.session.connect(id: _selection?.id, name: _name.text, address: _address.text, key: _keyField.text);
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
            if (session.servers.isNotEmpty) ...[
              if (!widget.manager) Text(title, style: Theme.of(context).textTheme.titleMedium),
              for (final entry in session.servers)
                ListTile(
                  key: ValueKey('server-entry-${entry.id}'),
                  selected: selection?.id == entry.id,
                  enabled: !session.busy,
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(entry.name),
                  subtitle: Text(entry.address),
                  trailing: entry.id == session.activeId ? Text(l.active) : null,
                  onTap: () => _choose(entry),
                ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('server-add'),
                  icon: const Icon(Icons.add),
                  label: Text(l.add),
                  onPressed: session.busy ? null : () => _choose(null),
                ),
              ),
            ],
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
                FilledButton(
                  key: const ValueKey('server-connect'),
                  onPressed: session.busy ? null : _connect,
                  child: Text(l.connect),
                ),
                OutlinedButton(
                  key: const ValueKey('server-save'),
                  onPressed: session.busy ? null : _save,
                  child: Text(l.save),
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
