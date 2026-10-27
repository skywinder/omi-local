import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/widgets/live_translation_controls.dart';

void main() {
  Widget app(Widget child) => MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      );

  test('picker languages are unique base codes in bundled order', () {
    final languages = LiveTranslationSettings.languages({
      'English': 'en',
      'English (US)': 'en-US',
      'Swedish (Sweden)': 'sv-SE',
      'Swedish': 'sv',
      'Cantonese': 'yue',
      'Broken': 'x1',
    });
    expect(languages, {'English': 'en', 'Swedish': 'sv', 'Cantonese': 'yue'});
    expect(LiveTranslationSettings.label('sv', languages), 'Swedish');
    expect(LiveTranslationSettings.label('zz', languages), 'ZZ');
    expect(LiveTranslationSettings.languages()['German'], 'de');
  });

  testWidgets('toggle flips enablement and the chip picks a new target', (tester) async {
    final calls = <Map<String, Object?>>[];
    var enabled = false;
    var language = 'en';
    late StateSetter refresh;
    await tester.pumpWidget(app(StatefulBuilder(builder: (context, setState) {
      refresh = setState;
      return LiveTranslationToggle(
        enabled: enabled,
        language: language,
        onChanged: ({bool? enabled, String? language}) async => calls.add({'enabled': enabled, 'language': language}),
      );
    })));
    expect(find.byKey(const Key('live_translation_language_chip')), findsNothing);
    await tester.tap(find.byKey(const Key('live_translation_toggle')));
    expect(calls, [
      {'enabled': true, 'language': null}
    ]);
    refresh(() => enabled = true);
    await tester.pumpAndSettle();
    expect(find.text('→ EN'), findsOneWidget);
    await tester.tap(find.byKey(const Key('live_translation_language_chip')));
    await tester.pumpAndSettle();
    final french = find.byKey(const ValueKey('live-translation-language-fr'));
    await tester.scrollUntilVisible(french, 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(french);
    await tester.pumpAndSettle();
    expect(calls.last, {'enabled': null, 'language': 'fr'});
    refresh(() => language = 'fr');
    await tester.pumpAndSettle();
    expect(find.text('→ FR'), findsOneWidget);
    await tester.tap(find.byKey(const Key('live_translation_toggle')));
    expect(calls.last, {'enabled': false, 'language': null});
  });

  testWidgets('status hint explains unconfigured or failed relays only while enabled', (tester) async {
    await tester.pumpWidget(app(const LiveTranslationStatusHint(enabled: true, status: 'unconfigured')));
    final l10n = AppLocalizations.of(tester.element(find.byType(LiveTranslationStatusHint)));
    expect(find.text(l10n.liveTranslationUnconfigured), findsOneWidget);
    expect(l10n.liveTranslationUnconfigured, contains('connected server'));
    expect(l10n.liveTranslationUnconfigured, contains('Settings'));
    await tester.pumpWidget(app(const LiveTranslationStatusHint(enabled: true, status: 'failed')));
    expect(find.text(l10n.liveTranslationFailed), findsOneWidget);
    for (final hidden in [
      const LiveTranslationStatusHint(enabled: true, status: 'ready'),
      const LiveTranslationStatusHint(enabled: true, status: null),
      const LiveTranslationStatusHint(enabled: false, status: 'unconfigured'),
    ]) {
      await tester.pumpWidget(app(hidden));
      expect(find.byKey(const Key('live_translation_status_hint')), findsNothing);
    }
  });
}
