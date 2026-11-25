import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/local_next/processing.dart';
import 'package:omi/local_next/processing_page.dart';

Finder _control(String id) => find.byKey(ValueKey(id));

Future<void> _tap(WidgetTester tester, String key) async {
  final control = _control(key);
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final field = _control(key);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, NextProcessingClient client) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1120);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: LocalNextProcessingPage(client: client, serverLabel: 'paired.example', isRecording: () => true),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('models, explicit metadata check and draft save leave the published STT snapshot intact', (tester) async {
    final active = <String, dynamic>{
      'id': 'stt1',
      'name': 'Transcriber',
      'stage': 'stt',
      'kind': 'openai-compatible',
      'configuration_revision': 5,
      'can_edit': true,
      'has_key': true,
      'settings': {
        'provider_url': 'https://asr.example/v1',
        'model': 'old-model',
        'language': 'ru',
        'device': 'cpu',
        'diarization_model': 'none',
      },
    };
    var saved = active;
    var revision = 5;
    Map<String, dynamic> read() => {
      'revision': revision,
      'profiles': [saved],
      'effective': {'stt': active},
    };
    final calls = <NextDraftOperation>[];
    final bodies = <Map<String, dynamic>>[];
    final client = NextProcessingClient(
      read: () async => read(),
      activatePrepared: (_) => throw StateError('Unexpected activation'),
      draftRequest: (action, body, _) async {
        calls.add(action);
        bodies.add(body);
        if (action != NextDraftOperation.save) {
          return {
            'state': 'ready',
            'models': ['catalog-model'],
          };
        }
        revision++;
        saved = <String, dynamic>{
          ...body['profile'] as Map<String, dynamic>,
          'can_edit': true,
          'has_key': false,
          'configuration_revision': revision,
        };
        return read();
      },
    );
    await _open(tester, client);
    expect(_control('next-stt-delete'), findsNothing);
    await _tap(tester, 'next-stt-edit');
    final secret = tester.widget<TextField>(
      find.descendant(of: _control('next-draft-key'), matching: find.byType(TextField)),
    );
    expect(secret.obscureText, isTrue);
    expect(secret.controller!.text, isEmpty);
    await _tap(tester, 'next-draft-models');
    expect(calls, [NextDraftOperation.models]);
    expect(bodies.first.keys, ['profile']);
    await tester.tap(find.text('catalog-model'));
    await tester.pumpAndSettle();
    await _tap(tester, 'next-draft-probe');
    expect(bodies.last['profile']['settings']['model'], 'catalog-model');
    expect(bodies.last.keys, ['profile']);
    expect(find.text('Connection test passed.'), findsOneWidget);
    await _enter(tester, 'next-draft-endpoint', 'https://asr.example');
    await _tap(tester, 'next-draft-save');
    expect(find.text('Please enter a valid URL'), findsOneWidget);
    await _enter(tester, 'next-draft-endpoint', 'https://asr.example/v1');
    await _enter(tester, 'next-draft-language', 'Russian');
    await _tap(tester, 'next-draft-save');
    expect(find.textContaining('three-letter language code'), findsOneWidget);
    expect(calls.length, 2);
    await _enter(tester, 'next-draft-language', 'ru');
    await _enter(tester, 'next-draft-endpoint', 'https://replacement.example/v1');
    await _tap(tester, 'next-draft-save');
    expect(find.textContaining('This address belongs to a different server'), findsOneWidget);
    expect(calls.length, 2);
    await _enter(tester, 'next-draft-key', 'é');
    await _tap(tester, 'next-draft-save');
    expect(calls.length, 2);
    expect(find.text('Check provider settings'), findsOneWidget);
    expect(tester.widget<FilledButton>(_control('next-draft-save')).onPressed, isNotNull);
    await _enter(tester, 'next-draft-key', 'fixture-only');
    await _tap(tester, 'next-draft-probe');
    expect(bodies.last['api_key'], 'fixture-only');
    expect(bodies.last, isNot(contains('clear_key')));
    await _tap(tester, 'next-draft-clear');
    expect(secret.controller!.text, isEmpty);
    await _tap(tester, 'next-draft-save');
    expect(calls, [
      NextDraftOperation.models,
      NextDraftOperation.probe,
      NextDraftOperation.probe,
      NextDraftOperation.save,
    ]);
    expect(bodies.last, containsPair('clear_key', true));
    expect(bodies.last, isNot(contains('api_key')));
    expect(bodies.last, containsPair('revision', 5));
    expect(bodies.last['profile']['settings']['device'], 'cpu');
    expect(find.text('Active · Transcriber'), findsOneWidget);
    expect(find.textContaining('Saved changes are not active'), findsOneWidget);
    expect(tester.widget<FilledButton>(_control('next-stt-confirm')).onPressed, isNull);
  });

  testWidgets('create with no key and delete only an inactive editable profile after confirmation', (tester) async {
    final active = {
      'id': 'managed',
      'name': 'Managed local',
      'stage': 'live',
      'kind': 'whisperlivekit',
      'can_edit': false,
      'configuration_revision': 1,
    };
    Map<String, dynamic>? saved;
    var revision = 2;
    var deletes = 0;
    Map<String, dynamic> read() => {
      'revision': revision,
      'profiles': [active, if (saved != null) saved],
      'effective': {'live': active, 'summary': null, 'translation': null},
    };
    final client = NextProcessingClient(
      read: () async => read(),
      activatePrepared: (_) => throw StateError('Unexpected activation'),
      draftRequest: (operation, body, id) async {
        revision++;
        if (operation == NextDraftOperation.save) {
          expect(body['profile']['stage'], 'live');
          expect(body['profile']['kind'], 'external');
          expect(body, isNot(contains('api_key')));
          expect(body, isNot(contains('clear_key')));
          saved = <String, dynamic>{
            ...body['profile'] as Map<String, dynamic>,
            'id': 'draft',
            'can_edit': true,
            'has_key': false,
            'configuration_revision': revision,
          };
        } else {
          expect(operation, NextDraftOperation.delete);
          expect(id, 'draft');
          expect(body, {'revision': 3});
          deletes++;
          saved = null;
        }
        return read();
      },
    );
    await _open(tester, client);
    expect(_control('next-live-edit'), findsNothing);
    expect(_control('next-live-delete'), findsNothing);
    expect(_control('next-summary-add'), findsNothing);
    expect(_control('next-translation-add'), findsNothing);
    await _tap(tester, 'next-live-add');
    expect(_control('next-draft-models'), findsNothing);
    expect(_control('next-draft-clear'), findsNothing);
    await _enter(tester, 'next-draft-name', 'External draft');
    await _enter(tester, 'next-draft-endpoint', 'wss://relay.example/asr');
    await _tap(tester, 'next-draft-save');
    expect(find.text('Active · Managed local'), findsOneWidget);
    await _tap(tester, 'next-live-3');
    await tester.tap(find.text('External draft').last);
    await tester.pumpAndSettle();
    await _tap(tester, 'next-live-delete');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pumpAndSettle();
    expect(deletes, 0);
    await _tap(tester, 'next-live-delete');
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Delete')),
    );
    await tester.pumpAndSettle();
    expect(deletes, 1);
    expect(_control('next-live-delete'), findsNothing);
    expect(find.text('Active · Managed local'), findsOneWidget);
  });
}
