import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:omi/pages/settings/local_runtime_status_card.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/services/auth/local_mac_session.dart';
import 'package:omi/services/local_runtime_status.dart';
import 'package:omi/services/connectivity_service.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/enums.dart';

class LocalMacPage extends StatefulWidget {
  const LocalMacPage({super.key, this.session, this.stopRecording, this.refreshConnection, this.statusFetcher});
  final LocalMacSession? session;
  final Future<void> Function()? stopRecording;
  final Future<void> Function()? refreshConnection;
  final Future<LocalRuntimeStatus> Function()? statusFetcher;
  @override
  State<LocalMacPage> createState() => _LocalMacPageState();
}

class _LocalMacPageState extends State<LocalMacPage> with WidgetsBindingObserver {
  LocalMacSession get _session => widget.session ?? LocalMacSession.instance;
  late final _address = TextEditingController(text: _session.address);
  final _key = TextEditingController();
  bool _busy = true;
  bool _showKey = false;
  String? _error;
  Future<void> _pendingSave = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final saved = await _session.readSettings();
      if (!mounted) return;
      _address.text = saved.address;
      _key.text = saved.key;
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.localMacConnectionFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _showKey) {
      setState(() => _showKey = false);
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _showConnectionDetails() async {
    setState(() => _showKey = true);
    await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: Text(context.l10n.localMacTitle),
              content: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(context.l10n.localMacAddress),
                  const SizedBox(height: 8),
                  SelectableText(_address.text.trim(), key: const ValueKey('local-mac-visible-url')),
                  const SizedBox(height: 20),
                  Text(context.l10n.localMacAccessKey),
                  const SizedBox(height: 8),
                  SelectableText(_key.text,
                      key: const ValueKey('local-mac-visible-key'), style: const TextStyle(fontFamily: 'monospace')),
                ]),
              ),
              actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(context.l10n.close))],
            ));
    if (mounted) setState(() => _showKey = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _address.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _queueSave();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.saved)));
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.failedToSaveCheckConnection);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _queueSave() {
    final address = _address.text;
    final key = _key.text;
    final save = _pendingSave.then((_) => _session.saveSettings(address, key));
    // Each caller reports its own failure; keep later edits writable after an error.
    _pendingSave = save.onError((_, __) {});
    return save;
  }

  Future<void> _autosave() async {
    try {
      await _queueSave();
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.failedToSaveCheckConnection);
    }
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _queueSave();
      if (!mounted) return;
      if (widget.stopRecording != null) {
        await widget.stopRecording!();
      } else {
        final capture = context.read<CaptureProvider>();
        if (capture.recordingState != RecordingState.stop || capture.havingRecordingDevice) {
          await capture.stopStreamRecording(reason: 'local_mac_changed');
          await capture.stopStreamDeviceRecording(cleanDevice: true);
        }
      }
      await _session.connect(_address.text.trim(), _key.text.trim());
      await (widget.refreshConnection ?? ConnectivityService().refreshLocalTunnel)();
      _key.clear();
      if (mounted) Navigator.of(context).pop(true);
    } on LocalMacUnauthorized {
      if (mounted) setState(() => _error = context.l10n.localMacKeyRejected);
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.localMacConnectionFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.l10n.localMacTitle)),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          Text(context.l10n.localMacHelp),
          const SizedBox(height: 16),
          LocalRuntimeStatusCard(session: _session, fetcher: widget.statusFetcher),
          const SizedBox(height: 24),
          TextField(
              key: const ValueKey('local-mac-address'),
              controller: _address,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => _autosave(),
              decoration: InputDecoration(labelText: context.l10n.localMacAddress, hintText: 'https://')),
          const SizedBox(height: 16),
          TextField(
              key: const ValueKey('local-mac-key'),
              controller: _key,
              enabled: !_busy,
              obscureText: !_showKey,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: 43,
              maxLengthEnforcement: MaxLengthEnforcement.none,
              inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
              onChanged: (_) => _autosave(),
              decoration: InputDecoration(
                  labelText: context.l10n.localMacAccessKey,
                  suffixIcon: Semantics(
                      toggled: _showKey,
                      child: IconButton(
                          key: const ValueKey('local-mac-show-key'),
                          tooltip: context.l10n.localMacAccessKey,
                          onPressed: _busy ? null : _showConnectionDetails,
                          icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility))))),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!)),
          const SizedBox(height: 24),
          OutlinedButton(
              key: const ValueKey('local-mac-save'),
              onPressed: _busy ? null : _saveSettings,
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
              child: Text(context.l10n.saveCredentials)),
          const SizedBox(height: 12),
          FilledButton(
              key: const ValueKey('local-mac-connect'),
              onPressed: _busy ? null : _connect,
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator())
                  : Text(context.l10n.localMacConnect)),
        ]),
      );
}
