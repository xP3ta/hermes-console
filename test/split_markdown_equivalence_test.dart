import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:hermes_android/core/screens/chat_screen.dart';

/// Corpus variado: el troceado debe respetar vallas de código, tablas GFM,
/// listas flojas, citas y definiciones de referencia.
List<String> _corpus() {
  final rnd = Random(20260924);
  final docs = <String>[];

  String paragraph(int i) =>
      'Parrafo $i con **negrita**, `codigo` y un [enlace][ref$i] que '
      'continua durante una linea razonablemente larga para el corte.';

  // 1) Prosa larga simple.
  docs.add(List.generate(400, paragraph).join('\n\n'));

  // 2) Prosa con vallas de código intercaladas.
  final fenced = StringBuffer();
  for (var i = 0; i < 260; i++) {
    fenced.writeln(paragraph(i));
    fenced.writeln();
    if (i % 5 == 0) {
      fenced.writeln('```dart');
      fenced.writeln('void bloque$i() {');
      fenced.writeln("  print('linea larga dentro de la valla $i');");
      fenced.writeln('}');
      fenced.writeln('```');
      fenced.writeln();
    }
  }
  docs.add(fenced.toString());

  // 3) Tablas GFM + listas + citas.
  final mixed = StringBuffer();
  for (var i = 0; i < 160; i++) {
    mixed.writeln('## Seccion $i');
    mixed.writeln();
    mixed.writeln('| col A | col B |');
    mixed.writeln('| --- | --- |');
    mixed.writeln('| dato $i | valor $i |');
    mixed.writeln();
    mixed.writeln('- item uno de $i');
    mixed.writeln('- item dos de $i');
    mixed.writeln();
    mixed.writeln('> cita de la seccion $i');
    mixed.writeln();
    mixed.writeln(paragraph(i));
    mixed.writeln();
  }
  docs.add(mixed.toString());

  // 4) Definiciones de referencia al final (caso frágil del corte).
  final refs = StringBuffer(List.generate(300, paragraph).join('\n\n'));
  refs.writeln();
  refs.writeln();
  for (var i = 0; i < 300; i++) {
    refs.writeln('[ref$i]: https://example.invalid/$i');
  }
  docs.add(refs.toString());

  // 5) Un bloque indivisible gigantesco.
  docs.add(
    '```\n${List.generate(1200, (i) => 'linea $i sin frontera').join('\n')}\n```',
  );

  // 6) Aleatorio reproducible.
  for (var d = 0; d < 3; d++) {
    final b = StringBuffer();
    for (var i = 0; i < 220; i++) {
      switch (rnd.nextInt(4)) {
        case 0:
          b.writeln(paragraph(i));
          break;
        case 1:
          b.writeln('```\ncodigo $i\n```');
          break;
        case 2:
          b.writeln('1. uno $i\n2. dos $i');
          break;
        default:
          b.writeln('### titulo $i');
      }
      b.writeln();
    }
    docs.add(b.toString());
  }
  return docs;
}

void main() {
  test('el troceado reconstruye el documento y respeta su estructura', () {
    for (final (index, doc) in _corpus().indexed) {
      final parts = splitAssistantMarkdownForViewport(doc);
      expect(parts.join(), doc, reason: 'doc $index debe reconstruirse');
      expect(parts.any((p) => p.isEmpty), isFalse);
      // Cada parte debe renderizar igual aislada que dentro del documento:
      // es la garantía que hace seguro repartirla en varios MarkdownBody.
      final rebuilt = parts
          .map(
            (part) => md.markdownToHtml(
              part,
              extensionSet: md.ExtensionSet.gitHubFlavored,
              encodeHtml: false,
            ),
          )
          .join();
      final whole = md.markdownToHtml(
        doc,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        encodeHtml: false,
      );
      if (parts.length > 1) {
        expect(
          rebuilt,
          whole,
          reason: 'doc $index cambia de render al trocear',
        );
      }
    }
  });

  test('trocear una respuesta larga entra en presupuesto interactivo', () {
    // El troceado corre en el hilo de UI al entrar una respuesta en viewport.
    // Verificar cada frontera contra el resto del documento lo hacía crecer
    // con el cuadrado de la longitud: 63 KB tardaban ~520 ms y un documento
    // con definiciones de referencia llegaba a ~38 s.
    //
    // La medida es RELATIVA: un umbral en milisegundos depende de la carga de
    // la máquina y parpadea cuando la suite corre en paralelo. Lo que delata
    // la regresión es la FORMA de la curva: al cuadruplicar el texto, un
    // coste lineal se multiplica por ~4 y uno cuadrático por ~16.
    String prosa(int chars) => List.generate(
      chars ~/ 55,
      (i) => 'linea $i de markdown con **negrita** y `codigo` aqui',
    ).join('\n\n');

    int microsPara(String texto) {
      final sw = Stopwatch()..start();
      splitAssistantMarkdownForViewport(texto);
      sw.stop();
      return sw.elapsedMicroseconds;
    }

    final corto = prosa(16000);
    final largo = prosa(64000);
    // Calentamiento: la primera pasada paga la compilación JIT.
    microsPara(corto);

    var mejorCorto = microsPara(corto);
    var mejorLargo = microsPara(largo);
    for (var intento = 0; intento < 2; intento++) {
      final c = microsPara(corto);
      final l = microsPara(largo);
      if (c < mejorCorto) mejorCorto = c;
      if (l < mejorLargo) mejorLargo = l;
    }

    // x4 de texto: lineal ~4x, cuadrático ~16x. El corte en 8 separa ambos
    // casos con holgura y usa el mejor de tres para absorber el ruido de
    // planificación cuando otras suites compiten por la CPU.
    expect(
      mejorLargo / mejorCorto,
      lessThan(8),
      reason:
          'coste cuadrático al trocear: x4 de texto pasó de $mejorCorto a '
          '$mejorLargo microsegundos',
    );

    final prosaConRefs = List.generate(
      300,
      (i) => 'Parrafo $i con [enlace][ref$i] y texto adicional para llenar.',
    ).join('\n\n');
    final definiciones = List.generate(
      300,
      (i) => '[ref$i]: https://example.invalid/$i',
    ).join('\n');
    final refs = '$prosaConRefs\n\n$definiciones';
    final withRefs = Stopwatch()..start();
    splitAssistantMarkdownForViewport(refs);
    withRefs.stop();
    expect(
      withRefs.elapsedMilliseconds,
      lessThan(15000),
      reason: 'las definiciones de referencia no pueden colgar la UI 38s',
    );
  });
}
