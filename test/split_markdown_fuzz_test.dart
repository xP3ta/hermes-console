import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:markdown/markdown.dart' as md;

/// El troceado reparte una respuesta en varios MarkdownBody. Si una parte
/// renderiza distinto aislada que dentro del documento, el usuario ve el texto
/// deformado. El atajo de prosa simple evita el parseo de verificación, así
/// que hay que demostrar que nunca se lo salta cuando importa.
String? _html(String source) {
  try {
    return md.markdownToHtml(
      source,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );
  } catch (_) {
    return null;
  }
}

void main() {
  test('fuzz: trocear nunca altera el render, con markdown arbitrario', () {
    // Semilla fija: un fallo debe poder reproducirse exactamente.
    final rnd = Random(20260924);
    const piezas = [
      'Un parrafo normal con **negrita**, _cursiva_ y `codigo` suelto.',
      '- item de lista\n- otro item\n- tercero',
      '1. primero\n2. segundo\n3. tercero',
      '> una cita que ocupa\n> dos lineas seguidas',
      '```dart\nvoid main() {\n  print("hola");\n}\n```',
      '| col a | col b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |',
      '## Un encabezado',
      'Texto con [enlace][ref] que se define abajo.',
      '[ref]: https://example.invalid/destino',
      'Encabezado subrayado\n====================',
      '    bloque indentado de cuatro espacios',
      '<div>html embebido</div>',
      'Parrafo con asteriscos sueltos * y guiones - en medio.',
      'Una linea\ncon salto simple dentro del mismo parrafo.',
      '~~~\nvalla con tildes\n~~~',
      '* lista con asterisco\n* segunda',
    ];

    for (var caso = 0; caso < 400; caso++) {
      final bloques = 12 + rnd.nextInt(90);
      final buffer = StringBuffer();
      for (var i = 0; i < bloques; i++) {
        buffer.write(piezas[rnd.nextInt(piezas.length)]);
        buffer.write('\n\n');
        // Relleno variable para empujar las fronteras a sitios distintos.
        if (rnd.nextBool()) {
          buffer.write('Relleno $i: ');
          buffer.write('palabra ' * (5 + rnd.nextInt(60)));
          buffer.write('\n\n');
        }
      }
      final doc = buffer.toString();
      final partes = splitAssistantMarkdownForViewport(doc);

      expect(
        partes.join(),
        doc,
        reason: 'caso $caso: el troceado debe reconstruir el texto exacto',
      );
      if (partes.length <= 1) continue;

      final entero = _html(doc);
      if (entero == null) continue;
      final recompuesto = StringBuffer();
      var alguna = false;
      for (final parte in partes) {
        final h = _html(parte);
        if (h == null) {
          alguna = true;
          break;
        }
        recompuesto.write(h);
      }
      if (alguna) continue;
      expect(
        recompuesto.toString(),
        entero,
        reason:
            'caso $caso: trocear cambió el render (${partes.length} partes, '
            '${doc.length} caracteres)',
      );
    }
  });

  test('el atajo de prosa simple no se aplica a markdown estructurado', () {
    // Cada una de estas construcciones debe forzar la ruta verificada.
    const estructurados = <String>[
      '- lista',
      '1. numerada',
      '> cita',
      '```\ncodigo\n```',
      '| a | b |\n| - | - |',
      '[ref]: https://example.invalid',
      '<div>html</div>',
      '    indentado',
      'Subrayado\n=========',
    ];
    for (final pieza in estructurados) {
      final doc =
          '${'Parrafo de relleno con texto suficiente. ' * 200}\n\n'
          '$pieza\n\n'
          '${'Mas relleno para pasar del umbral de troceado. ' * 200}';
      final partes = splitAssistantMarkdownForViewport(doc);
      if (partes.length <= 1) continue;
      final entero = _html(doc);
      final recompuesto = partes.map(_html).join();
      expect(
        recompuesto,
        entero,
        reason: 'la construcción «$pieza» cambió de render al trocear',
      );
    }
  });
}
