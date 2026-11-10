import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/voice_disclosure_dialog.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// Copy of the voice lane (prefix `voz132`): the direct-voice consent, the
/// provider error wrapper and the stop-phrase notice, in the nine catalogs.
void main() {
  const keys = <String>{
    'voz132VoiceProviderError',
    'voz132DirectConsentTitle',
    'voz132DirectConsentBody',
    'voz132DirectConsentAccept',
    'voz132DirectConsentAcceptSub',
    'voz132DirectConsentDecline',
    'voz132DirectConsentDeclineSub',
    'voz132SayStopToEnd',
  };
  const locales = ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'];

  Map<String, int> arguments(String value) {
    final result = <String, int>{};
    for (final match in RegExp(
      r'\{[A-Za-z][A-Za-z0-9_]*\}',
    ).allMatches(value)) {
      result.update(match.group(0)!, (n) => n + 1, ifAbsent: () => 1);
    }
    return result;
  }

  final catalogs = <String, Map<String, dynamic>>{
    for (final lang in locales)
      lang:
          jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
              as Map<String, dynamic>,
  };

  test('exact keys and placeholders in all nine locales', () {
    for (final entry in catalogs.entries) {
      final catalog = entry.value;
      expect(
        catalog.keys.where((key) => key.startsWith('voz132')),
        unorderedEquals(keys),
        reason: entry.key,
      );
      for (final key in keys) {
        final value = catalog[key] as String;
        expect(value.trim(), isNotEmpty, reason: '${entry.key} $key');
        expect(
          arguments(value),
          arguments(catalogs['en']![key] as String),
          reason: '${entry.key} $key',
        );
      }
    }
  });

  test('every consent text names example providers and the relay', () {
    for (final entry in catalogs.entries) {
      final body = entry.value['voz132DirectConsentBody'] as String;
      for (final provider in ['OpenAI', 'ElevenLabs', 'Groq']) {
        expect(body, contains(provider), reason: '${entry.key} $provider');
      }
    }
  });

  test('generated accessors carry the copy', () {
    expect(
      lookupStrings(const Locale('es')).voz132DirectConsentTitle,
      'Voz directa al proveedor',
    );
    expect(
      lookupStrings(const Locale('en')).voz132DirectConsentTitle,
      'Direct voice to the provider',
    );
    expect(
      lookupStrings(const Locale('es')).voz132VoiceProviderError('x'),
      'El proveedor de voz respondió: x',
    );
    expect(
      lookupStrings(const Locale('en')).voz132VoiceProviderError('x'),
      'The voice provider replied: x',
    );
    // Desktop i18n/en.ts:458 and es.ts:470 (sayStopToEnd).
    expect(
      lookupStrings(const Locale('en')).voz132SayStopToEnd('stop'),
      'Say "stop" to end the voice chat.',
    );
    expect(
      lookupStrings(const Locale('es')).voz132SayStopToEnd('stop'),
      'Di «stop» para terminar el chat de voz.',
    );
  });

  test('the stop notice names the phrase in every locale', () {
    for (final lang in locales) {
      expect(
        lookupStrings(Locale(lang)).voz132SayStopToEnd('отбой'),
        contains('отбой'),
        reason: lang,
      );
    }
  });

  group('showClientDirectVoiceConsentDialog', () {
    Future<bool?> open(WidgetTester tester, Key choice, Size view) async {
      tester.view
        ..physicalSize = view
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      bool? result;
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showClientDirectVoiceConsentDialog(context);
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final s = lookupStrings(const Locale('es'));
      expect(find.text(s.voz132DirectConsentTitle), findsOneWidget);
      expect(find.text(s.voz132DirectConsentBody), findsOneWidget);
      // The dialog scrolls: on a short screen a choice can sit below the
      // fold. Bring it into view and make sure a tap reaches it first.
      final target = find.byKey(choice);
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      expect(
        target.hitTestable(),
        findsOneWidget,
        reason: '$choice is not reachable by a tap at ${view.width}x'
            '${view.height}',
      );
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      return result;
    }

    // A test window and a small phone, where the text pushes the choices
    // below the fold.
    for (final view in const [Size(800, 600), Size(360, 640)]) {
      final label = '${view.width.toInt()}x${view.height.toInt()}';

      testWidgets('$label: accepting answers true', (tester) async {
        expect(
          await open(
            tester,
            const ValueKey('voice_client_direct_accept'),
            view,
          ),
          isTrue,
        );
      });

      testWidgets('$label: declining answers false', (tester) async {
        expect(
          await open(
            tester,
            const ValueKey('voice_client_direct_decline'),
            view,
          ),
          isFalse,
        );
      });
    }
  });
}
