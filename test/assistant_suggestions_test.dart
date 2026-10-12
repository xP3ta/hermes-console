import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/utils/assistant_suggestions.dart';

void main() {
  test('proyecta solo el cierre explicito y limpia el conector suelto', () {
    final projection = projectAssistantSuggestions('''
Resumen con una lista normal:
1. Primer hecho
2. Segundo hecho

Si quieres, te lo convierto en:
- **versión corta (10 minutos de lectura)**,
- **versión por regiones (Madrid/Cataluña/Andalucía...)**, o
- solo “hechos duros” sin contexto político/cultural.
''');

    expect(projection.body, contains('1. Primer hecho'));
    expect(projection.body, isNot(contains('Si quieres')));
    expect(projection.suggestions, [
      'versión corta (10 minutos de lectura)',
      'versión por regiones (Madrid/Cataluña/Andalucía...)',
      'solo “hechos duros” sin contexto político/cultural',
    ]);
  });

  test('no interpreta una lista normal y acepta un cierre con una opcion', () {
    final normal = projectAssistantSuggestions('- uno\n- dos\n- tres');
    final one = projectAssistantSuggestions(
      'Texto\n\nSi quieres, puedo:\n- resumirlo',
    );

    expect(normal.hasSuggestions, isFalse);
    expect(normal.body, '- uno\n- dos\n- tres');
    expect(one.body, 'Texto');
    expect(one.suggestions, ['resumirlo']);
  });

  test('retira un conector suelto entre las opciones', () {
    final projection = projectAssistantSuggestions('''
Texto

Si te sirve, puedo dejarlo como:
— resumen ejecutivo
.o
— lista de tareas
''');

    expect(projection.body, 'Texto');
    expect(projection.suggestions, ['resumen ejecutivo', 'lista de tareas']);
  });

  test('acepta cierres explícitos alternativos sin tocar listas normales', () {
    final projection = projectAssistantSuggestions('''
Respuesta principal.

También puedo dejarlo listo como:
- checklist de QA
- plan de implementación
''');

    expect(projection.body, 'Respuesta principal.');
    expect(projection.suggestions, [
      'checklist de QA',
      'plan de implementación',
    ]);
  });

  test(
    'proyecta una oferta final española sin bullets y retira su divisor',
    () {
      final projection = projectAssistantSuggestions('''
Resultado estable.

---

Si quieres, en el siguiente paso te preparo un plan detallado.
''');

      expect(projection.body, 'Resultado estable.');
      expect(projection.suggestions, ['Prepara un plan detallado']);
    },
  );

  test('proyecta una oferta final inglesa sin bullets', () {
    final projection = projectAssistantSuggestions('''
The result is ready.

If you want, next I can prepare a compact checklist.
''');

    expect(projection.body, 'The result is ready.');
    expect(projection.suggestions, ['Prepare a compact checklist']);
  });

  test('compacta la oferta larga que produce el chat real', () {
    final projection = projectAssistantSuggestions('''
Orden recomendado.

---

Si quieres, en el siguiente paso te preparo un **plan de recorte con números concretos por escenario** (conservador / medio / agresivo) y el set de comandos de Zerobyte con valores exactos para aplicarlo sin riesgo operacional (incluye qué se perdería y qué no).
''');

    expect(projection.body, 'Orden recomendado.');
    expect(projection.suggestions, [
      'Prepara un plan de recorte con números concretos por escenario',
    ]);
  });

  test('una mención intermedia o un verbo desconocido no se convierten', () {
    const middle =
        'Lo resolvemos si quieres, pero antes hay que revisar el servidor.';
    const unknown =
        'Resultado.\n\n---\n\nSi quieres, mañana coordinamos el despliegue.';

    final middleProjection = projectAssistantSuggestions(middle);
    final unknownProjection = projectAssistantSuggestions(unknown);

    expect(middleProjection.hasSuggestions, isFalse);
    expect(middleProjection.body, middle);
    expect(unknownProjection.hasSuggestions, isFalse);
    expect(unknownProjection.body, unknown, reason: 'no borra el divisor');
  });

  test('solo proyecta la oferta cuando es el último párrafo', () {
    const source =
        'Si quieres, te preparo un plan.\n\nPero este es el cierre real.';
    final projection = projectAssistantSuggestions(source);

    expect(projection.hasSuggestions, isFalse);
    expect(projection.body, source);
  });

  test('no convierte cierres de más de tres acciones en un rail parcial', () {
    final projection = projectAssistantSuggestions('''
Respuesta principal.

¿Cuál prefieres?
1) resumen breve
2) checklist
3) tabla comparativa
4) plan paso a paso
''');

    expect(projection.body, contains('¿Cuál prefieres?'));
    expect(projection.suggestions, isEmpty);
  });

  test('no oculta código, errores ni bloques con más de cuatro opciones', () {
    final code = projectAssistantSuggestions('''
```dart
throw StateError('fallo');
```

Si quieres, puedo:
- explicarlo
''');
    final error = projectAssistantSuggestions('''
Error: no se pudo completar la operación.

Si quieres, puedo:
- reintentarlo
''');
    final tooMany = projectAssistantSuggestions('''
Texto.

Puedes elegir:
1. uno
2. dos
3. tres
4. cuatro
5. cinco
''');

    expect(code.hasSuggestions, isFalse);
    expect(error.hasSuggestions, isFalse);
    expect(tooMany.hasSuggestions, isFalse);
  });

  test(
    'solo ofrece acciones en el último assistant terminal y chat limpio',
    () {
      bool allowed({
        bool latest = true,
        bool terminal = true,
        bool busy = false,
        bool writable = true,
        bool composerEmpty = true,
        bool attachmentsEmpty = true,
      }) => canOfferAssistantSuggestions(
        isLatestAssistant: latest,
        isTerminal: terminal,
        chatBusy: busy,
        writable: writable,
        composerEmpty: composerEmpty,
        attachmentsEmpty: attachmentsEmpty,
      );

      expect(allowed(), isTrue);
      expect(allowed(latest: false), isFalse, reason: 'mensaje histórico');
      expect(allowed(terminal: false), isFalse, reason: 'run activo');
      expect(allowed(busy: true), isFalse, reason: 'chat ocupado');
      expect(allowed(writable: false), isFalse, reason: 'solo lectura');
      expect(allowed(composerEmpty: false), isFalse, reason: 'borrador');
      expect(allowed(attachmentsEmpty: false), isFalse, reason: 'adjuntos');
    },
  );

  test(
    'el cierre no se duplica al virtualizar una respuesta de más de 5200',
    () {
      final prefix = List.generate(
        170,
        (index) => 'Párrafo $index con contenido estable para el viewport.\n\n',
      ).join();
      final source =
          '$prefix'
          'Si quieres, puedo:\n'
          '- resumirlo\n'
          '- convertirlo en tareas';
      final projection = projectAssistantSuggestions(source);
      final chunks = splitAssistantMarkdownForViewport(source);

      expect(source.length, greaterThan(5200));
      expect(chunks.length, greaterThan(1));
      expect(projection.suggestions, ['resumirlo', 'convertirlo en tareas']);
      final renderedBody = [
        ...chunks.take(chunks.length - 1),
        stripAssistantSuggestionsFromTerminalChunk(chunks.last),
      ].join();
      expect(renderedBody, projection.body);
      expect(renderedBody, isNot(contains('Si quieres, puedo:')));
    },
  );
}
