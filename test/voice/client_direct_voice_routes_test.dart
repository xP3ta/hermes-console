import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/client_direct_voice_routes.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice_session_configurator.dart';
import 'package:hermes_android/core/services/voice/voice_client_direct.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/utils/voice_error.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Client-direct voice wired into the server voice route: Desktop's ladder
/// (direct first, relay when the server says so or has no endpoint, provider
/// rejections shown without a relay retry) behind the versioned consent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secret = 'sk-test-SECRET-0123456789';
  const identity = 'http://hermes.test:9119';

  Map<String, dynamic> directStt() => {
    'mode': 'direct',
    'wire': 'openai-multipart',
    'provider': 'openai',
    'base_url': 'https://stt.example.test/v1',
    'api_key': secret,
    'model': 'whisper-1',
    'language': 'es',
  };

  Map<String, dynamic> directTts() => {
    'mode': 'direct',
    'wire': 'openai-speech',
    'provider': 'openai',
    'base_url': 'https://tts.example.test/v1',
    'api_key': secret,
    'model': 'gpt-4o-mini-tts',
    'voice': 'alloy',
  };

  Map<String, dynamic> relay(String reason) => {
    'mode': 'relay',
    'reason': reason,
  };

  VoiceClientConfig config({Object? stt, Object? tts}) =>
      VoiceClientConfig.fromResponse({
        'ok': true,
        'stt': stt ?? directStt(),
        'tts': tts ?? directTts(),
      })!;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ClientDirectVoiceConsentStore', () {
    test('pending by default, per server and persisted', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = ClientDirectVoiceConsentStore(prefs);
      expect(store.read(identity), ClientDirectVoiceConsent.pending);
      await store.write(identity, ClientDirectVoiceConsent.accepted);
      expect(store.read(identity), ClientDirectVoiceConsent.accepted);
      expect(
        store.read('http://other.test:9119'),
        ClientDirectVoiceConsent.pending,
      );
      await store.write(identity, ClientDirectVoiceConsent.rejected);
      expect(
        ClientDirectVoiceConsentStore(prefs).read(identity),
        ClientDirectVoiceConsent.rejected,
      );
    });

    test('the server-voice consent is not a direct one', () async {
      final prefs = await SharedPreferences.getInstance();
      await NativeVoiceConsentStore(
        prefs,
      ).write(identity, NativeVoiceConsent.accepted);
      expect(
        ClientDirectVoiceConsentStore(prefs).read(identity),
        ClientDirectVoiceConsent.pending,
      );
    });

    test('the stored answer is tied to the consent text version', () {
      expect(
        ClientDirectVoiceConsentStore.storageKey(identity),
        'voice_client_direct_consent_v1::$identity',
      );
    });
  });

  test('direct voice is offered when either direction is direct', () {
    expect(clientDirectVoiceOffered(config()), isTrue);
    expect(
      clientDirectVoiceOffered(config(tts: relay('local provider'))),
      isTrue,
    );
    expect(
      clientDirectVoiceOffered(config(stt: relay('local provider'))),
      isTrue,
    );
    expect(
      clientDirectVoiceOffered(
        config(
          stt: relay('voice.client_direct disabled'),
          tts: relay('voice.client_direct disabled'),
        ),
      ),
      isFalse,
    );
    expect(clientDirectVoiceOffered(null), isFalse);
  });

  group('resolveClientDirectVoiceConsent', () {
    Future<
      ({bool result, int fetches, int asks, ClientDirectVoiceConsent stored})
    >
    resolve({
      ClientDirectVoiceConsent initial = ClientDirectVoiceConsent.pending,
      Object? answer,
      bool? choice,
      VoiceClientConfigCache? cache,
    }) async {
      final prefs = await SharedPreferences.getInstance();
      final store = ClientDirectVoiceConsentStore(prefs);
      if (initial != ClientDirectVoiceConsent.pending) {
        await store.write(identity, initial);
      }
      final held = cache ?? VoiceClientConfigCache();
      addTearDown(held.clear);
      var fetches = 0;
      var asks = 0;
      final result = await resolveClientDirectVoiceConsent(
        store: store,
        identity: identity,
        loadConfig: () => held.load(identity, () async {
          fetches += 1;
          if (answer is DashboardHttpException) throw answer;
          return answer;
        }),
        ask: () async {
          asks += 1;
          return choice;
        },
        cache: held,
      );
      return (
        result: result,
        fetches: fetches,
        asks: asks,
        stored: store.read(identity),
      );
    }

    Map<String, dynamic> offered() => {
      'ok': true,
      'stt': directStt(),
      'tts': directTts(),
    };

    test('an accepted consent is used without asking or fetching', () async {
      final r = await resolve(initial: ClientDirectVoiceConsent.accepted);
      expect((r.result, r.fetches, r.asks), (true, 0, 0));
    });

    test('a declined consent stays on the relay without fetching', () async {
      final r = await resolve(initial: ClientDirectVoiceConsent.rejected);
      expect((r.result, r.fetches, r.asks), (false, 0, 0));
    });

    test('voice.client_direct:false never asks', () async {
      final cache = VoiceClientConfigCache();
      final r = await resolve(
        answer: {
          'ok': true,
          'stt': relay('voice.client_direct disabled'),
          'tts': relay('voice.client_direct disabled'),
        },
        cache: cache,
      );
      expect((r.result, r.asks), (false, 0));
      expect(r.stored, ClientDirectVoiceConsent.pending);
      expect(cache.debugHoldsConfig, isFalse);
    });

    test('a server without the endpoint never asks', () async {
      final r = await resolve(
        answer: const DashboardHttpException(404, body: 'Not Found'),
      );
      expect((r.result, r.asks), (false, 0));
      expect(r.stored, ClientDirectVoiceConsent.pending);
    });

    test('accepting the new text enables direct voice', () async {
      final r = await resolve(answer: offered(), choice: true);
      expect((r.result, r.asks), (true, 1));
      expect(r.stored, ClientDirectVoiceConsent.accepted);
    });

    test('declining keeps the relay and drops the fetched keys', () async {
      final cache = VoiceClientConfigCache();
      final r = await resolve(answer: offered(), choice: false, cache: cache);
      expect((r.result, r.asks), (false, 1));
      expect(r.stored, ClientDirectVoiceConsent.rejected);
      expect(cache.debugHoldsConfig, isFalse);
    });

    test('closing the dialog decides nothing and asks again later', () async {
      final cache = VoiceClientConfigCache();
      final r = await resolve(answer: offered(), cache: cache);
      expect((r.result, r.asks), (false, 1));
      expect(r.stored, ClientDirectVoiceConsent.pending);
      expect(cache.debugHoldsConfig, isFalse);
    });
  });

  group('clientDirectTranscribe', () {
    final wav = base64Encode([1, 2, 3, 4]);

    test('a direct STT config transcribes at the provider', () async {
      final relayed = <String>[];
      final provider = <http.Request>[];
      final transcribe = clientDirectTranscribe(
        relay: (dataUrl, mime) async {
          relayed.add(dataUrl);
          return {'ok': true, 'transcript': 'relay'};
        },
        loadConfig: () async => config(),
        direct: VoiceClientDirect(
          clientFactory: () => MockClient((request) async {
            provider.add(request);
            return http.Response(' directo ', 200);
          }),
        ),
      );
      final result = await transcribe(
        'data:audio/wav;base64,$wav',
        'audio/wav',
      );
      expect(result, {
        'ok': true,
        'transcript': 'directo',
        'provider': 'openai',
      });
      expect(relayed, isEmpty);
      expect(provider.single.url.host, 'stt.example.test');
      expect(
        latin1.decode(provider.single.bodyBytes),
        contains('filename="recording.wav"'),
      );
    });

    test('relay verdicts, no endpoint and errors relay', () async {
      for (final load in <Future<VoiceClientConfig?> Function()>[
        () async => null,
        () async => config(stt: relay('local provider')),
        () async => config(stt: relay('voice.client_direct disabled')),
        () async => throw const DashboardHttpException(404),
      ]) {
        final relayed = <(String, String)>[];
        final transcribe = clientDirectTranscribe(
          relay: (dataUrl, mime) async {
            relayed.add((dataUrl, mime));
            return {'ok': true, 'transcript': 'relay'};
          },
          loadConfig: load,
          direct: VoiceClientDirect(
            clientFactory: () => MockClient((_) async {
              fail('the provider must not be called');
            }),
          ),
        );
        final result = await transcribe(
          'data:audio/wav;base64,$wav',
          'audio/wav',
        );
        expect(result['transcript'], 'relay');
        expect(relayed, [('data:audio/wav;base64,$wav', 'audio/wav')]);
      }
    });

    test('a provider rejection is never retried on the relay', () async {
      var relayed = 0;
      final transcribe = clientDirectTranscribe(
        relay: (dataUrl, mime) async {
          relayed += 1;
          return {'ok': true, 'transcript': 'relay'};
        },
        loadConfig: () async => config(),
        direct: VoiceClientDirect(
          clientFactory: () => MockClient(
            (_) async => http.Response('{"detail":"bad key"}', 401),
          ),
        ),
      );
      await expectLater(
        transcribe('data:audio/wav;base64,$wav', 'audio/wav'),
        throwsA(
          isA<VoiceDirectProviderException>().having(
            (e) => e.message,
            'message',
            'openai STT error (HTTP 401): bad key',
          ),
        ),
      );
      expect(relayed, 0);
    });
  });

  group('clientDirectSpeak', () {
    test('a direct TTS config answers an mp3 data URL', () async {
      var relayed = 0;
      final speak = clientDirectSpeak(
        relay: (text) async {
          relayed += 1;
          return {'ok': true};
        },
        loadConfig: () async => config(),
        direct: VoiceClientDirect(
          clientFactory: () =>
              MockClient((_) async => http.Response.bytes([7, 8, 9], 200)),
        ),
      );
      final result = await speak('Hola.');
      expect(result, {
        'ok': true,
        'data_url': 'data:audio/mpeg;base64,${base64Encode([7, 8, 9])}',
        'mime_type': 'audio/mpeg',
        'provider': 'openai',
      });
      expect(relayed, 0);
    });

    test('relay verdicts and no endpoint speak on the relay', () async {
      for (final load in <Future<VoiceClientConfig?> Function()>[
        () async => null,
        () async => config(tts: relay("provider 'edge' has no client wire")),
        () async => throw const DashboardHttpException(404),
      ]) {
        final relayed = <String>[];
        final speak = clientDirectSpeak(
          relay: (text) async {
            relayed.add(text);
            return {'ok': true, 'data_url': 'data:audio/mpeg;base64,AA=='};
          },
          loadConfig: load,
          direct: VoiceClientDirect(
            clientFactory: () => MockClient((_) async {
              fail('the provider must not be called');
            }),
          ),
        );
        await speak('Hola.');
        expect(relayed, ['Hola.']);
      }
    });

    test('a failed direct synthesis falls back to the relay', () async {
      final relayed = <String>[];
      final speak = clientDirectSpeak(
        relay: (text) async {
          relayed.add(text);
          return {'ok': true, 'data_url': 'data:audio/mpeg;base64,AA=='};
        },
        loadConfig: () async => config(),
        direct: VoiceClientDirect(
          clientFactory: () =>
              MockClient((_) async => http.Response('{"detail":"x"}', 500)),
        ),
      );
      final result = await speak('Hola.');
      expect(relayed, ['Hola.']);
      expect(result['data_url'], 'data:audio/mpeg;base64,AA==');
    });
  });

  test('DashboardClient reads voice-config for the profile', () async {
    final requests = <http.Request>[];
    final dashboard = DashboardClient(
      host: 'hermes.test',
      port: 9119,
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({'ok': true, 'stt': directStt(), 'tts': directTts()}),
          200,
        );
      }),
    );
    addTearDown(dashboard.close);

    final body = await dashboard.getVoiceClientConfig(profile: 'work');
    await dashboard.getVoiceClientConfig(profile: 'default');

    expect(body['ok'], isTrue);
    expect(requests.map((r) => r.method), ['GET', 'GET']);
    expect(requests[0].url.path, '/api/audio/voice-config');
    expect(requests[0].url.queryParameters, {'profile': 'work'});
    expect(requests[1].url.queryParameters, isEmpty);
  });

  test('a provider rejection is shown with its own localized wrapper', () {
    final strings = lookupStrings(const Locale('es'));
    expect(
      localizedVoiceError(
        strings,
        const VoiceDirectProviderException('openai STT error (HTTP 401): x'),
      ),
      strings.voz132VoiceProviderError('openai STT error (HTTP 401): x'),
    );
  });

  group('configureAcceptedNativeVoiceSession', () {
    Future<
      ({
        VoiceService voice,
        List<String> dashboardPaths,
        List<Uri> providerCalls,
      })
    >
    configure({
      ClientDirectVoiceConsent consent = ClientDirectVoiceConsent.accepted,
      http.Response Function()? voiceConfig,
      http.Response Function()? provider,
    }) async {
      final prefs = await SharedPreferences.getInstance();
      await NativeVoiceConsentStore(
        prefs,
      ).write(identity, NativeVoiceConsent.accepted);
      await NativeVoiceModeStore(prefs).write(identity, NativeVoiceMode.server);
      await NativeVoiceCapabilityStore(prefs).write(
        identity,
        NativeVoiceCapability(
          transcribe: true,
          speak: true,
          checkedAtMs: DateTime.now().millisecondsSinceEpoch,
          conclusive: true,
        ),
      );
      if (consent != ClientDirectVoiceConsent.pending) {
        await ClientDirectVoiceConsentStore(prefs).write(identity, consent);
      }
      final voice = VoiceService(prefs, SecureStorage());
      addTearDown(voice.dispose);
      final dashboardPaths = <String>[];
      final providerCalls = <Uri>[];
      final dashboard = DashboardClient(
        host: 'hermes.test',
        port: 9119,
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          dashboardPaths.add(request.url.path);
          return switch (request.url.path) {
            '/api/audio/voice-config' =>
              voiceConfig?.call() ??
                  http.Response(
                    jsonEncode({
                      'ok': true,
                      'stt': directStt(),
                      'tts': directTts(),
                    }),
                    200,
                  ),
            '/api/audio/transcribe' => http.Response(
              jsonEncode({'ok': true, 'transcript': 'relay'}),
              200,
            ),
            _ => http.Response('{}', 200),
          };
        }),
      );
      final cache = VoiceClientConfigCache();
      addTearDown(cache.clear);
      final configured = await configureAcceptedNativeVoiceSession(
        voice: voice,
        connection: SavedConnection(
          id: 'client-direct',
          label: 'Hermes',
          host: 'hermes.test',
          port: 8642,
          apiKey: 'test-key',
        ),
        preferences: prefs,
        profile: '',
        dashboardClient: dashboard,
        clientDirect: VoiceClientDirect(
          clientFactory: () => MockClient((request) async {
            providerCalls.add(request.url);
            return provider?.call() ?? http.Response('directo', 200);
          }),
        ),
        clientDirectCache: cache,
      );
      expect(configured, isTrue);
      return (
        voice: voice,
        dashboardPaths: dashboardPaths,
        providerCalls: providerCalls,
      );
    }

    final wav = Uint8List.fromList([1, 2, 3, 4]);

    test('with the new consent STT goes to the provider and TTS skips '
        'speak-stream like Desktop', () async {
      final r = await configure();
      expect(await r.voice.transcribeNativeWav(wav), 'directo');
      expect(r.providerCalls.single.host, 'stt.example.test');
      expect(r.dashboardPaths, isNot(contains('/api/audio/transcribe')));
      expect(r.voice.nativeClientDirectSpeech, isTrue);
      expect(r.voice.nativeSpeechStreamingAvailable, isFalse);
    });

    test('without the new consent no key is fetched', () async {
      for (final consent in [
        ClientDirectVoiceConsent.pending,
        ClientDirectVoiceConsent.rejected,
      ]) {
        final r = await configure(consent: consent);
        expect(await r.voice.transcribeNativeWav(wav), 'relay');
        expect(r.dashboardPaths, isNot(contains('/api/audio/voice-config')));
        expect(r.providerCalls, isEmpty);
        expect(r.voice.nativeClientDirectSpeech, isFalse);
        expect(r.voice.nativeSpeechStreamingAvailable, isTrue);
      }
    });

    test('a server without voice-config keeps today\'s relay', () async {
      final r = await configure(
        voiceConfig: () => http.Response('{"detail":"Not Found"}', 404),
      );
      expect(await r.voice.transcribeNativeWav(wav), 'relay');
      expect(r.providerCalls, isEmpty);
      expect(r.voice.nativeClientDirectSpeech, isFalse);
      expect(r.voice.nativeSpeechStreamingAvailable, isTrue);
    });

    test('voice.client_direct:false keeps today\'s relay', () async {
      final r = await configure(
        voiceConfig: () => http.Response(
          jsonEncode({
            'ok': true,
            'stt': relay('voice.client_direct disabled'),
            'tts': relay('voice.client_direct disabled'),
          }),
          200,
        ),
      );
      expect(await r.voice.transcribeNativeWav(wav), 'relay');
      expect(r.providerCalls, isEmpty);
      expect(r.voice.nativeClientDirectSpeech, isFalse);
      expect(r.voice.nativeSpeechStreamingAvailable, isTrue);
    });

    test('a provider rejection surfaces without a relay request', () async {
      final r = await configure(
        provider: () => http.Response('{"detail":"bad key"}', 401),
      );
      await expectLater(
        r.voice.transcribeNativeWav(wav),
        throwsA(isA<VoiceDirectProviderException>()),
      );
      expect(r.dashboardPaths, isNot(contains('/api/audio/transcribe')));
    });
  });
}
