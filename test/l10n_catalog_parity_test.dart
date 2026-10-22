import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';
import 'package:hermes_android/l10n/app_localizations_pt.dart';

Map<String, Object?> _readCatalog(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

Set<String> _messageKeys(Map<String, Object?> catalog) =>
    catalog.keys.where((key) => !key.startsWith('@')).toSet();

Set<String> _placeholders(Object? message) => RegExp(
  r'\{([A-Za-z][A-Za-z0-9_]*)\s*(?:\}|,)',
).allMatches(message as String).map((match) => match.group(1)!).toSet();

void main() {
  test(
    'los catálogos español, inglés y portugués tienen las mismas claves y variables',
    () {
      final es = _readCatalog('lib/l10n/app_es.arb');
      final en = _readCatalog('lib/l10n/app_en.arb');
      final pt = _readCatalog('lib/l10n/app_pt.arb');

      // app_es.arb es la plantilla de gen-l10n y por eso conserva más
      // entradas @metadata. El contrato traducible son las claves de mensaje
      // sin @.
      expect(_messageKeys(en), _messageKeys(es));
      expect(_messageKeys(pt), _messageKeys(es));

      for (final key in _messageKeys(es)) {
        expect(
          _placeholders(en[key]),
          _placeholders(es[key]),
          reason: 'Los placeholders de $key deben coincidir en ES/EN',
        );
        expect(
          _placeholders(pt[key]),
          _placeholders(es[key]),
          reason: 'Los placeholders de $key deben coincidir en ES/PT',
        );
      }
    },
  );

  test(
    'Notificaciones conserva la misma mayúscula inicial que cada pantalla',
    () {
      final es = _readCatalog('lib/l10n/app_es.arb');
      final en = _readCatalog('lib/l10n/app_en.arb');
      final pt = _readCatalog('lib/l10n/app_pt.arb');

      expect(es['notifTitle'], 'Notificaciones');
      expect(en['notifTitle'], 'Notifications');
      expect(pt['notifTitle'], 'Notificações');
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
    expect(
      StringsPt().chaBackgroundWorkRemaining(1),
      'Não foi possível parar tudo: resta 1 tarefa em segundo plano',
    );
    expect(
      StringsPt().chaBackgroundWorkRemaining(2),
      'Não foi possível parar tudo: restam 2 tarefas em segundo plano',
    );
  });

  test('el hint de voz explica barge-in sin pedir que Hermes termine', () {
    final es = _readCatalog('lib/l10n/app_es.arb');
    final en = _readCatalog('lib/l10n/app_en.arb');
    final pt = _readCatalog('lib/l10n/app_pt.arb');

    expect(es['chaVoiceCanInterruptHint'], contains('interrumpir hablando'));
    expect(es['chaVoiceCanInterruptHint'], isNot(contains('Espera')));
    expect(en['chaVoiceCanInterruptHint'], contains('interrupt by speaking'));
    expect(en['chaVoiceCanInterruptHint'], isNot(contains('Wait')));
    expect(pt['chaVoiceCanInterruptHint'], contains('interromper falando'));
    expect(pt['chaVoiceCanInterruptHint'], isNot(contains('Espere')));
  });

  test('Servidor Hermes nunca promete cambiar a la voz local', () {
    final es = _readCatalog('lib/l10n/app_es.arb');
    final en = _readCatalog('lib/l10n/app_en.arb');
    final pt = _readCatalog('lib/l10n/app_pt.arb');

    expect(es['voiceModeServerSub'], contains('no cambia al teléfono'));
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

    expect(pt['voiceModeServerSub'], contains('não troca para o telefone'));
    expect(pt['nativeVoiceConsentBody'], contains('não muda para a voz local'));
    expect(
      pt['voiceServerFallbackNote'],
      contains('Não ativa automaticamente'),
    );
  });
}
