import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/person.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/paired_library.dart';
import 'package:omi/local_next/recording_edit.dart';
import 'package:omi/local_next/recording_page.dart';
import 'package:omi/widgets/transcript.dart';

const _id = '00000000-0000-4000-8000-000000000001';

class _SpeakerLibrary extends PairedLibrary {
  _SpeakerLibrary() : super('100.64.0.1', List.filled(43, 'A').join()) {
    recordingEdits = true;
    speakerLabelsAvailable = true;
  }

  final people = <Person>[];
  final labels = <String, String>{};
  RecordingEdit? saved;

  @override
  Future<ServerConversation> detail(String id) async => ServerConversation.fromJson({
    'id': id,
    'created_at': '2026-01-02T11:00:00Z',
    'started_at': '2026-01-02T11:00:00Z',
    'finished_at': '2026-01-02T11:01:00Z',
    'structured': {'title': 'Speaker fixture'},
    'transcript_segments': [
      for (var index = 0; index < 2; index++)
        {
          'id': 'line-$index',
          'text': 'Line $index',
          'start': index * 3.0,
          'end': index * 3.0 + 2,
          'speaker_id': 1,
          'is_user': false,
          'person_id': labels['line-$index'],
        },
    ],
  });

  @override
  Future<List<Person>> readLocalPeople() async => [...people];

  @override
  Future<Person> createLocalPerson(String name) async {
    final person = Person(id: 'person-1', name: name, createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026));
    people.add(person);
    return person;
  }

  @override
  Future<ServerConversation> editRecording(String id, RecordingEdit edit) async {
    saved = edit;
    final expected = edit.expected as Map<String, Object?>;
    final value = edit.value as Map<String, Object?>;
    for (final key in expected.keys) {
      labels[key] = value['person_id'] as String;
    }
    return detail(id);
  }
}

void main() {
  testWidgets('the transcript speaker badge names every line in an explicitly selected group', (tester) async {
    final library = _SpeakerLibrary();
    addTearDown(library.close);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: RecordingPage(library: library, id: _id),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();
    final badge = find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == 'Identify speaker',
    );
    expect(badge, findsWidgets);
    await tester.tap(badge.first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add person'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Anna');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();
    expect(library.saved?.field, 'speaker');
    expect(library.labels, {'line-0': 'person-1', 'line-1': 'person-1'});
    final transcript = tester.widget<TranscriptWidget>(find.byType(TranscriptWidget));
    expect(transcript.localPeople.single.name, 'Anna');
    expect(transcript.segments.map((segment) => segment.start), [0.0, 3.0]);
    expect(find.text('Anna'), findsOneWidget);
  });
}
