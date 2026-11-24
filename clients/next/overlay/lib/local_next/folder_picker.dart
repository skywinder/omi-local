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
}) => showModalBottomSheet<LocalFolderChoice>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _FolderPicker(library: library, moving: moving, onRename: onRename),
);

class _FolderPicker extends StatefulWidget {
  const _FolderPicker({required this.library, required this.moving, this.onRename});
  final PairedLibrary library;
  final bool moving;
  final ValueChanged<Folder>? onRename;

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  late Future<List<Folder>> _folders = widget.library.readFolders();

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
              onPressed: _edit,
            ),
          ),
          ListTile(
            title: Text(widget.moving ? context.l10n.noFolder : pairedSettingsLabel(context, 'localAllFolders')),
            onTap: () => Navigator.of(context).pop(const LocalFolderChoice(null)),
          ),
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
                      onTap: () => Navigator.of(context).pop(LocalFolderChoice(folder)),
                      trailing: IconButton(
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
