import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/stt_sherpa.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';
import 'package:hermes_android/core/services/voice/tts_model_manager.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';

void main() {
  group('VoiceSettings', () {
    test('enums parsean por id y caen al default', () {
      expect(SttEngineKind.from('whisper'), SttEngineKind.whisper);
      expect(SttEngineKind.from('sherpa_live'), SttEngineKind.sherpaLive);
      expect(SttEngineKind.from('hermes_server'), SttEngineKind.hermesServer);
      expect(SttEngineKind.from('server'), SttEngineKind.server);
      // El default es Live on-device: privado y con texto parcial.
      expect(SttEngineKind.from('nope'), SttEngineKind.sherpaLive);
      expect(TtsEngineKind.from('elevenlabs'), TtsEngineKind.elevenlabs);
      expect(TtsEngineKind.from('custom_http'), TtsEngineKind.customHttp);
      expect(TtsEngineKind.from(null), TtsEngineKind.onnx);
      expect(
        ReadAloudStopBehavior.from('stop_and_restart'),
        ReadAloudStopBehavior.stopAndRestart,
      );
      expect(
        ReadAloudStopBehavior.from('valor_desconocido'),
        ReadAloudStopBehavior.pauseAndResume,
      );
    });

    test(
      'STT por servidor: motor + URL hacen round-trip (token aparte)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        const s = VoiceSettings(
          sttEngine: SttEngineKind.server,
          serverSttUrl: 'ws://192.168.1.20:9123',
        );
        await s.save(prefs);
        final loaded = VoiceSettings.load(prefs);
        expect(loaded.sttEngine, SttEngineKind.server);
        expect(loaded.serverSttUrl, 'ws://192.168.1.20:9123');
      },
    );

    test('catálogo sherpa: 3 modelos ES, transducer solo Parakeet', () {
      expect(kSherpaSttModels.length, 3);
      expect(kSherpaSttModels.map((m) => m.kind).toSet(), {
        SherpaModelKind.whisperBase,
        SherpaModelKind.whisperSmall,
        SherpaModelKind.parakeetV3,
      });
      // Whisper = encoder+decoder (sin joiner); Parakeet = transductor.
      for (final m in kSherpaSttModels) {
        if (m.kind == SherpaModelKind.parakeetV3) {
          expect(m.isTransducer, isTrue);
          expect(m.joiner, isNotEmpty);
          expect(m.heavyRam, isTrue); // ~1.2 GB → avisa de RAM
        } else {
          expect(m.isTransducer, isFalse);
          expect(m.joiner, isEmpty);
        }
        expect(m.url, contains('k2-fsa/sherpa-onnx'));
      }
      expect(
        sherpaModelByKind(SherpaModelKind.whisperSmall).displayName,
        'Whisper small',
      );
    });

    test('STT en vivo (sherpa): modelo elegido hace round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const s = VoiceSettings(
        sttEngine: SttEngineKind.sherpaLive,
        sherpaModel: SherpaModelKind.parakeetV3,
      );
      await s.save(prefs);
      final loaded = VoiceSettings.load(prefs);
      expect(loaded.sttEngine, SttEngineKind.sherpaLive);
      expect(loaded.sherpaModel, SherpaModelKind.parakeetV3);
    });

    test('load/save hace round-trip en prefs', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const s = VoiceSettings(
        sttEngine: SttEngineKind.whisper,
        ttsEngine: TtsEngineKind.elevenlabs,
        autoSpeak: true,
        readAloudStopBehavior: ReadAloudStopBehavior.stopAndRestart,
        elevenVoiceId: 'voiceX',
        elevenModelId: 'eleven_multilingual_v2',
      );
      await s.save(prefs);
      final loaded = VoiceSettings.load(prefs);
      expect(loaded.sttEngine, SttEngineKind.whisper);
      expect(loaded.ttsEngine, TtsEngineKind.elevenlabs);
      expect(loaded.autoSpeak, isTrue);
      expect(
        loaded.readAloudStopBehavior,
        ReadAloudStopBehavior.stopAndRestart,
      );
      expect(loaded.elevenVoiceId, 'voiceX');
    });

    test('defaults: live on-device + onnx, sin auto-leer', () {
      const d = VoiceSettings();
      expect(d.sttEngine, SttEngineKind.sherpaLive);
      expect(d.ttsEngine, TtsEngineKind.onnx);
      expect(d.autoSpeak, isFalse);
      expect(d.readAloudStopBehavior, ReadAloudStopBehavior.pauseAndResume);
      expect(d.elevenModelId, 'eleven_multilingual_v2');
    });

    test('motor onnx parsea y onnxVoiceId hace round-trip', () async {
      expect(TtsEngineKind.from('onnx'), TtsEngineKind.onnx);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const s = VoiceSettings(
        ttsEngine: TtsEngineKind.onnx,
        onnxVoiceId: 'es_MX-claude-high',
      );
      await s.save(prefs);
      final loaded = VoiceSettings.load(prefs);
      expect(loaded.ttsEngine, TtsEngineKind.onnx);
      expect(loaded.onnxVoiceId, 'es_MX-claude-high');
    });

    test('TTS de Hermes legacy migra a la voz neuronal local', () async {
      SharedPreferences.setMockInitialValues({
        'voice_tts_engine': 'hermes_server',
      });
      final prefs = await SharedPreferences.getInstance();

      final loaded = VoiceSettings.load(prefs);
      expect(loaded.ttsEngine, TtsEngineKind.onnx);
      expect(prefs.getString('voice_tts_engine'), 'onnx');
    });

    test(
      'TTS REST personalizado hace round-trip sin incluir el secreto',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        const settings = VoiceSettings(
          ttsEngine: TtsEngineKind.customHttp,
          customTtsUrl: 'https://tts.example.com/speech',
          customTtsVoice: 'maria',
          customTtsModel: 'neural-v3',
          customTtsBodyTemplate: '{"input":"{{text}}"}',
          customTtsAuthMode: CustomTtsAuthMode.apiKey,
          customTtsHeaderName: 'x-api-key',
          customTtsHeaderPrefix: '',
          customTtsResponseKind: CustomTtsResponseKind.jsonBase64,
          customTtsBase64Path: 'data.audio',
          customTtsMimeType: 'audio/wav',
        );
        await settings.save(prefs);
        final loaded = VoiceSettings.load(prefs);
        expect(loaded.ttsEngine, TtsEngineKind.customHttp);
        expect(loaded.customTtsUrl, 'https://tts.example.com/speech');
        expect(loaded.customTtsAuthMode, CustomTtsAuthMode.apiKey);
        expect(loaded.customTtsResponseKind, CustomTtsResponseKind.jsonBase64);
        expect(loaded.customTtsBase64Path, 'data.audio');
        expect(
          prefs.getKeys().where((key) => key.contains('secret')),
          isEmpty,
          reason: 'la credencial nunca forma parte de VoiceSettings',
        );
      },
    );
  });

  group('Catálogo de voces neuronales', () {
    test('hay voces y los ids son únicos', () {
      expect(kNeuralVoices, isNotEmpty);
      final ids = kNeuralVoices.map((v) => v.id).toSet();
      expect(ids.length, kNeuralVoices.length);
    });

    test('cada voz tiene URL .tar.bz2 y onnx coherente con dirName', () {
      for (final v in kNeuralVoices) {
        expect(v.url, endsWith('.tar.bz2'));
        expect(v.url, contains(v.dirName));
        expect(v.onnxFile, endsWith('.onnx'));
        expect(v.sizeMb, greaterThan(0));
        expect(v.archiveBytes, greaterThan(1024 * 1024));
        expect(v.archiveSha256, matches(RegExp(r'^[a-f0-9]{64}$')));
      }
    });

    test('neuralVoiceById resuelve y devuelve null si no existe', () {
      expect(neuralVoiceById('es_ES-davefx-medium')?.id, 'es_ES-davefx-medium');
      expect(neuralVoiceById('no-existe'), isNull);
    });

    test('el onnxVoiceId por defecto existe en el catálogo', () {
      const d = VoiceSettings();
      expect(neuralVoiceById(d.onnxVoiceId), isNotNull);
    });
  });

  group('ElevenLabsTtsEngine.buildRequest', () {
    test('URL, header de clave y body correctos', () {
      final r = ElevenLabsTtsEngine.buildRequest(
        apiKey: 'sk-123',
        voiceId: 'abc',
        text: 'hola',
        modelId: 'eleven_multilingual_v2',
      );
      expect(
        r.uri.toString(),
        'https://api.elevenlabs.io/v1/text-to-speech/abc',
      );
      expect(r.headers['xi-api-key'], 'sk-123');
      expect(r.headers['Accept'], 'audio/mpeg');
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect(body['text'], 'hola');
      expect(body['model_id'], 'eleven_multilingual_v2');
    });

    test('trunca el texto muy largo', () {
      final long = 'a' * 9000;
      final r = ElevenLabsTtsEngine.buildRequest(
        apiKey: 'k',
        voiceId: 'v',
        text: long,
        modelId: 'm',
      );
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect((body['text'] as String).length, lessThanOrEqualTo(5000));
    });
  });

  group('OpenAiStreamingTtsEngine.buildRequest', () {
    test('endpoint, body OpenAI y SIN auth para Kokoro local', () {
      final r = OpenAiStreamingTtsEngine.buildRequest(
        baseUrl: 'http://192.168.1.20:8880/v1',
        voice: 'em_santa',
        model: 'kokoro',
        text: 'hola',
        speed: 0.9,
      );
      expect(r.uri.toString(), 'http://192.168.1.20:8880/v1/audio/speech');
      // Kokoro local sin token: no debe enviarse cabecera Authorization.
      expect(r.headers.containsKey('Authorization'), isFalse);
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect(body['model'], 'kokoro');
      expect(body['voice'], 'em_santa');
      expect(body['input'], 'hola');
      expect(body['response_format'], 'wav');
      // Velocidad un poco por debajo de 1.0: voz más pausada/natural.
      expect(body['speed'], 0.9);
    });

    test('con token añade Bearer y normaliza barras finales', () {
      final r = OpenAiStreamingTtsEngine.buildRequest(
        baseUrl: 'https://api.openai.com/v1/',
        voice: 'onyx',
        model: 'tts-1',
        text: 'hi',
        apiKey: 'sk-abc',
      );
      expect(r.uri.toString(), 'https://api.openai.com/v1/audio/speech');
      expect(r.headers['Authorization'], 'Bearer sk-abc');
    });
  });

  group('Asistente Kokoro', () {
    test('convierte dirección + puerto en la base /v1', () {
      expect(
        KokoroTtsSetup.normalizeBaseUrl(address: '192.168.1.20', port: '8880'),
        'http://192.168.1.20:8880/v1',
      );
      expect(
        KokoroTtsSetup.normalizeBaseUrl(
          address: 'https://voice.example.com/otra-ruta',
          port: '443',
        ),
        'https://voice.example.com/v1',
      );
    });

    test('convierte HTTP público bloqueado en un error comprensible', () {
      expect(
        () => KokoroTtsSetup.normalizeBaseUrl(
          address: 'http://api.openai.com',
          port: '80',
        ),
        throwsA(
          isA<TtsUserException>().having(
            (error) => error.code,
            'code',
            TtsUserError.invalidKokoroAddress,
          ),
        ),
      );
    });

    test('descubre voces del endpoint estable de Kokoro', () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'http://192.168.1.20:8880/v1/audio/voices',
        );
        return http.Response(
          jsonEncode({
            'voices': [
              {'id': 'em_santa'},
              {'id': 'ef_dora'},
            ],
          }),
          200,
        );
      });
      final result = await KokoroTtsSetup.discover(
        address: '192.168.1.20',
        client: client,
      );
      expect(result.baseUrl, 'http://192.168.1.20:8880/v1');
      expect(result.voices, ['em_santa', 'ef_dora']);
    });
  });

  group('CustomHttpTtsEngine', () {
    test('construye JSON seguro y cabecera configurable', () {
      final request = CustomHttpTtsEngine.buildRequest(
        url: 'https://tts.example.com/synthesize',
        bodyTemplate:
            '{"input":"{{text}}","voice":"{{voice}}","model":"{{model}}"}',
        text: 'hola "mundo"\nnueva línea',
        voice: 'maria',
        model: 'v3',
        authHeaderName: 'x-api-key',
        authSecret: 'secret-value',
      );
      expect(request.headers['x-api-key'], 'secret-value');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['input'], 'hola "mundo"\nnueva línea');
      expect(body['voice'], 'maria');
      expect(body['model'], 'v3');
    });

    test('decodifica audio base64 anidado y respeta data URI', () {
      final audio = Uint8List.fromList([82, 73, 70, 70]);
      final response = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'data': {'audio': 'data:audio/wav;base64,${base64Encode(audio)}'},
          }),
        ),
      );
      final decoded = CustomHttpTtsEngine.decodeResponse(
        bodyBytes: response,
        headers: const {'content-type': 'application/json'},
        responseIsJsonBase64: true,
        base64Path: 'data.audio',
      );
      expect(decoded.bytes, audio);
      expect(decoded.mimeType, 'audio/wav');
    });

    test('audio binario usa el MIME real de la respuesta', () {
      final decoded = CustomHttpTtsEngine.decodeResponse(
        bodyBytes: Uint8List.fromList([1, 2, 3]),
        headers: const {'content-type': 'audio/ogg; codecs=opus'},
        responseIsJsonBase64: false,
      );
      expect(decoded.bytes, [1, 2, 3]);
      expect(decoded.mimeType, 'audio/ogg');
    });

    test('autodetecta JSON habitual sin pedir ruta al usuario', () {
      final audio = Uint8List.fromList([82, 73, 70, 70]);
      final decoded = CustomHttpTtsEngine.decodeResponse(
        bodyBytes: Uint8List.fromList(
          utf8.encode(jsonEncode({'audioContent': base64Encode(audio)})),
        ),
        headers: const {'content-type': 'application/json'},
        responseIsJsonBase64: false,
        autoDetect: true,
      );

      expect(decoded.bytes, audio);
    });

    test('autodetección conserva audio binario sin Content-Type', () {
      final decoded = CustomHttpTtsEngine.decodeResponse(
        bodyBytes: Uint8List.fromList([1, 2, 3]),
        headers: const {},
        responseIsJsonBase64: false,
        autoDetect: true,
      );

      expect(decoded.bytes, [1, 2, 3]);
    });
  });

  // Spec 031 (contrato I1/I3): la resolución española queda ANCLADA byte a
  // byte a la histórica — si uno de estos tests falla, hay una regresión en
  // español, no un test desactualizado. No "arreglar" el test: investigar.
  group('Idioma de voz en el dictado (spec 031)', () {
    test('el fin de turno local conserva el ritmo de Hermes Desktop', () {
      expect(kVoiceTurnSilenceTimeout, const Duration(milliseconds: 1250));
      expect(kVoiceTurnMaxDuration, const Duration(seconds: 60));
    });

    test('lista de locales del sistema en español = la histórica exacta', () {
      expect(kSystemSttLocalePrefs['es'], const [
        'es_ES',
        'es_US',
        'es_MX',
        'es_419',
        'es_CO',
        'es_AR',
        'es-ES',
        'es',
      ]);
    });

    test('lista de locales del sistema en inglés según contrato §2', () {
      expect(kSystemSttLocalePrefs['en'], const [
        'en_US',
        'en_GB',
        'en_AU',
        'en_IN',
        'en-US',
        'en',
      ]);
    });

    test('lista de locales del sistema en portugués', () {
      expect(kSystemSttLocalePrefs['pt'], const [
        'pt_BR',
        'pt_PT',
        'pt-BR',
        'pt',
      ]);
    });

    test('la clave del caché de recognizers incluye el idioma', () {
      final base = sherpaModelByKind(SherpaModelKind.whisperBase);
      expect(SherpaSttEngine.recognizerCacheKey(base, 'es'), '${base.id}:es');
      expect(
        SherpaSttEngine.recognizerCacheKey(base, 'en'),
        isNot(SherpaSttEngine.recognizerCacheKey(base, 'es')),
      );
    });
    // Nota: el default lang='es' de los motores no se ancla instanciándolos —
    // sus constructores crean plugins de plataforma (AudioRecorder) que no
    // funcionan en tests de host. Queda anclado por las listas de arriba y por
    // la validación física V5 del quickstart.
  });

  // Spec 031 (contrato I2): defaults por idioma SOLO con clave ausente; una
  // preferencia guardada nunca cambia de valor.
  group('Defaults de voz por idioma (spec 031)', () {
    test(
      'sin elección guardada, app en español → defaults históricos',
      () async {
        SharedPreferences.setMockInitialValues({'app_locale': 'es'});
        final prefs = await SharedPreferences.getInstance();
        final s = VoiceSettings.load(prefs);
        expect(s.onnxVoiceId, 'es_ES-davefx-medium');
        expect(s.streamingTtsVoice, 'em_santa');
      },
    );

    test('sin elección guardada, app en inglés → Amy y af_heart', () async {
      SharedPreferences.setMockInitialValues({'app_locale': 'en'});
      final prefs = await SharedPreferences.getInstance();
      final s = VoiceSettings.load(prefs);
      expect(s.onnxVoiceId, 'en_US-amy-medium');
      expect(s.streamingTtsVoice, 'af_heart');
      // La voz propuesta debe existir de verdad en el catálogo.
      expect(neuralVoiceById(s.onnxVoiceId), isNotNull);
    });

    test('sin elección guardada, app en portugués → Faber y pm_santa', () async {
      SharedPreferences.setMockInitialValues({'app_locale': 'pt'});
      final prefs = await SharedPreferences.getInstance();
      final s = VoiceSettings.load(prefs);
      expect(s.onnxVoiceId, 'pt_BR-faber-medium');
      expect(s.streamingTtsVoice, 'pm_santa');
      // La voz propuesta debe existir de verdad en el catálogo.
      expect(neuralVoiceById(s.onnxVoiceId), isNotNull);
    });

    test('Japanese and Korean start with Android when no voice was chosen', () async {
      for (final language in ['ja', 'ko']) {
        SharedPreferences.setMockInitialValues({'app_locale': language});
        final prefs = await SharedPreferences.getInstance();
        final settings = VoiceSettings.load(prefs);
        expect(settings.ttsEngine, TtsEngineKind.device);
        expect(settings.onnxVoiceId, isEmpty);
      }
    });

    test('una elección guardada se respeta en ambos idiomas', () async {
      for (final locale in const ['es', 'en']) {
        SharedPreferences.setMockInitialValues({
          'app_locale': locale,
          'voice_onnx_voice_id': 'es_MX-claude-high',
          'voice_streaming_tts_voice': 'onyx',
        });
        final prefs = await SharedPreferences.getInstance();
        final s = VoiceSettings.load(prefs);
        expect(
          s.onnxVoiceId,
          'es_MX-claude-high',
          reason: 'app_locale=$locale no debe pisar la elección',
        );
        expect(
          s.streamingTtsVoice,
          'onyx',
          reason: 'app_locale=$locale no debe pisar la elección',
        );
      }
    });

    test('default helpers use English for unknown languages', () {
      expect(VoiceSettings.defaultOnnxVoiceFor('es'), 'es_ES-davefx-medium');
      expect(VoiceSettings.defaultOnnxVoiceFor('xx'), 'en_US-amy-medium');
      expect(VoiceSettings.defaultStreamingVoiceFor('es'), 'em_santa');
      expect(VoiceSettings.defaultStreamingVoiceFor('xx'), 'af_heart');
      expect(VoiceSettings.defaultOnnxVoiceFor('pt'), 'pt_BR-faber-medium');
      expect(VoiceSettings.defaultStreamingVoiceFor('pt'), 'pm_santa');
    });
  });

  // Spec 031 (contrato I1): igual que arriba, pero para la voz del sistema.
  group('Idioma de voz en la lectura (spec 031)', () {
    test('lista de voces del sistema en español = la histórica exacta', () {
      expect(kDeviceTtsLangPrefs['es'], const [
        'es-ES',
        'es-US',
        'es-MX',
        'es-419',
        'es-CO',
        'es-AR',
      ]);
      expect(kDeviceTtsFallback['es'], 'es-ES');
    });

    test('lista de voces del sistema en inglés según contrato §2', () {
      expect(kDeviceTtsLangPrefs['en'], const [
        'en-US',
        'en-GB',
        'en-AU',
        'en-IN',
      ]);
      expect(kDeviceTtsFallback['en'], 'en-US');
    });

    test('lista de voces del sistema en portugués', () {
      expect(kDeviceTtsLangPrefs['pt'], const ['pt-BR', 'pt-PT']);
      expect(kDeviceTtsFallback['pt'], 'pt-BR');
    });
  });
}
