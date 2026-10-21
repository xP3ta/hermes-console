import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/external_provider_screen.dart';
import 'package:hermes_android/core/services/litert_engine.dart';
import 'package:hermes_android/core/services/voice/stt_remote.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fronteras de transporte de proveedores del cliente', () {
    test('proveedor OpenAI-compatible bloquea HTTP público', () {
      expect(
        () => normalizeExternalProviderUrl('http://provider.example.com:11434'),
        throwsArgumentError,
      );
    });

    test('OlliteRT bloquea HTTP público antes de crear el cliente', () {
      expect(
        () => OlliteRtClient(
          baseUrl: 'http://models.example.com:8000',
          token: 'must-stay-local',
        ),
        throwsArgumentError,
      );
    });

    test('STT remoto bloquea WS público antes de enviar audio o token', () {
      expect(
        () => ServerSttEngine(
          baseUrl: 'ws://stt.example.com:9123',
          token: 'must-stay-local',
        ),
        throwsArgumentError,
      );
    });

    test('TTS REST personalizado bloquea HTTP público antes del secreto', () {
      expect(
        () => CustomHttpTtsEngine(
          url: 'http://tts.example.com/speech',
          bodyTemplate: '{"text":"{{text}}"}',
          authSecret: 'must-stay-local',
        ),
        throwsArgumentError,
      );
    });

    test('TTS remoto bloquea HTTP público antes de enviar texto o token', () {
      expect(
        () => OpenAiStreamingTtsEngine(
          baseUrl: 'http://tts.example.com/v1',
          voice: 'voice',
          model: 'model',
          apiKey: 'must-stay-local',
        ),
        throwsArgumentError,
      );
      expect(
        () => OpenAiStreamingTtsEngine.buildRequest(
          baseUrl: 'http://tts.example.com/v1',
          voice: 'voice',
          model: 'model',
          text: 'private text',
          apiKey: 'must-stay-local',
        ),
        throwsArgumentError,
      );
    });

    test('mantiene LAN/Tailscale y HTTPS compatibles', () {
      expect(
        normalizeExternalProviderUrl('http://192.168.1.8:11434/'),
        'http://192.168.1.8:11434',
      );
      final stt = ServerSttEngine(baseUrl: 'ws://100.100.20.30:9123');
      final ttsRequest = OpenAiStreamingTtsEngine.buildRequest(
        baseUrl: 'https://tts.example.com/v1',
        voice: 'voice',
        model: 'model',
        text: 'private text',
      );
      addTearDown(stt.dispose);
      expect(ttsRequest.uri.scheme, 'https');
    });
  });
}
