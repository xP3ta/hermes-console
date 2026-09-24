import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/services/sse_frame_buffer.dart';

/// Los lectores SSE reensamblan frames que llegan partidos por la red. El
/// acumulador no puede perder un separador que quede a caballo entre dos
/// trozos, ni volverse cuadrático al crecer el payload.
List<String> drenarFrames(List<String> trozos) {
  final buf = SseFrameBuffer();
  final frames = <String>[];
  for (final chunk in trozos) {
    frames.addAll(buf.addChunk(chunk));
  }
  return frames;
}

void main() {
  test('un separador partido entre dos trozos no se pierde', () {
    // El caso que rompe una búsqueda reanudable ingenua: «\n» al final de un
    // trozo y «\n» al principio del siguiente.
    expect(drenarFrames(['data: uno\n', '\ndata: dos\n\n']), [
      'data: uno',
      'data: dos',
    ]);
    // Y con el separador entero en el límite exacto.
    expect(drenarFrames(['data: uno\n\n', 'data: dos\n\n']), [
      'data: uno',
      'data: dos',
    ]);
    // Varios frames dentro de un único trozo.
    expect(drenarFrames(['a\n\nb\n\nc\n\n']), ['a', 'b', 'c']);
    // Trozo vacío intercalado.
    expect(drenarFrames(['a\n', '', '\nb\n\n']), ['a', 'b']);
  });

  test('fuzz: trocear el flujo en cualquier punto da los mismos frames', () {
    final rnd = Random(20260924);
    for (var caso = 0; caso < 300; caso++) {
      final cuantos = 1 + rnd.nextInt(8);
      final esperados = <String>[];
      final flujo = StringBuffer();
      for (var i = 0; i < cuantos; i++) {
        // Payloads con saltos simples dentro, que no deben cortar el frame.
        final cuerpo = List.generate(
          1 + rnd.nextInt(4),
          (l) => 'data: campo$l del frame $i',
        ).join('\n');
        esperados.add(cuerpo);
        flujo
          ..write(cuerpo)
          ..write('\n\n');
      }
      final texto = flujo.toString();

      // Partirlo en trozos aleatorios, como haría la red.
      final trozos = <String>[];
      var pos = 0;
      while (pos < texto.length) {
        final tam = 1 + rnd.nextInt(7);
        trozos.add(texto.substring(pos, min(pos + tam, texto.length)));
        pos += tam;
      }

      expect(
        drenarFrames(trozos),
        esperados,
        reason: 'caso $caso: el reensamblado perdió o partió frames',
      );
    }
  });

  test('el coste de ensamblar un frame grande es lineal, no cuadrático', () {
    List<String> trocear(int kb) {
      final payload = 'x' * (kb * 1024);
      final trozos = <String>[];
      for (var i = 0; i < payload.length; i += 1400) {
        trozos.add(payload.substring(i, min(i + 1400, payload.length)));
      }
      return trozos..add('\n\n');
    }

    int micros(int kb) {
      final trozos = trocear(kb);
      final sw = Stopwatch()..start();
      drenarFrames(trozos);
      sw.stop();
      return sw.elapsedMicroseconds;
    }

    micros(64); // calentamiento
    var pequeno = micros(64);
    var grande = micros(256);
    for (var intento = 0; intento < 2; intento++) {
      pequeno = min(pequeno, micros(64));
      grande = min(grande, micros(256));
    }
    // x4 de tamaño: lineal ~4x, cuadrático ~16x.
    expect(
      grande / pequeno,
      lessThan(8),
      reason:
          'reensamblado cuadrático: x4 de payload pasó de $pequeno a $grande us',
    );
  });
}
