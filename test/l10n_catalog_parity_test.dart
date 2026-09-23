import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

Map<String, Object?> _readCatalog(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

Set<String> _messageKeys(Map<String, Object?> catalog) =>
    catalog.keys.where((key) => !key.startsWith('@')).toSet();

Set<String> _placeholders(Object? message) => RegExp(
  r'\{([A-Za-z][A-Za-z0-9_]*)\s*(?:\}|,)',
).allMatches(message as String).map((match) => match.group(1)!).toSet();

void main() {
  test(
    'los catálogos español e inglés tienen las mismas claves y variables',
    () {
      final es = _readCatalog('lib/l10n/app_es.arb');
      final en = _readCatalog('lib/l10n/app_en.arb');

      // app_es.arb es la plantilla de gen-l10n y por eso conserva más entradas
      // @metadata. El contrato traducible son las claves de mensaje sin @.
      expect(_messageKeys(en), _messageKeys(es));

      for (final key in _messageKeys(es)) {
        expect(
          _placeholders(en[key]),
          _placeholders(es[key]),
          reason: 'Los placeholders de $key deben coincidir en ES/EN',
        );
      }
    },
  );

  test(
    'Notificaciones conserva la misma mayúscula inicial que cada pantalla',
    () {
      final es = _readCatalog('lib/l10n/app_es.arb');
      final en = _readCatalog('lib/l10n/app_en.arb');

      expect(es['notifTitle'], 'Notificaciones');
      expect(en['notifTitle'], 'Notifications');
    },
  );

  test('las tareas restantes usan singular y plural', () {
    expect(
      StringsEn().chaBackgroundWorkRemaining(1),
      'Could not stop everything: 1 background task remains',
    );
    expect(
      StringsEn().chaBackgroundWorkRemaining(2),
      'Could not stop everything: 2 background tasks remain',
    );
    expect(
      StringsEs().chaBackgroundWorkRemaining(1),
      'No se pudo detener todo: queda 1 tarea en segundo plano',
    );
    expect(
      StringsEs().chaBackgroundWorkRemaining(2),
      'No se pudo detener todo: quedan 2 tareas en segundo plano',
    );
  });

  test('el hint de voz explica barge-in sin pedir que Hermes termine', () {
    final es = _readCatalog('lib/l10n/app_es.arb');
    final en = _readCatalog('lib/l10n/app_en.arb');

    expect(es['chaVoiceCanInterruptHint'], contains('interrumpir hablando'));
    expect(es['chaVoiceCanInterruptHint'], isNot(contains('Espera')));
    expect(en['chaVoiceCanInterruptHint'], contains('interrupt by speaking'));
    expect(en['chaVoiceCanInterruptHint'], isNot(contains('Wait')));
  });

  test('Servidor Hermes nunca promete cambiar a la voz local', () {
    final es = _readCatalog('lib/l10n/app_es.arb');
    final en = _readCatalog('lib/l10n/app_en.arb');

    expect(es['voiceModeServerSub'], contains('no cambia al móvil'));
    expect(
      es['nativeVoiceConsentBody'],
      contains('no cambiará a la voz local'),
    );
    expect(
      es['voiceServerFallbackNote'],
      contains('No activa automáticamente'),
    );

    expect(en['voiceModeServerSub'], contains('never switches'));
    expect(
      en['nativeVoiceConsentBody'],
      contains('will not switch to local voice'),
    );
    expect(en['voiceServerFallbackNote'], contains('does not automatically'));
  });
}
