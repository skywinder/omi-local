import 'package:flutter/material.dart';
import 'package:omi/backend/schema/person.dart';
import 'package:omi/utils/l10n_extensions.dart';

import 'paired_library.dart';
import 'recording_edit.dart';
import 'settings_labels.dart';

class SpeakerChoice {
  const SpeakerChoice({this.person, this.isUser = false, this.group = false});
  final Person? person;
  final bool isUser;
  final bool group;
}

class LocalSpeakerPicker extends StatefulWidget {
  const LocalSpeakerPicker({super.key, required this.library, required this.canGroup});
  final PairedLibrary library;
  final bool canGroup;

  @override
  State<LocalSpeakerPicker> createState() => _LocalSpeakerPickerState();
}

class _LocalSpeakerPickerState extends State<LocalSpeakerPicker> {
  late Future<List<Person>> _people = widget.library.readLocalPeople();
  bool _group = false;

  void _choose({Person? person, bool isUser = false}) =>
      Navigator.of(context).pop(SpeakerChoice(person: person, isUser: isUser, group: _group));

  Future<void> _add() => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RecordingTextEditor(
      label: pairedSettingsLabel(context, 'localSpeakerAdd'),
      initial: '',
      maxLength: 100,
      multiline: false,
      onSave: (name) async {
        await widget.library.createLocalPerson(name);
        if (mounted) {
          setState(() {
            _people = widget.library.readLocalPeople();
          });
        }
      },
    ),
  );

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: 0.72,
    child: SafeArea(
      child: Column(
        children: [
          ListTile(
            title: Text(context.l10n.identifySpeaker),
            trailing: IconButton(
              tooltip: pairedSettingsLabel(context, 'localSpeakerAdd'),
              icon: const Icon(Icons.person_add_alt_1_outlined),
              onPressed: _add,
            ),
          ),
          if (widget.canGroup)
            SwitchListTile(
              value: _group,
              title: Text(pairedSettingsLabel(context, 'localSpeakerGroup')),
              onChanged: (value) => setState(() => _group = value),
            ),
          Expanded(
            child: FutureBuilder<List<Person>>(
              future: _people,
              builder: (context, snapshot) => ListView(
                children: [
                  ListTile(
                    title: Text(pairedSettingsLabel(context, 'localSpeakerSelf')),
                    onTap: () => _choose(isUser: true),
                  ),
                  ListTile(title: Text(pairedSettingsLabel(context, 'localSpeakerClear')), onTap: () => _choose()),
                  if (snapshot.connectionState != ConnectionState.done) const LinearProgressIndicator(),
                  if (snapshot.hasError)
                    TextButton(
                      onPressed: () => setState(() {
                        _people = widget.library.readLocalPeople();
                      }),
                      child: Text(context.l10n.retry),
                    ),
                  for (final person in snapshot.data ?? const <Person>[])
                    ListTile(
                      title: Text(person.name),
                      onTap: () => _choose(person: person),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
