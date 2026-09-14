import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';

/// Spec 048 / US5 — TTS del servidor Hermes (contracts/native-voice.md):
/// `{text}` → data_url base64 → bytes al playback; errores limpios para la
/// cadena de fallback; stop aborta la petición en vuelo.
class _Playback implements TtsAudioPlayback {
  final _completions = StreamController<void>.broadcast();
  final List<(Uint8List, String)> played = [];
  int stopCalls = 0;

  @override
  Stream<void> get onComplete => _completions.stream;

  @override
  Future<void> playBytes(Uint8List bytes, {required String mimeType}) async {
    played.add((bytes, mimeType));
    scheduleMicrotask(() => _completions.add(null));
  }

  @override
  Future<void> playFile(String path) async {
    throw StateError('el TTS servidor reproduce bytes, no ficheros');
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  final audio = Uint8List.fromList(List.generate(64, (i) => i));

  test('speak sintetiza en el servidor y reproduce los bytes', () async {
    final requests = <String>[];
    final playback = _Playback();
    final engine = HermesServerTtsEngine(
      synthesize: (text) async {
        requests.add(text);
        return {
          'ok': true,
          'data_url': 'data:audio/mpeg;base64,${base64Encode(audio)}',
          'mime_type': 'audio/mpeg',
          'provider': 'edge',
        };
      },
      playback: playback,
      playbackFactory: _Playback.new,
    );
    addTearDown(engine.dispose);

    await engine.speak('Hola desde el servidor.');

    expect(requests, ['Hola desde el servidor.']);
    expect(playback.played, hasLength(1));
    expect(playback.played.single.$1, audio);
    expect(playback.played.single.$2, 'audio/mpeg');
  });

  test(
    'prewarm prepara un único lote sin reproducirlo y speak lo reutiliza',
    () async {
      final requests = <String>[];
      final playback = _Playback();
      final engine = HermesServerTtsEngine(
        synthesize: (text) async {
          requests.add(text);
          return {
            'ok': true,
            'data_url': 'data:audio/mpeg;base64,${base64Encode(audio)}',
          };
        },
        playback: playback,
        playbackFactory: _Playback.new,
      );
      addTearDown(engine.dispose);

      await engine.prewarm('Siguiente lote.');
      expect(requests, ['Siguiente lote.']);
      expect(playback.played, isEmpty);

      await engine.speak('Siguiente lote.');
      expect(requests, ['Siguiente lote.']);
      expect(playback.played, hasLength(1));
    },
  );

  test('speak espera una precarga en vuelo sin duplicar la petición', () async {
    final gate = Completer<void>();
    final requests = <String>[];
    final playback = _Playback();
    final engine = HermesServerTtsEngine(
      synthesize: (text) async {
        requests.add(text);
        await gate.future;
        return {
          'ok': true,
          'data_url': 'data:audio/mpeg;base64,${base64Encode(audio)}',
        };
      },
      playback: playback,
      playbackFactory: _Playback.new,
    );
    addTearDown(engine.dispose);

    final warming = engine.prewarm('Lote en vuelo.');
    await Future<void>.delayed(Duration.zero);
    final speaking = engine.speak('Lote en vuelo.');
    await Future<void>.delayed(Duration.zero);
    expect(requests, ['Lote en vuelo.']);

    gate.complete();
    await Future.wait([warming, speaking]);
    expect(requests, ['Lote en vuelo.']);
    expect(playback.played, hasLength(1));
  });

  test(
    'precalentar N+1 no expulsa el lote N antes de que speak lo reclame',
    () async {
      final requests = <String>[];
      final playback = _Playback();
      final engine = HermesServerTtsEngine(
        synthesize: (text) async {
          requests.add(text);
          return {
            'ok': true,
            'data_url': 'data:audio/mpeg;base64,${base64Encode(audio)}',
          };
        },
        playback: playback,
        playbackFactory: _Playback.new,
      );
      addTearDown(engine.dispose);

      // El controlador encola N y, antes de que el drenador llegue a speak(),
      // empieza a preparar N+1. Una caché de una sola entrada expulsaba N y lo
      // sintetizaba por segunda vez, dejando 3–5 s de silencio en el Pixel.
      await engine.prewarm('Lote N.');
      await engine.prewarm('Lote N+1.');
      await engine.speak('Lote N.');
      await engine.speak('Lote N+1.');

      expect(requests, ['Lote N.', 'Lote N+1.']);
      expect(playback.played, hasLength(2));
    },
  );

  test('una respuesta sin audio lanza sin copiar detalle remoto', () async {
    final engine = HermesServerTtsEngine(
      synthesize: (text) async => {
        'ok': false,
        'detail': 'PRIVATE_TTS_SERVER_DETAIL /home/server/audio.wav',
      },
      playback: _Playback(),
      playbackFactory: _Playback.new,
    );
    addTearDown(engine.dispose);

    await expectLater(
      engine.speak('Hola.'),
      throwsA(
        predicate<Object>(
          (error) =>
              !error.toString().contains('PRIVATE_TTS_SERVER_DETAIL') &&
              !error.toString().contains('/home/server'),
        ),
      ),
    );
  });

  test('un error de red lanza para activar el fallback', () async {
    final engine = HermesServerTtsEngine(
      synthesize: (text) async => throw Exception('timeout'),
      playback: _Playback(),
      playbackFactory: _Playback.new,
    );
    addTearDown(engine.dispose);

    await expectLater(engine.speak('Hola.'), throwsException);
  });

  test('stop durante la petición descarta el audio sin reproducir', () async {
    final gate = Completer<void>();
    final playback = _Playback();
    final engine = HermesServerTtsEngine(
      synthesize: (text) async {
        await gate.future;
        return {
          'ok': true,
          'data_url': 'data:audio/wav;base64,${base64Encode(audio)}',
        };
      },
      playback: playback,
      playbackFactory: _Playback.new,
    );
    addTearDown(engine.dispose);

    final speaking = engine.speak('Hola.');
    await engine.stop();
    gate.complete();
    await speaking;

    expect(playback.played, isEmpty);
  });
}
