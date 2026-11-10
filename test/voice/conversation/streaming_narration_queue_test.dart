import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/conversation/streaming_narration_queue.dart';

void main() {
  StreamingNarrationQueue queue() => StreamingNarrationQueue(language: 'es');

  test('retiene una frase parcial y publica fronteras semánticas', () {
    final q = queue();

    q.observe('Hola mun');
    expect(q.chunks, isEmpty);

    q.observe('Hola mundo. Sigo redactando');
    expect(q.chunks.map((chunk) => chunk.text), ['Hola mundo.']);
    expect(q.current?.text, 'Hola mundo.');
  });

  test(
    'retiene el encabezado inicial breve hasta la primera frase estable',
    () {
      final q = queue();

      q.observe('## Noticias de hoy\n');
      expect(q.chunks, isEmpty);

      q.observe('## Noticias de hoy\n\nEspaña sigue redactando');
      expect(q.chunks, isEmpty);

      q.observe('## Noticias de hoy\n\nEspaña tiene novedades.');
      expect(q.chunks.map((chunk) => chunk.text), [
        'Noticias de hoy.',
        'España tiene novedades.',
      ]);
    },
  );

  test('una respuesta terminal que solo contiene encabezado sí se narra', () {
    final q = queue();

    q.observe('## Aviso', terminal: true);

    expect(q.chunks.map((chunk) => chunk.text), ['Aviso.']);
  });

  test('una respuesta mayor de 450 caracteres no se trunca', () {
    final q = queue();
    final response = List.generate(
      18,
      (index) =>
          'Esta es la frase número $index y contiene suficiente detalle.',
    ).join(' ');
    expect(response.length, greaterThan(450));

    q.observe(response, terminal: true);

    expect(q.chunks, isNotEmpty);
    expect(q.chunks.every((chunk) => chunk.text.length <= 160), isTrue);
    expect(
      q.chunks.map((chunk) => chunk.text).join(' ').length,
      greaterThan(450),
    );
    expect(q.chunks.map((chunk) => chunk.text).join(' '), response);
  });

  test('el final decorado retoma tras el cuerpo ya aceptado sin repetirlo', () {
    final q = queue();
    const alreadyAccepted =
        'Aquí van las noticias verificadas. Precio de la luz baja. '
        'España reactiva controles fronterizos.';
    q.observe(alreadyAccepted);
    q.markPlaybackThrough(q.chunks.length);
    final revision = q.revision;

    final update = q.observe(
      '¡Listo! $alreadyAccepted Ceuta sigue abierta.',
      terminal: true,
    );

    expect(update.revisionChanged, isTrue);
    expect(q.revision, isNot(revision));
    expect(
      q.current?.text,
      'Ceuta sigue abierta.',
      reason:
          'el prefijo decorativo nuevo no justifica volver a leer el cuerpo '
          'que el motor ya aceptó',
    );
  });

  test('aplica el renderer oral a Markdown, URLs y bloques de código', () {
    final q = queue();
    q.observe(
      'Consulta [la guía](https://example.com).\n\n```dart\nprint(1);\n```',
      terminal: true,
    );
    final spoken = q.chunks.map((chunk) => chunk.text).join(' ');

    expect(spoken, contains('la guía'));
    expect(spoken, contains('Bloque de código omitido.'));
    expect(spoken, isNot(contains('https')));
    expect(spoken, isNot(contains('print')));
  });

  test('una divergencia por delante de lo hablado continúa sin corte', () {
    // Spec 048/US1: con solo "Uno." completado y nada sonando, reescribir lo
    // pendiente NO invalida la reproducción; la cola continúa corregida.
    final q = queue();
    q.observe('Uno. Dos. Tres.', terminal: true);
    final revision = q.revision;
    expect(q.completeCurrent(revision), isTrue);
    expect(q.cursor, 1);

    final update = q.observe('Uno. Cambio. Final.', terminal: true);

    expect(update.revisionChanged, isFalse);
    expect(update.divergenceIndex, 1);
    expect(q.revision, revision);
    expect(q.cursor, 1);
    expect(q.current?.text, 'Cambio.');
  });

  test('una divergencia bajo lo ya hablado sí corta y retrocede', () {
    final q = queue();
    q.observe('Uno. Dos. Tres.', terminal: true);
    final revision = q.revision;
    expect(q.completeCurrent(revision), isTrue);
    expect(q.cursor, 1);

    final update = q.observe('Cambio. Dos. Tres.', terminal: true);

    expect(update.revisionChanged, isTrue);
    expect(q.revision, isNot(revision));
    expect(q.cursor, 0);
    expect(q.current?.text, 'Cambio.');
  });

  test('Pause conserva la frase y una completion vieja no avanza', () {
    final q = queue();
    q.observe('Primera. Segunda.', terminal: true);
    final revision = q.revision;

    q.pause();
    expect(q.current, isNull);
    expect(q.cursor, 0);
    q.reset();
    expect(q.completeCurrent(revision), isFalse);
    expect(q.cursor, 0);
  });

  test('Stop-and-talk silencia la revisión sin borrar texto ni cursor', () {
    final q = queue();
    q.observe('Primera. Segunda.', terminal: true);

    q.silence();

    expect(q.current, isNull);
    expect(q.rawObserved, 'Primera. Segunda.');
    expect(q.chunks, hasLength(2));
    expect(q.cursor, 0);
  });

  test('steer reanuda solo desde el final ya visible', () {
    final q = queue();
    q.observe('Primera. Segunda.');
    q.silence();
    q.observe('Primera. Segunda. Texto acumulado mientras hablo.');

    q.resumeFromVisibleEnd();
    expect(q.hasPending, isFalse);
    q.observe(
      'Primera. Segunda. Texto acumulado mientras hablo. Nueva respuesta.',
    );

    expect(q.current?.text, 'Nueva respuesta.');
  });

  test('el terminal publica la cola parcial pendiente', () {
    final q = queue();
    q.observe('Una última frase sin puntuación');
    expect(q.chunks, isEmpty);

    q.observe('Una última frase sin puntuación', terminal: true);
    expect(q.current?.text, 'Una última frase sin puntuación.');
  });

  test('un feed creciente conserva un único cursor sin repetir el prefijo', () {
    final q = queue();

    q.observe('Voy a revisarlo.');
    final revision = q.revision;
    expect(q.completeCurrent(revision), isTrue);

    final update = q.observe(
      'Voy a revisarlo. Todo está correcto.',
      terminal: true,
    );

    expect(update.revisionChanged, isFalse);
    expect(q.revision, revision);
    expect(q.cursor, 1);
    expect(q.current?.text, 'Todo está correcto.');
    expect(
      q.chunks.where((chunk) => chunk.text == 'Voy a revisarlo.'),
      hasLength(1),
    );
  });

  test('whitespace incremental no crea locuciones ni pausas artificiales', () {
    final q = queue();

    q.observe('  \n\t');
    expect(q.chunks, isEmpty);

    q.observe('Primera frase.');
    final before = q.chunks;
    expect(before, hasLength(1));
    expect(before.single.text.trim(), isNotEmpty);

    final update = q.observe('Primera frase.   \n \t');

    expect(update.queueChanged, isFalse);
    expect(q.chunks, hasLength(1));
    expect(q.chunks.single.text, before.single.text);
    expect(q.chunks.single.pauseAfter, before.single.pauseAfter);
    expect(q.chunks.every((chunk) => chunk.text.trim().isNotEmpty), isTrue);
  });

  test('un bloque de fuentes incremental nunca entra en la cola oral', () {
    final q = queue();

    q.observe('Resumen confirmado.\n\n### Fuentes\n');
    expect(q.chunks.map((chunk) => chunk.text), ['Resumen confirmado.']);

    q.observe(
      'Resumen confirmado.\n\n### Fuentes\n'
      '- RTVE: https://www.rtve.es/noticias/\n'
      '- https://efe.com/portada-espana/',
      terminal: true,
    );

    expect(q.chunks.map((chunk) => chunk.text), ['Resumen confirmado.']);
  });

  test('flush releases a sealed tail without ending the turn (Desktop '
      'session.flush)', () {
    final q = queue();

    q.observe('Voy a revisar el repositorio');
    expect(q.chunks, isEmpty);

    q.observe('Voy a revisar el repositorio', flush: true);
    expect(q.chunks.map((chunk) => chunk.text), [
      'Voy a revisar el repositorio.',
    ]);
    expect(q.terminal, isFalse);

    q.observe('Voy a revisar el repositorio\n\nTodo en ord');
    expect(q.chunks.map((chunk) => chunk.text), [
      'Voy a revisar el repositorio.',
    ]);

    q.observe('Voy a revisar el repositorio\n\nTodo en orden.', terminal: true);
    expect(q.chunks.map((chunk) => chunk.text), [
      'Voy a revisar el repositorio.',
      'Todo en orden.',
    ]);
  });

  test('a flushed chunk that already played is not read again', () {
    final q = queue();

    q.observe('Miro el registro:', flush: true);
    expect(q.chunks, hasLength(1));
    q.markPlaybackThrough(1);
    expect(q.completeCurrent(q.revision), isTrue);

    final update = q.observe('Miro el registro:\n\nSin errores.');
    expect(update.revisionChanged, isFalse);
    expect(q.cursor, 1);
    expect(q.current?.text, 'Sin errores.');
  });
}
