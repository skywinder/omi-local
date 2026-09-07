import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/services/auth/local_mac_session.dart';
import 'package:omi/services/connectivity_service.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/enums.dart';

class LocalMacPage extends StatefulWidget {
  const LocalMacPage({super.key, this.session, this.stopRecording, this.refreshConnection});
  final LocalMacSession? session;
  final Future<void> Function()? stopRecording;
  final Future<void> Function()? refreshConnection;
  @override
  State<LocalMacPage> createState() => _LocalMacPageState();
}

class _LocalMacPageState extends State<LocalMacPage> {
  LocalMacSession get _session => widget.session ?? LocalMacSession.instance;
  late final _address = TextEditingController(text: _session.address);
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
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
          const SizedBox(height: 24),
          TextField(
              key: const ValueKey('local-mac-address'),
              controller: _address,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(labelText: context.l10n.localMacAddress, hintText: 'https://')),
          const SizedBox(height: 16),
          TextField(
              key: const ValueKey('local-mac-key'),
              controller: _key,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: context.l10n.localMacAccessKey)),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!)),
          const SizedBox(height: 24),
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
