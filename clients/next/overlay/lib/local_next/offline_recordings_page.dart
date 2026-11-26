import 'package:flutter/material.dart';
import 'package:omi/ui/components/omi_page_states.dart';

import 'offline_recordings.dart';
import 'paired_library.dart';
import 'recording_page.dart';
import 'settings_labels.dart';

class OfflineRecordingsPage extends StatefulWidget {
  const OfflineRecordingsPage({super.key, required this.library});

  final PairedLibrary library;

  @override
  State<OfflineRecordingsPage> createState() => _OfflineRecordingsPageState();
}

class _OfflineRecordingsPageState extends State<OfflineRecordingsPage> {
  late Future<List<OfflineRecording>> _downloaded = _list();
  String? _removing;

  Future<List<OfflineRecording>> _list() async {
    if (!widget.library.canOpenOffline) throw LibraryFailure.key;
    final results = await widget.library.offlineRecordings.list();
    if (!widget.library.canOpenOffline) throw LibraryFailure.key;
    return results;
  }

  void _reload() => setState(() {
    _downloaded = _list();
  });

  Future<void> _remove(OfflineRecording item) async {
    setState(() => _removing = item.card.id);
    try {
      await widget.library.offlineRecordings.remove(item.card.id);
      if (mounted) _reload();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(pairedSettingsLabel(context, 'nextOfflineStorageFailed'))));
      }
    } finally {
      if (mounted) setState(() => _removing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    String text(String key) => pairedSettingsLabel(context, key);
    return Scaffold(
      appBar: AppBar(title: Text(text('nextOfflineRecordings'))),
      body: FutureBuilder<List<OfflineRecording>>(
        future: _downloaded,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const OmiLoadingState();
          final rows = snapshot.data;
          if (rows == null) return OmiErrorState(message: text('nextOfflineStorageFailed'), onRetry: _reload);
          if (rows.isEmpty) return Center(child: Text(text('nextOfflineEmpty'), textAlign: TextAlign.center));
          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final item = rows[index];
              final card = item.card;
              final date = MaterialLocalizations.of(context).formatCompactDate(card.createdAt.toLocal());
              final size = text(
                'nextOfflineSize',
              ).replaceAll('{size}', (item.bytes / (1024 * 1024)).toStringAsFixed(1));
              return ListTile(
                key: ValueKey(card.id),
                title: Text(recordingTitle(context, card)),
                subtitle: Text('$date · $size'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: text('nextOfflineRemove'),
                  onPressed: _removing != null ? null : () => _remove(item),
                ),
                onTap: _removing != null
                    ? null
                    : () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => RecordingPage(library: widget.library, id: card.id, offlineOnly: true),
                        ),
                      ),
              );
            },
          );
        },
      ),
    );
  }
}
