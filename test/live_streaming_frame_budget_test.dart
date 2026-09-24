import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/utils/streaming_normalizer.dart';

/// La ruta viva de streaming corre entera en CADA frame mientras el modelo
/// escribe: si excede el presupuesto de 16,7ms a 60fps, el chat se congela
/// justo cuando el usuario está mirando.
void main() {
  String buildDoc(int chars) => List.generate(
    chars ~/ 55,
    (i) => 'linea $i de markdown con **negrita** y `codigo` aqui',
  ).join('\n\n');

  double perFrameMs(String text, {int frames = 30}) {
    final sw = Stopwatch()..start();
    for (var k = 0; k < frames; k++) {
      final prepared = prepareAssistantAnswerStructure(text);
      final escaped = escapePathGlobs(prepared);
      final tailStart = streamingMarkdownTailStart(escaped);
      normalizeStreamingMarkdown(
        tailStart > 0 ? escaped.substring(tailStart) : escaped,
        isStreaming: true,
      );
    }
    sw.stop();
    return sw.elapsedMicroseconds / frames / 1000;
  }

  test('una respuesta viva larga no revienta el presupuesto de frame', () {
    // Umbral generoso: sólo atrapa el orden de magnitud del fallo (280ms por
    // frame), sin parpadear cuando otras suites compiten por la CPU.
    expect(
      perFrameMs(buildDoc(60000)),
      lessThan(120),
      reason:
          'la ruta viva corre por frame: a 280ms el chat se congela al escribir',
    );
  });

  test('el coste por frame crece de forma lineal, no cuadrática', () {
    // Medida relativa, invariante a la carga de la máquina: al cuadruplicar
    // el texto un coste lineal se multiplica por ~4 y uno cuadrático por ~16.
    perFrameMs(buildDoc(15000), frames: 5); // calentamiento JIT
    var small = perFrameMs(buildDoc(15000));
    var big = perFrameMs(buildDoc(60000));
    for (var intento = 0; intento < 2; intento++) {
      final s = perFrameMs(buildDoc(15000));
      final b = perFrameMs(buildDoc(60000));
      if (s < small) small = s;
      if (b < big) big = b;
    }
    expect(
      big / small,
      lessThan(8),
      reason: 'coste cuadrático: x4 de texto pasó de $small a $big ms/frame',
    );
  });

  test(
    'el delimitador de matemáticas sigue detectándose dentro de la línea',
    () {
      // El escaneo acotado no puede perder bloques $$...$$ legítimos.
      const withMath =
          'texto previo\n\n'
          r'$$a = b$$'
          '\n\nmas texto\n\npárrafo final';
      final tail = streamingMarkdownTailStart(withMath);
      expect(tail, greaterThan(0), reason: 'debe localizar una cola segura');
      expect(withMath.substring(tail).isNotEmpty, isTrue);

      // Un $$ abierto sin cerrar mantiene el bloque unido: no se puede cortar
      // dentro de una fórmula a medio llegar.
      const openMath =
          'intro\n\n'
          r'$$x = 1'
          '\n\nsigue dentro de la formula';
      expect(
        openMath.substring(streamingMarkdownTailStart(openMath)),
        contains(r'$$'),
        reason: 'una formula abierta no debe quedar partida',
      );
    },
  );
}
