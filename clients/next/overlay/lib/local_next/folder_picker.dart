import 'package:flutter/material.dart';
import 'package:omi/backend/schema/folder.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'paired_library.dart';
import 'recording_edit.dart';
import 'settings_labels.dart';

class LocalFolderChoice {
  const LocalFolderChoice(this.folder);
  final Folder? folder;
}

Future<LocalFolderChoice?> pickLocalFolder(
  BuildContext context,
  PairedLibrary library, {
  required bool moving,
  ValueChanged<Folder>? onRename,
  ValueChanged<String>? onDelete,
}) => showModalBottomSheet<LocalFolderChoice>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _FolderPicker(library: library, moving: moving, onRename: onRename, onDelete: onDelete),
);

class _FolderPicker extends StatefulWidget {
  const _FolderPicker({required this.library, required this.moving, this.onRename, this.onDelete});
  final PairedLibrary library;
  final bool moving;
  final ValueChanged<Folder>? onRename;
  final ValueChanged<String>? onDelete;

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  late Future<List<Folder>> _folders = widget.library.readFolders();
  bool _busy = false;
  Object? _error;

  Future<void> _change(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) {
        setState(() {
          _folders = widget.library.readFolders();
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          if (error == RecordingEditFailure.conflict) _folders = widget.library.readFolders();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reorder(List<Folder> rows, int from, int to) {
    final expected = rows.map((folder) => folder.id).toList();
    final ordered = [...expected];
    ordered.insert(to, ordered.removeAt(from));
    return _change(() => widget.library.reorderFolders(expected, ordered));
  }

  Future<void> _delete(Folder folder) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(folder.name),
        content: Text(pairedSettingsLabel(context, 'localFolderDeleteConfirm')),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.l10n.cancel)),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(context.l10n.delete)),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    await _change(() async {
      await widget.library.deleteFolder(folder.id);
      if (mounted) widget.onDelete?.call(folder.id);
    });
  }

  Future<void> _edit([Folder? folder]) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RecordingTextEditor(
      label: pairedSettingsLabel(context, folder == null ? 'localFolderCreate' : 'localFolderRename'),
      initial: folder?.name ?? '',
      maxLength: 100,
      multiline: false,
      onSave: (name) async {
        final saved = await widget.library.saveFolder(name, id: folder?.id);
        if (!mounted) return;
        if (folder != null) widget.onRename?.call(saved);
        setState(() {
          _folders = widget.library.readFolders();
        });
      },
    ),
  );

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: 0.65,
    child: SafeArea(
      child: Column(
        children: [
          ListTile(
            title: Text(widget.moving ? context.l10n.moveToFolder : pairedSettingsLabel(context, 'localFolders')),
            trailing: IconButton(
              tooltip: pairedSettingsLabel(context, 'localFolderCreate'),
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: _busy ? null : _edit,
            ),
          ),
          ListTile(
            title: Text(widget.moving ? context.l10n.noFolder : pairedSettingsLabel(context, 'localAllFolders')),
            onTap: _busy ? null : () => Navigator.of(context).pop(const LocalFolderChoice(null)),
          ),
          if (_error != null) ListTile(title: Text(recordingEditError(context, _error!))),
          Expanded(
            child: FutureBuilder<List<Folder>>(
              future: _folders,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: TextButton(
                      onPressed: () => setState(() {
                        _folders = widget.library.readFolders();
                      }),
                      child: Text(context.l10n.retry),
                    ),
                  );
                }
                final rows = snapshot.data ?? const [];
                return ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final folder = rows[index];
                    return ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(folder.name),
                      onTap: _busy ? null : () => Navigator.of(context).pop(LocalFolderChoice(folder)),
                      trailing: widget.library.folderManagementAvailable && !widget.moving
                          ? PopupMenuButton<_FolderAction>(
                              enabled: !_busy,
                              onSelected: (action) => switch (action) {
                                _FolderAction.rename => _edit(folder),
                                _FolderAction.up => _reorder(rows, index, index - 1),
                                _FolderAction.down => _reorder(rows, index, index + 1),
                                _FolderAction.delete => _delete(folder),
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: _FolderAction.rename,
                                  child: Text(pairedSettingsLabel(context, 'localFolderRename')),
                                ),
                                if (index > 0)
                                  PopupMenuItem(
                                    value: _FolderAction.up,
                                    child: Text(pairedSettingsLabel(context, 'localFolderUp')),
                                  ),
                                if (index + 1 < rows.length)
                                  PopupMenuItem(
                                    value: _FolderAction.down,
                                    child: Text(pairedSettingsLabel(context, 'localFolderDown')),
                                  ),
                                if (!folder.isSystem)
                                  PopupMenuItem(value: _FolderAction.delete, child: Text(context.l10n.delete)),
                              ],
                            )
                          : IconButton(
                              tooltip: pairedSettingsLabel(context, 'localFolderRename'),
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _edit(folder),
                            ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

enum _FolderAction { rename, up, down, delete }
