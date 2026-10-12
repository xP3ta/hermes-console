import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/removed_voice_engines.dart';
import 'package:hermes_android/core/services/voice/stt_sherpa.dart';
import 'package:hermes_android/core/services/voice/tts_model_manager.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the phone has downloaded, without a disk.
RemovedVoiceEngineDownloads onPhone({
  Set<String> voices = const {},
  Set<SherpaModelKind> dictation = const {},
  bool whisper = false,
}) => RemovedVoiceEngineDownloads(
  voice: (voice) async => voices.contains(voice.id),
  dictation: (model) async => dictation.contains(model.kind),
  whisper: () async => whisper,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(VoiceService, SharedPreferences)> rig(
    Map<String, Object> stored,
  ) async {
    SharedPreferences.setMockInitialValues(stored);
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    return (voice, prefs);
  }

  Future<bool?> neverAsked() =>
      fail('the server is not asked when dictation is not being moved');

  group('a removed reply voice', () {
    for (final engine in const [
      TtsEngineKind.elevenlabs,
      TtsEngineKind.streaming,
      TtsEngineKind.customHttp,
    ]) {
      test(
        '${engine.id} becomes the downloaded voice that was chosen',
        () async {
          final (voice, prefs) = await rig({
            'voice_tts_engine': engine.id,
            'voice_onnx_voice_id': kNeuralVoices[1].id,
          });
          expect(RemovedVoiceEngines.pending(voice.settings), isTrue);

          final changed = await RemovedVoiceEngines.migrate(
            voice: voice,
            serverDictation: neverAsked,
            downloads: onPhone(
              voices: {kNeuralVoices[0].id, kNeuralVoices[1].id},
            ),
          );

          expect(changed, isTrue);
          expect(voice.settings.ttsEngine, TtsEngineKind.onnx);
          expect(voice.settings.onnxVoiceId, kNeuralVoices[1].id);
          expect(prefs.getString('voice_tts_engine'), TtsEngineKind.onnx.id);
          expect(RemovedVoiceEngines.pending(voice.settings), isFalse);
        },
      );
    }

    test('falls to another downloaded voice when the chosen one is not on '
        'the phone', () async {
      final (voice, prefs) = await rig({
        'voice_tts_engine': TtsEngineKind.elevenlabs.id,
        'voice_onnx_voice_id': kNeuralVoices[0].id,
      });

      await RemovedVoiceEngines.migrate(
        voice: voice,
        serverDictation: neverAsked,
        downloads: onPhone(voices: {kNeuralVoices[2].id}),
      );

      expect(voice.settings.ttsEngine, TtsEngineKind.onnx);
      expect(voice.settings.onnxVoiceId, kNeuralVoices[2].id);
      expect(prefs.getString('voice_onnx_voice_id'), kNeuralVoices[2].id);
    });

    test('becomes the Android voice when nothing is downloaded', () async {
      final (voice, prefs) = await rig({
        'voice_tts_engine': TtsEngineKind.streaming.id,
      });

      await RemovedVoiceEngines.migrate(
        voice: voice,
        serverDictation: neverAsked,
        downloads: onPhone(),
      );

      expect(voice.settings.ttsEngine, TtsEngineKind.device);
      expect(prefs.getString('voice_tts_engine'), TtsEngineKind.device.id);
    });

    test('keeps the addresses, the keys and the server choice of each '
        'connection', () async {
      const mode = 'native_voice_mode_v1::http://hermes-demo.local:9119';
      const consent = 'native_voice_consent::http://hermes-demo.local:9119';
      final (voice, prefs) = await rig({
        'voice_tts_engine': TtsEngineKind.streaming.id,
        'voice_streaming_tts_profile': 'kokoro',
        'voice_streaming_tts_kokoro_url': 'http://192.168.1.40:8880',
        'voice_streaming_tts_kokoro_voice': 'em_santa',
        'voice_custom_tts_url': 'https://tts.example.test/speak',
        'voice_eleven_voice_id': 'voice-123',
        mode: 'server',
        consent: 'accepted',
      });
      await voice.setElevenKey('eleven-secret');
      await voice.setCustomTtsSecret('custom-secret');
      await voice.setStreamingTtsToken('stream-secret');

      await RemovedVoiceEngines.migrate(
        voice: voice,
        serverDictation: neverAsked,
        downloads: onPhone(),
      );

      expect(voice.settings.ttsEngine, TtsEngineKind.device);
      expect(
        prefs.getString('voice_streaming_tts_kokoro_url'),
        'http://192.168.1.40:8880',
      );
      expect(prefs.getString('voice_streaming_tts_kokoro_voice'), 'em_santa');
      expect(
        prefs.getString('voice_custom_tts_url'),
        'https://tts.example.test/speak',
      );
      expect(prefs.getString('voice_eleven_voice_id'), 'voice-123');
      expect(await voice.elevenKey(), 'eleven-secret');
      expect(await voice.customTtsSecret(), 'custom-secret');
      expect(await voice.streamingTtsToken(), 'stream-secret');
      // A connection that speaks through the Hermes server keeps doing so.
      expect(prefs.getString(mode), 'server');
      expect(prefs.getString(consent), 'accepted');
    });
  });

  group('dictation through a server of the user\'s own', () {
    const stored = <String, Object>{
      'voice_stt_engine': 'server',
      'voice_server_stt_url': 'ws://192.168.1.40:9123',
    };

    test('becomes the Hermes server when it can dictate', () async {
      final (voice, prefs) = await rig(stored);
      expect(voice.settings.sttEngine, SttEngineKind.server);
      await voice.setServerSttToken('stt-secret');

      final changed = await RemovedVoiceEngines.migrate(
        voice: voice,
        serverDictation: () async => true,
        downloads: onPhone(dictation: {SherpaModelKind.parakeetV3}),
      );

      expect(changed, isTrue);
      expect(voice.settings.sttEngine, SttEngineKind.hermesServer);
      expect(
        prefs.getString('voice_stt_engine'),
        SttEngineKind.hermesServer.id,
      );
      // The address and its token are still there.
      expect(prefs.getString('voice_server_stt_url'), 'ws://192.168.1.40:9123');
      expect(await voice.serverSttToken(), 'stt-secret');
    });

    test(
      'becomes a model already on the phone when the server cannot',
      () async {
        final (voice, _) = await rig({
          ...stored,
          'voice_sherpa_model': SherpaModelKind.whisperSmall.id,
        });

        await RemovedVoiceEngines.migrate(
          voice: voice,
          serverDictation: () async => false,
          downloads: onPhone(
            dictation: {
              SherpaModelKind.parakeetV3,
              SherpaModelKind.whisperSmall,
            },
            whisper: true,
          ),
        );

        expect(voice.settings.sttEngine, SttEngineKind.sherpaLive);
        expect(voice.settings.sherpaModel, SherpaModelKind.whisperSmall);
      },
    );

    test(
      'picks the model that is downloaded, not the one that was chosen',
      () async {
        final (voice, _) = await rig({
          ...stored,
          'voice_sherpa_model': SherpaModelKind.whisperSmall.id,
        });

        await RemovedVoiceEngines.migrate(
          voice: voice,
          serverDictation: () async => false,
          downloads: onPhone(dictation: {SherpaModelKind.parakeetV3}),
        );

        expect(voice.settings.sttEngine, SttEngineKind.sherpaLive);
        expect(voice.settings.sherpaModel, SherpaModelKind.parakeetV3);
      },
    );

    test('uses the model that transcribes at the end when it is the only '
        'download', () async {
      final (voice, _) = await rig(stored);

      await RemovedVoiceEngines.migrate(
        voice: voice,
        serverDictation: () async => false,
        downloads: onPhone(whisper: true),
      );

      expect(voice.settings.sttEngine, SttEngineKind.whisper);
    });

    test('falls to Android when nothing is downloaded', () async {
      final (voice, prefs) = await rig(stored);

      await RemovedVoiceEngines.migrate(
        voice: voice,
        serverDictation: () async => false,
        downloads: onPhone(),
      );

      expect(voice.settings.sttEngine, SttEngineKind.system);
      expect(prefs.getString('voice_stt_engine'), SttEngineKind.system.id);
    });

    test('waits, still working, while the server cannot be asked', () async {
      final (voice, prefs) = await rig({
        ...stored,
        'voice_tts_engine': TtsEngineKind.elevenlabs.id,
      });

      final first = await RemovedVoiceEngines.migrate(
        voice: voice,
        serverDictation: () async => null,
        downloads: onPhone(),
      );

      // The voice needs no server and moves now; dictation is left as it is.
      expect(first, isTrue);
      expect(voice.settings.ttsEngine, TtsEngineKind.device);
      expect(voice.settings.sttEngine, SttEngineKind.server);
      expect(prefs.getString('voice_stt_engine'), 'server');
      expect(RemovedVoiceEngines.pending(voice.settings), isTrue);

      final second = await RemovedVoiceEngines.migrate(
        voice: voice,
        serverDictation: () async => null,
        downloads: onPhone(),
      );
      expect(second, isFalse);

      final third = await RemovedVoiceEngines.migrate(
        voice: voice,
        serverDictation: () async => true,
        downloads: onPhone(),
      );
      expect(third, isTrue);
      expect(voice.settings.sttEngine, SttEngineKind.hermesServer);
    });
  });

  test('settings that name no removed engine are left alone', () async {
    final (voice, prefs) = await rig({
      'voice_tts_engine': TtsEngineKind.onnx.id,
      'voice_stt_engine': SttEngineKind.whisper.id,
    });
    final before = prefs.getKeys().map((key) => '$key=${prefs.get(key)}');

    final changed = await RemovedVoiceEngines.migrate(
      voice: voice,
      serverDictation: neverAsked,
      downloads: onPhone(),
    );

    expect(changed, isFalse);
    expect(voice.settings.ttsEngine, TtsEngineKind.onnx);
    expect(voice.settings.sttEngine, SttEngineKind.whisper);
    expect(prefs.getKeys().map((key) => '$key=${prefs.get(key)}'), before);
  });

  test('a choice made while the checks run wins over the migration', () async {
    final (voice, _) = await rig({
      'voice_tts_engine': TtsEngineKind.elevenlabs.id,
    });

    final changed = await RemovedVoiceEngines.migrate(
      voice: voice,
      serverDictation: neverAsked,
      downloads: RemovedVoiceEngineDownloads(
        voice: (_) async {
          if (voice.settings.ttsEngine != TtsEngineKind.device) {
            await voice.saveSettings(
              voice.settings.copyWith(ttsEngine: TtsEngineKind.device),
            );
          }
          return true;
        },
        dictation: (_) async => false,
        whisper: () async => false,
      ),
    );

    expect(changed, isFalse);
    expect(voice.settings.ttsEngine, TtsEngineKind.device);
  });

  group('whether a connection may dictate through the Hermes server', () {
    final connection = SavedConnection(
      id: 'demo-node',
      label: 'Server',
      host: 'hermes-demo.local',
      port: 8642,
      apiKey: 'test-key',
      dashboardUrl: 'http://hermes-demo.local:9119',
    );

    Future<(bool?, List<http.Request>)> ask({
      required Map<String, Object> stored,
      required http.Response Function() answer,
      String profile = '',
    }) async {
      SharedPreferences.setMockInitialValues(stored);
      final prefs = await SharedPreferences.getInstance();
      final requests = <http.Request>[];
      final result = await RemovedVoiceEngines.serverDictationFor(
        connection: connection,
        preferences: prefs,
        profile: profile,
        dashboardFactory: (_) => DashboardClient(
          host: 'hermes-demo.local',
          manualToken: 'test-token',
          httpClientOverride: MockClient((request) async {
            requests.add(request);
            return answer();
          }),
        ),
      );
      return (result, requests);
    }

    const accepted = <String, Object>{
      'native_voice_consent::http://hermes-demo.local:9119': 'accepted',
    };

    test(
      'never without the user having accepted it, and nothing is sent',
      () async {
        final (result, requests) = await ask(
          stored: const {},
          answer: () => http.Response('{}', 200),
        );
        expect(result, isFalse);
        expect(requests, isEmpty);
      },
    );

    test('yes when the server transcribes', () async {
      for (final status in const [200, 400, 422]) {
        final (result, requests) = await ask(
          stored: accepted,
          answer: () => http.Response(jsonEncode({'detail': 'x'}), status),
        );
        expect(result, isTrue, reason: '$status');
        expect(requests.single.url.path, '/api/audio/transcribe');
      }
    });

    test('no when the server has no transcription', () async {
      for (final status in const [404, 405, 501]) {
        final (result, _) = await ask(
          stored: accepted,
          answer: () => http.Response('{}', status),
        );
        expect(result, isFalse, reason: '$status');
      }
    });

    test('unknown when the server gives no conclusive answer', () async {
      for (final status in const [401, 500, 503]) {
        final (result, _) = await ask(
          stored: accepted,
          answer: () => http.Response('{}', status),
        );
        expect(result, isNull, reason: '$status');
      }
      final (offline, _) = await ask(
        stored: accepted,
        answer: () => throw http.ClientException('offline'),
      );
      expect(offline, isNull);
    });

    test('the acceptance of one profile does not count for another', () async {
      final (result, requests) = await ask(
        stored: accepted,
        answer: () => http.Response('{}', 200),
        profile: 'work',
      );
      expect(result, isFalse);
      expect(requests, isEmpty);
    });
  });
}
