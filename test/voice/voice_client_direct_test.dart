import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice/voice_client_direct.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Contract of client-direct voice, copied from Hermes Desktop
/// `apps/desktop/src/lib/voice-client-direct.ts` (v0.22.0 = v0.22.4) and the
/// server resolver `tools/voice_client_config.py`.
void main() {
  const secret = 'sk-test-SECRET-0123456789';

  Map<String, dynamic> openAiStt({Map<String, dynamic> extra = const {}}) => {
    'mode': 'direct',
    'wire': 'openai-multipart',
    'provider': 'openai',
    'base_url': 'https://stt.example.test/v1/',
    'api_key': secret,
    'model': 'whisper-1',
    'language': 'es',
    'timeout_s': 60,
    'hallucination_filter': {
      'phrases': ['thank you', 'bye', 'you'],
      'repeat_regex':
          r'^(?:thank you|thanks|bye|you|ok|okay|the end|[.,!\s])+$',
    },
    ...extra,
  };

  Map<String, dynamic> openAiTts({Map<String, dynamic> extra = const {}}) => {
    'mode': 'direct',
    'wire': 'openai-speech',
    'provider': 'openai',
    'base_url': 'https://tts.example.test/v1',
    'api_key': secret,
    'model': 'gpt-4o-mini-tts',
    'voice': 'alloy',
    'speed': 1.0,
    'extra_body': {'lang_code': 'es'},
    'min_len': 20,
    ...extra,
  };

  Map<String, dynamic> response({Object? stt, Object? tts, bool ok = true}) =>
      {'ok': ok, 'stt': stt ?? openAiStt(), 'tts': tts ?? openAiTts()};

  group('VoiceClientConfig.fromResponse', () {
    test('reads a Desktop-shaped direct STT and TTS answer', () {
      final config = VoiceClientConfig.fromResponse(
        response(stt: openAiStt(extra: {'streaming': true})),
      )!;
      final stt = config.stt!;
      expect(stt.wire, DirectSttWire.openAiMultipart);
      expect(stt.provider, 'openai');
      expect(stt.baseUrl, 'https://stt.example.test/v1/');
      expect(stt.model, 'whisper-1');
      expect(stt.language, 'es');
      expect(stt.timeout, const Duration(seconds: 60));
      expect(stt.hallucinationFilter!.phrases, ['thank you', 'bye', 'you']);
      expect(config.sttStreaming, isTrue);
      final tts = config.tts!;
      expect(tts.wire, DirectTtsWire.openAiSpeech);
      expect(tts.voice, 'alloy');
      expect(tts.speed, 1.0);
      expect(tts.extraBody, {'lang_code': 'es'});
    });

    test('every wire Desktop speaks is recognised', () {
      for (final (wire, expected) in [
        ('openai-multipart', DirectSttWire.openAiMultipart),
        ('xai-stt', DirectSttWire.xaiStt),
        ('elevenlabs-stt', DirectSttWire.elevenLabsStt),
      ]) {
        final config = VoiceClientConfig.fromResponse(
          response(stt: openAiStt(extra: {'wire': wire})),
        )!;
        expect(config.stt!.wire, expected, reason: wire);
      }
      for (final (wire, expected) in [
        ('openai-speech', DirectTtsWire.openAiSpeech),
        ('elevenlabs-tts', DirectTtsWire.elevenLabsTts),
      ]) {
        final config = VoiceClientConfig.fromResponse(
          response(tts: openAiTts(extra: {'wire': wire})),
        )!;
        expect(config.tts!.wire, expected, reason: wire);
      }
    });

    test('a relay verdict keeps that direction on the relay', () {
      // `voice.client_direct: false` is resolved by the server into this
      // exact answer (voice_client_config.py:239-240).
      final config = VoiceClientConfig.fromResponse(
        response(
          stt: {'mode': 'relay', 'reason': 'voice.client_direct disabled'},
          tts: {'mode': 'relay', 'reason': 'voice.client_direct disabled'},
        ),
      )!;
      expect(config.stt, isNull);
      expect(config.tts, isNull);
      expect(config.sttRelayReason, 'voice.client_direct disabled');
      expect(config.ttsRelayReason, 'voice.client_direct disabled');
    });

    test('server-host-only providers stay on the relay', () {
      for (final reason in [
        'local provider',
        'command/plugin provider',
        'xai oauth (server-managed) or no credentials',
        "provider 'edge' has no client wire",
      ]) {
        final config = VoiceClientConfig.fromResponse(
          response(
            stt: {'mode': 'relay', 'reason': reason},
            tts: {'mode': 'relay', 'reason': reason},
          ),
        )!;
        expect(config.stt, isNull, reason: reason);
        expect(config.tts, isNull, reason: reason);
      }
    });

    test('a malformed answer is no config at all (relay)', () {
      for (final bad in <Object?>[
        null,
        'not a map',
        {'ok': false, 'stt': openAiStt(), 'tts': openAiTts()},
        {'ok': true, 'tts': openAiTts()},
        {'ok': true, 'stt': openAiStt()},
        {'data': '<html></html>'},
      ]) {
        expect(VoiceClientConfig.fromResponse(bad), isNull, reason: '$bad');
      }
    });

    test('an unknown wire or a missing key or URL keeps the relay', () {
      for (final stt in [
        openAiStt(extra: {'wire': 'grpc-stt'}),
        openAiStt(extra: {'api_key': ''}),
        openAiStt(extra: {'api_key': null}),
        openAiStt(extra: {'base_url': ''}),
      ]) {
        final config = VoiceClientConfig.fromResponse(response(stt: stt))!;
        expect(config.stt, isNull, reason: '$stt');
        expect(config.tts, isNotNull);
      }
      final config = VoiceClientConfig.fromResponse(
        response(tts: openAiTts(extra: {'wire': 'edge-websocket'})),
      )!;
      expect(config.tts, isNull);
    });

    test('the key never goes over plain HTTP to a public host', () {
      for (final url in [
        'http://stt.example.com/v1',
        'http://203.0.113.7:8000/v1',
      ]) {
        final config = VoiceClientConfig.fromResponse(
          response(
            stt: openAiStt(extra: {'base_url': url}),
            tts: openAiTts(extra: {'base_url': url}),
          ),
        );
        expect(config?.stt, isNull, reason: url);
        expect(config?.tts, isNull, reason: url);
      }
      for (final url in [
        'https://stt.example.com/v1',
        'http://192.168.1.20:8000/v1',
        'http://100.101.102.103:8000/v1',
        'http://whisper.tail1234.ts.net/v1',
        'http://127.0.0.1:8000/v1',
      ]) {
        final config = VoiceClientConfig.fromResponse(
          response(
            stt: openAiStt(extra: {'base_url': url}),
            tts: openAiTts(extra: {'base_url': url}),
          ),
        )!;
        expect(config.stt?.baseUrl, url);
        expect(config.tts?.baseUrl, url);
      }
    });

    test('a non-positive or missing timeout falls back to 60 s', () {
      for (final value in [null, 0, -3, 'soon']) {
        final config = VoiceClientConfig.fromResponse(
          response(stt: openAiStt(extra: {'timeout_s': value})),
        )!;
        expect(config.stt!.timeout, const Duration(seconds: 60));
      }
      final config = VoiceClientConfig.fromResponse(
        response(stt: openAiStt(extra: {'timeout_s': 7.5})),
      )!;
      expect(config.stt!.timeout, const Duration(milliseconds: 7500));
    });

    test('no description of a config ever contains the key', () {
      final config = VoiceClientConfig.fromResponse(response())!;
      for (final text in [
        '$config',
        '${config.stt}',
        '${config.tts}',
        '${config.stt!.hallucinationFilter}',
      ]) {
        expect(text, isNot(contains(secret)));
      }
    });
  });

  group('VoiceClientConfigCache', () {
    final scope = VoiceClientConfigCache.scopeKey(
      'https://hermes.example.test/',
      'default',
    );

    test('scope is the Dashboard and the profile, default normalised', () {
      expect(
        VoiceClientConfigCache.scopeKey('https://hermes.example.test/', null),
        VoiceClientConfigCache.scopeKey('https://hermes.example.test', ''),
      );
      expect(
        VoiceClientConfigCache.scopeKey('https://hermes.example.test', 'work'),
        isNot(scope),
      );
      expect(
        VoiceClientConfigCache.scopeKey('https://other.example.test', null),
        isNot(scope),
      );
    });

    test('one fetch per scope within 60 s, a new one after', () {
      fakeAsync((async) {
        final cache = VoiceClientConfigCache();
        var fetches = 0;
        Future<Object?> fetch() async {
          fetches += 1;
          return response();
        }

        VoiceClientConfig? first;
        VoiceClientConfig? second;
        cache.load(scope, fetch).then((value) => first = value);
        async.flushMicrotasks();
        cache.load(scope, fetch).then((value) => second = value);
        async.flushMicrotasks();
        expect(fetches, 1);
        expect(first, isNotNull);
        expect(identical(first, second), isTrue);

        async.elapse(const Duration(seconds: 61));
        cache.load(scope, fetch);
        async.flushMicrotasks();
        expect(fetches, 2);
        cache.clear();
      });
    });

    test('concurrent loads of one scope share a single request', () {
      fakeAsync((async) {
        final cache = VoiceClientConfigCache();
        final gate = Completer<Object?>();
        var fetches = 0;
        Future<Object?> fetch() {
          fetches += 1;
          return gate.future;
        }

        final results = <VoiceClientConfig?>[];
        cache.load(scope, fetch).then(results.add);
        cache.load(scope, fetch).then(results.add);
        gate.complete(response());
        async.flushMicrotasks();
        expect(fetches, 1);
        expect(results, hasLength(2));
        cache.clear();
      });
    });

    test('another profile or Dashboard never reuses the cached keys', () {
      fakeAsync((async) {
        final cache = VoiceClientConfigCache();
        final seen = <String>[];
        Future<Object?> Function() fetchFor(String name) => () async {
          seen.add(name);
          return response();
        };

        cache.load(scope, fetchFor('default'));
        async.flushMicrotasks();
        cache.load(
          VoiceClientConfigCache.scopeKey('https://hermes.example.test', 'w'),
          fetchFor('w'),
        );
        async.flushMicrotasks();
        expect(seen, ['default', 'w']);
        cache.clear();
      });
    });

    test('a missing endpoint or a failure is relay and is not cached', () {
      fakeAsync((async) {
        final cache = VoiceClientConfigCache();
        var fetches = 0;
        final results = <VoiceClientConfig?>[];
        for (final failure in <Object>[
          const DashboardHttpException(404, body: '{"detail":"Not Found"}'),
          const FormatException('html instead of json'),
          TimeoutException('slow'),
        ]) {
          cache
              .load(scope, () async {
                fetches += 1;
                throw failure;
              })
              .then(results.add);
          async.flushMicrotasks();
        }
        expect(results, [null, null, null]);
        expect(fetches, 3);
        expect(cache.debugHoldsConfig, isFalse);
      });
    });

    test('the keys leave memory when the 60 s are over', () {
      fakeAsync((async) {
        final cache = VoiceClientConfigCache();
        cache.load(scope, () async => response());
        async.flushMicrotasks();
        expect(cache.debugHoldsConfig, isTrue);
        async.elapse(const Duration(seconds: 59));
        expect(cache.debugHoldsConfig, isTrue);
        async.elapse(const Duration(seconds: 2));
        expect(cache.debugHoldsConfig, isFalse);
      });
    });

    test('clear drops the held keys at once', () {
      fakeAsync((async) {
        final cache = VoiceClientConfigCache();
        cache.load(scope, () async => response());
        async.flushMicrotasks();
        cache.clear();
        expect(cache.debugHoldsConfig, isFalse);
      });
    });
  });

  group('silence hallucination filter (relay parity)', () {
    const filter = VoiceHallucinationFilter(
      phrases: ['thank you', 'bye', 'you'],
      repeatRegex: r'^(?:thank you|thanks|bye|you|ok|okay|the end|[.,!\s])+$',
    );

    test('matches what the relay drops and keeps real speech', () {
      expect(isSttSilenceHallucination('', filter), isTrue);
      expect(isSttSilenceHallucination('  Thank you.  ', filter), isTrue);
      expect(isSttSilenceHallucination('Bye!', filter), isTrue);
      expect(isSttSilenceHallucination('OK. OK. OK.', filter), isTrue);
      expect(isSttSilenceHallucination('thank. you', filter), isFalse);
      expect(isSttSilenceHallucination('thank you so much', filter), isFalse);
      expect(isSttSilenceHallucination('hola', filter), isFalse);
    });

    test('no filter (older backend) lets the transcript through', () {
      expect(isSttSilenceHallucination('thank you', null), isFalse);
    });

    test('a broken regex never swallows a turn', () {
      const broken = VoiceHallucinationFilter(phrases: [], repeatRegex: '(');
      expect(isSttSilenceHallucination('thank you', broken), isFalse);
    });
  });

  test('OpenAI-compatible body: bare text or Voxtral JSON', () {
    expect(transcriptFromOpenAiMultipartBody('  hola  '), 'hola');
    expect(
      transcriptFromOpenAiMultipartBody('{"text":" hola ","model":"v"}'),
      'hola',
    );
    expect(transcriptFromOpenAiMultipartBody('{broken'), '{broken');
    expect(transcriptFromOpenAiMultipartBody(''), '');
  });

  group('STT provider wires', () {
    final audio = Uint8List.fromList(List<int>.generate(64, (i) => i));

    DirectSttConfig sttWith(Map<String, dynamic> extra) =>
        VoiceClientConfig.fromResponse(
          response(stt: openAiStt(extra: extra)),
        )!.stt!;

    Future<(String, http.Request)> run(
      DirectSttConfig stt,
      http.Response Function(http.Request) answer,
    ) async {
      late http.Request seen;
      final direct = VoiceClientDirect(
        clientFactory: () => MockClient((request) async {
          seen = request;
          return answer(request);
        }),
      );
      final transcript = await direct.transcribe(
        stt,
        audio,
        mimeType: 'audio/wav',
      );
      return (transcript, seen);
    }

    test('openai-multipart posts the clip like Desktop', () async {
      final (transcript, request) = await run(
        sttWith(const {}),
        (_) => http.Response(' hola ', 200),
      );
      expect(transcript, 'hola');
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://stt.example.test/v1/audio/transcriptions',
      );
      expect(request.headers['Authorization'], 'Bearer $secret');
      final body = latin1.decode(request.bodyBytes);
      expect(body, contains('name="file"; filename="recording.wav"'));
      expect(body, contains('name="model"\r\n\r\nwhisper-1'));
      expect(body, contains('name="response_format"\r\n\r\ntext'));
      expect(body, contains('name="language"\r\n\r\nes'));
    });

    test('model and language are optional', () async {
      final (_, request) = await run(
        sttWith(const {'model': null, 'language': null}),
        (_) => http.Response('hola', 200),
      );
      final body = latin1.decode(request.bodyBytes);
      expect(body, isNot(contains('name="model"')));
      expect(body, isNot(contains('name="language"')));
    });

    test('a hallucination on silence is an empty transcript', () async {
      final (transcript, _) = await run(
        sttWith(const {}),
        (_) => http.Response('Thank you.', 200),
      );
      expect(transcript, '');
    });

    test('xai-stt sends format only together with a language', () async {
      final (transcript, request) = await run(
        sttWith(const {
          'wire': 'xai-stt',
          'provider': 'xai',
          'base_url': 'https://api.x.example.test/v1',
          'model': 'grok-stt',
        }),
        (_) => http.Response(jsonEncode({'text': ' hola '}), 200),
      );
      expect(transcript, 'hola');
      expect(request.url.toString(), 'https://api.x.example.test/v1/stt');
      expect(request.headers['Authorization'], 'Bearer $secret');
      final body = latin1.decode(request.bodyBytes);
      expect(body, contains('name="model"\r\n\r\ngrok-stt'));
      expect(body, contains('name="language"\r\n\r\nes'));
      expect(body, contains('name="format"\r\n\r\ntrue'));

      final (_, autoDetect) = await run(
        sttWith(const {'wire': 'xai-stt', 'language': null}),
        (_) => http.Response(jsonEncode({'text': 'hola'}), 200),
      );
      expect(
        latin1.decode(autoDetect.bodyBytes),
        isNot(contains('name="format"')),
      );
    });

    test('elevenlabs-stt sends xi-api-key, model_id, language_code', () async {
      final (transcript, request) = await run(
        sttWith(const {
          'wire': 'elevenlabs-stt',
          'provider': 'elevenlabs',
          'base_url': 'https://api.eleven.example.test/v1',
          'model': 'scribe_v1',
        }),
        (_) => http.Response(jsonEncode({'text': 'hola'}), 200),
      );
      expect(transcript, 'hola');
      expect(
        request.url.toString(),
        'https://api.eleven.example.test/v1/speech-to-text',
      );
      expect(request.headers['xi-api-key'], secret);
      expect(request.headers.containsKey('Authorization'), isFalse);
      final body = latin1.decode(request.bodyBytes);
      expect(body, contains('name="model_id"\r\n\r\nscribe_v1'));
      expect(body, contains('name="language_code"\r\n\r\nes'));
    });

    test('a provider rejection is raised with the Desktop wording', () async {
      final direct = VoiceClientDirect(
        clientFactory: () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'message': 'Incorrect API key provided: $secret'},
            }),
            401,
          ),
        ),
      );
      final error = await direct
          .transcribe(sttWith(const {}), audio, mimeType: 'audio/wav')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<VoiceDirectProviderException>());
      final message = (error! as VoiceDirectProviderException).message;
      expect(message, startsWith('openai STT error (HTTP 401): '));
      expect(message, contains('Incorrect API key provided'));
      expect(message, isNot(contains(secret)));
      expect('$error', isNot(contains(secret)));
    });

    test('the provider labels match Desktop for xAI and ElevenLabs', () async {
      for (final (wire, label) in [
        ('xai-stt', 'xAI STT error (HTTP 500): '),
        ('elevenlabs-stt', 'ElevenLabs STT error (HTTP 500): '),
      ]) {
        final direct = VoiceClientDirect(
          clientFactory: () => MockClient(
            (_) async => http.Response('{"detail":"down"}', 500),
          ),
        );
        final error = await direct
            .transcribe(sttWith({'wire': wire}), audio, mimeType: 'audio/wav')
            .then<Object?>((_) => null, onError: (Object e) => e);
        expect(
          (error! as VoiceDirectProviderException).message,
          '${label}down',
        );
      }
    });

    test('a raw error body is cut at 300 characters', () async {
      final direct = VoiceClientDirect(
        clientFactory: () =>
            MockClient((_) async => http.Response('x' * 500, 503)),
      );
      final error = await direct
          .transcribe(sttWith(const {}), audio, mimeType: 'audio/wav')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(
        (error! as VoiceDirectProviderException).message,
        'openai STT error (HTTP 503): ${'x' * 300}',
      );
    });

    test('the request is bounded by timeout_s with the Desktop wording', () {
      fakeAsync((async) {
        final direct = VoiceClientDirect(
          clientFactory: () =>
              MockClient((_) => Completer<http.Response>().future),
        );
        Object? error;
        direct
            .transcribe(
              sttWith(const {'timeout_s': 5}),
              audio,
              mimeType: 'audio/wav',
            )
            .then<void>((_) {}, onError: (Object e) => error = e);
        async.elapse(const Duration(seconds: 4));
        expect(error, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(error, isA<VoiceDirectProviderException>());
        expect(
          (error! as VoiceDirectProviderException).message,
          'Transcription timed out after 5s (openai did not answer)',
        );
      });
    });
  });

  group('TTS provider wires', () {
    DirectTtsConfig ttsWith(Map<String, dynamic> extra) =>
        VoiceClientConfig.fromResponse(
          response(tts: openAiTts(extra: extra)),
        )!.tts!;

    test('openai-speech asks for mp3 with the Desktop body', () async {
      late http.Request seen;
      final direct = VoiceClientDirect(
        clientFactory: () => MockClient((request) async {
          seen = request;
          return http.Response.bytes([1, 2, 3], 200);
        }),
      );
      final bytes = await direct.synthesize(ttsWith(const {}), 'Hola.');
      expect(bytes, [1, 2, 3]);
      expect(seen.url.toString(), 'https://tts.example.test/v1/audio/speech');
      expect(seen.headers['Authorization'], 'Bearer $secret');
      expect(seen.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(seen.body), {
        'lang_code': 'es',
        'model': 'gpt-4o-mini-tts',
        'voice': 'alloy',
        'input': 'Hola.',
        'response_format': 'mp3',
      });
    });

    test('speed is sent only when it is set and not 1', () async {
      final bodies = <Object?>[];
      final direct = VoiceClientDirect(
        clientFactory: () => MockClient((request) async {
          bodies.add(jsonDecode(request.body));
          return http.Response.bytes([1], 200);
        }),
      );
      await direct.synthesize(ttsWith(const {'speed': 1.25}), 'a');
      await direct.synthesize(ttsWith(const {'speed': null}), 'a');
      expect((bodies[0]! as Map)['speed'], 1.25);
      expect((bodies[1]! as Map).containsKey('speed'), isFalse);
    });

    test('extra_body never overrides the request Desktop builds', () async {
      late http.Request seen;
      final direct = VoiceClientDirect(
        clientFactory: () => MockClient((request) async {
          seen = request;
          return http.Response.bytes([1], 200);
        }),
      );
      await direct.synthesize(
        ttsWith(const {
          'extra_body': {'input': 'other', 'response_format': 'wav'},
        }),
        'Hola.',
      );
      final body = jsonDecode(seen.body) as Map;
      expect(body['input'], 'Hola.');
      expect(body['response_format'], 'mp3');
    });

    test('elevenlabs-tts posts to the encoded voice id', () async {
      late http.Request seen;
      final direct = VoiceClientDirect(
        clientFactory: () => MockClient((request) async {
          seen = request;
          return http.Response.bytes([9], 200);
        }),
      );
      await direct.synthesize(
        ttsWith(const {
          'wire': 'elevenlabs-tts',
          'provider': 'elevenlabs',
          'base_url': 'https://api.eleven.example.test/v1/',
          'model': 'eleven_multilingual_v2',
          'voice': 'voice id/1',
        }),
        'Hola.',
      );
      expect(
        seen.url.toString(),
        'https://api.eleven.example.test/v1/text-to-speech/voice%20id%2F1',
      );
      expect(seen.headers['xi-api-key'], secret);
      expect(seen.headers['Accept'], 'audio/mpeg');
      expect(jsonDecode(seen.body), {
        'text': 'Hola.',
        'model_id': 'eleven_multilingual_v2',
      });
    });

    test('a TTS rejection is raised with the Desktop wording', () async {
      for (final (extra, label) in [
        (const <String, dynamic>{}, 'openai TTS error (HTTP 429): '),
        (
          const <String, dynamic>{
            'wire': 'elevenlabs-tts',
            'provider': 'elevenlabs',
          },
          'ElevenLabs TTS error (HTTP 429): ',
        ),
      ]) {
        final direct = VoiceClientDirect(
          clientFactory: () => MockClient(
            (_) async => http.Response('{"detail":"quota for $secret"}', 429),
          ),
        );
        final error = await direct
            .synthesize(ttsWith(extra), 'Hola.')
            .then<Object?>((_) => null, onError: (Object e) => e);
        final message = (error! as VoiceDirectProviderException).message;
        expect(message, startsWith(label));
        expect(message, isNot(contains(secret)));
      }
    });
  });

  group('keys stay in memory only', () {
    test('no log line ever carries the key', () async {
      final lines = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = previous);

      final cache = VoiceClientConfigCache();
      addTearDown(cache.clear);
      final config = await cache.load(
        VoiceClientConfigCache.scopeKey('https://hermes.example.test', null),
        () async => response(),
      );
      final failing = VoiceClientDirect(
        clientFactory: () => MockClient(
          (_) async => http.Response('{"detail":"bad key $secret"}', 401),
        ),
      );
      await failing
          .transcribe(
            config!.stt!,
            Uint8List.fromList([1]),
            mimeType: 'audio/wav',
          )
          .then<void>((_) {}, onError: (_) {});
      await failing
          .synthesize(config.tts!, 'Hola.')
          .then<void>((_) {}, onError: (_) {});
      for (final line in lines) {
        expect(line, isNot(contains(secret)));
      }
    });

    test('the client-direct library has no way to write to disk or logs', () {
      final source = File(
        'lib/core/services/voice/voice_client_direct.dart',
      ).readAsStringSync();
      for (final forbidden in [
        'dart:io',
        'shared_preferences',
        'flutter_secure_storage',
        'path_provider',
        'debugPrint(',
        'print(',
        'developer.log',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });
}
