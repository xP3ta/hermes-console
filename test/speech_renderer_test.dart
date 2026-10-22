import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/speech_renderer.dart';

void main() {
  group('SpeechRenderer', () {
    test('conserva estructura y asigna pausas naturales', () {
      final segments = const SpeechRenderer(language: 'es').render('''
# Resumen

Primer párrafo con una idea.

- Punto uno
- Punto dos

Último párrafo.
''');

      expect(
        segments.map((item) => item.sourceKind),
        containsAll([
          NarrationSourceKind.heading,
          NarrationSourceKind.paragraph,
          NarrationSourceKind.listItem,
        ]),
      );
      expect(segments.first.text, 'Resumen.');
      expect(segments.first.pauseAfter, NarrationPause.long);
      expect(segments.last.pauseAfter, NarrationPause.long);
    });

    test('habla la etiqueta de un enlace y nunca su destino', () {
      final spoken = const SpeechRenderer(language: 'es')
          .render('Consulta [la documentación](https://example.com/a/b?q=1).')
          .map((item) => item.text)
          .join(' ');

      expect(spoken, contains('la documentación'));
      expect(spoken, isNot(contains('https')));
      expect(spoken, isNot(contains('example.com')));
      expect(spoken, isNot(contains('/')));
    });

    test('omite un bloque de código con un único aviso localizado', () {
      final segments = const SpeechRenderer(language: 'es').render('''
Antes.
```dart
final path = /tmp/file;
print(path);
```
Después.
''');
      final spoken = segments.map((item) => item.text).join(' ');

      expect(spoken, contains('Bloque de código omitido.'));
      expect('Bloque de código omitido.'.allMatches(spoken).length, 1);
      expect(spoken, isNot(contains('print')));
      expect(spoken, isNot(contains('/tmp')));
    });

    test('habla portugués: horas, porcentajes, decimales y código', () {
      final spoken = const SpeechRenderer(language: 'pt')
          .render('''
Reunião às 15:00. Desconto de 50%. Versão 1,5.
```
code
```
Fim.
''')
          .map((item) => item.text)
          .join(' ');

      expect(spoken, contains('15 em ponto'));
      expect(spoken, contains('50 por cento'));
      expect(spoken, contains('1 vírgula 5'));
      expect(spoken, contains('Bloco de código omitido.'));
      expect('Bloco de código omitido.'.allMatches(spoken).length, 1);
      expect(spoken, isNot(contains('code')));
    });

    test('habla fechas en portugués', () {
      final spoken = const SpeechRenderer(language: 'pt')
          .render('Entrega em 5/6/2026.')
          .map((item) => item.text)
          .join(' ');
      expect(spoken, contains('5 de junho de 2026'));
    });

    test('humaniza fechas, fracciones, identificadores y rutas', () {
      final spoken = const SpeechRenderer(language: 'es')
          .render(
            'El 18/07/2026 revisa `read_aloud_session` en '
            '/home/user/hermes-console-app y completa 1/2 del trabajo.',
          )
          .map((item) => item.text)
          .join(' ');

      expect(spoken, contains('18 de julio de 2026'));
      expect(spoken, contains('read aloud session'));
      expect(spoken, contains('hermes console app'));
      expect(spoken, contains('un medio'));
      expect(spoken, isNot(contains('/')));
      expect(spoken, isNot(contains('_')));
      expect(spoken, isNot(contains('`')));
    });

    test('preserva importes y porcentajes pequeños en español', () {
      final spoken = const SpeechRenderer(language: 'es')
          .render(
            'Cuesta 0,99€, la oferta es 0,99 €, luego €1,01, '
            'la ratio es 0,99 y el avance es 0,99%.',
          )
          .map((item) => item.text)
          .join(' ');

      expect('0 euros con 99 céntimos'.allMatches(spoken), hasLength(2));
      expect(spoken, contains('1 euro con 1 céntimo'));
      expect(spoken, contains('0 coma 99'));
      expect(spoken, contains('0 coma 99 por ciento'));
      expect(spoken, isNot(contains('99€.')));
    });

    test('preserva símbolos, códigos de moneda y porcentajes en inglés', () {
      final spoken = const SpeechRenderer(language: 'en')
          .render(
            r'It costs $0.99, another item is 0.99 USD, then 1.01€; '
            r'the ratio is 0.99 and progress is 0.99%.',
          )
          .map((item) => item.text)
          .join(' ');

      expect('0 dollars and 99 cents'.allMatches(spoken), hasLength(2));
      expect(spoken, contains('1 euro and 1 cent'));
      expect(spoken, contains('0 point 99'));
      expect(spoken, contains('0 point 99 percent'));
    });

    test('usa pausas breves sin demoras artificiales largas', () {
      expect(NarrationPause.short.duration, const Duration(milliseconds: 120));
      expect(NarrationPause.medium.duration, const Duration(milliseconds: 250));
      expect(NarrationPause.long.duration, const Duration(milliseconds: 400));
    });

    test('una URL sola se omite y una URL incrustada se llama enlace', () {
      const renderer = SpeechRenderer(language: 'es');
      expect(renderer.render('https://example.com/a/b'), isEmpty);
      expect(
        renderer
            .render('Mira https://example.com/a/b para más datos')
            .single
            .text,
        contains('enlace'),
      );
    });

    test('las tablas se leen por filas sin barras', () {
      final segments = const SpeechRenderer(language: 'es').render('''
| Nombre | Estado |
| --- | --- |
| Worker | Activo |
''');
      final spoken = segments.map((item) => item.text).join(' ');

      expect(spoken, contains('Nombre, Estado'));
      expect(spoken, contains('Worker, Activo'));
      expect(spoken, isNot(contains('|')));
    });

    final noisyFixtures = <String>[
      '**negrita**',
      '_cursiva_',
      '~~tachado~~',
      '> cita',
      '---',
      'repo/branch',
      r'C:\Users\tester\file.txt',
      '`camelCaseValue`',
      '`snake_case_value`',
      'https://example.org/x/y',
      'mira https://example.org/x/y ahora',
      '[etiqueta](https://example.org)',
      '![imagen](https://example.org/a.png)',
      '18/07/2026',
      '07/18/2026',
      '1/2',
      '3/4',
      '/usr/local/bin/flutter',
      '~/dev/hermes_android',
      'uno | dos | tres',
      '# Encabezado',
      '## Sección',
      '- viñeta',
      '1. primero',
      '* * *',
      '\u001b[31mrojo\u001b[0m',
      'foo_bar_baz',
      'HTTP/API',
      'play/pause',
      'correo@example.org',
      '10 km',
      '20 %',
      '€12,50',
      'v1.2.3',
      '¿Qué tal?',
      '¡Muy bien!',
      '🙂 texto',
      'A → B',
      '── separador ──',
      'archivo.json',
      'src/lib/main.dart',
      'www.example.com/path',
    ];

    test('corpus técnico nunca deja sintaxis estructural para el TTS', () {
      const renderer = SpeechRenderer(language: 'es');
      for (final fixture in noisyFixtures) {
        final spoken = renderer
            .render(fixture)
            .map((item) => item.text)
            .join(' ');
        expect(spoken, isNot(matches(RegExp(r'[|`*_#\\/]'))), reason: fixture);
        expect(spoken, isNot(contains('http')), reason: fixture);
      }
      expect(noisyFixtures.length, greaterThanOrEqualTo(40));
    });

    test('vocabulario equivalente en inglés', () {
      final spoken = const SpeechRenderer(language: 'en')
          .render('See https://example.com and 1/2 in `readAloudState`.')
          .map((item) => item.text)
          .join(' ');

      expect(spoken, contains('link'));
      expect(spoken, contains('one half'));
      expect(spoken, contains('read Aloud State'));
    });
  });

  group('calidad de lectura (spec 048, feedback físico 2026-07-24)', () {
    String es(String raw) => const SpeechRenderer(
      language: 'es',
    ).render(raw).map((item) => item.text).join(' ');

    test('las horas HH:MM se leen como habla, no como símbolos', () {
      expect(es('La reunión es a las 14:30 de hoy.'), contains('14 y 30'));
      expect(es('Programado a las 09:00 en punto.'), contains('9 en punto'));
      // Un marcador tipo 2:1 (una cifra de minutos) no es una hora: intacto.
      expect(es('Terminó 2:1 el partido.'), contains('2:1'));
      // 45:99 no es una hora válida: intacto.
      expect(es('El código 45:99 del manual.'), contains('45:99'));
    });

    test('una URL colgada al final se omite en vez de decir "enlace"', () {
      expect(
        es('Puedes verlo aquí: https://example.com/docs/guia'),
        isNot(contains('enlace')),
      );
      expect(
        es('El panel está en https://hermes.local/panel.'),
        isNot(contains('enlace')),
      );
      // En mitad de la frase sigue diciendo "enlace" (quitarla dejaría la
      // frase coja).
      expect(
        es('Abre https://example.com y dime qué ves.'),
        contains('enlace'),
      );
    });

    test('los emojis no llegan al TTS', () {
      final spoken = es('¡Hola! 👋 Todo listo ✅ para empezar 🚀🚀.');
      expect(
        spoken,
        isNot(matches(RegExp(r'[\u{1F300}-\u{1FAFF}]', unicode: true))),
      );
      expect(spoken, isNot(contains('✅')));
      expect(spoken, contains('Hola'));
      expect(spoken, contains('Todo listo'));
    });

    test('en inglés las horas usan su vocabulario', () {
      final spoken = const SpeechRenderer(language: 'en')
          .render('The meeting is at 14:30 sharp.')
          .map((item) => item.text)
          .join(' ');
      expect(spoken, contains('14 30'));
    });
  });
}
