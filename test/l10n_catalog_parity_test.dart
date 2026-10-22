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
  test('all nine catalogs have matching message keys and placeholders', () {
    final es = _readCatalog('lib/l10n/app_es.arb');
    final keys = _messageKeys(es);
    // Spanish is the gen-l10n template; metadata is not a message key.
    for (final lang in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
      final catalog = _readCatalog('lib/l10n/app_$lang.arb');
      expect(catalog['@@locale'], lang);
      expect(_messageKeys(catalog), keys, reason: lang);
      for (final key in keys) {
        expect(catalog[key], isA<String>(), reason: '$lang:$key');
        expect((catalog[key] as String).trim(), isNotEmpty,
            reason: '$lang:$key');
        expect(_placeholders(catalog[key]), _placeholders(es[key]),
            reason: '$lang:$key placeholders must match the template');
      }
    }
  });

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
