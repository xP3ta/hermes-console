import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/client_direct_voice_routes.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice_session_configurator.dart';
import 'package:hermes_android/core/services/voice/hermes_dictation_stream.dart';
import 'package:hermes_android/core/services/voice/voice_client_direct.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which dictations stream live: Desktop gates on `stt.streaming`
/// (`use-voice-recorder.ts:214-215`). Console reads it from voice-config
/// only after the direct-voice consent (that answer can carry the key), and
/// from `/api/config` otherwise.
final _connection = SavedConnection(
  id: 'live-dictation',
  label: 'Hermes',
  host: '192.168.1.20',
  port: 8642,
  apiKey: 'test-key',
);

class _Socket implements HermesDictationSocket {
  final StreamController<dynamic> controller = StreamController<dynamic>();
  final List<Object> sent = [];
  bool closed = false;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<dynamic> get frames => controller.stream;

  @override
  void send(Object frame) => sent.add(frame);

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late SharedPreferences prefs;
  late VoiceService voice;
  late String identity;
  late List<String> paths;
  late Object? configStreaming;
  late int configStatus;
  late Object? voiceConfigStreaming;
  late List<Uri> socketUris;
  late _Socket socket;

  DashboardClient dashboardFor(SavedConnection _) => DashboardClient(
    host: '192.168.1.20',
    port: 9119,
    manualToken: 'test-token',
    httpClientOverride: MockClient((request) async {
      final path = request.url.path;
      paths.add(request.url.toString());
      switch (path) {
        case '/api/audio/transcribe':
          return http.Response('{}', 400);
        case '/api/config':
          return http.Response(
            jsonEncode({
              'stt': {'provider': 'openai', 'streaming': configStreaming},
              'voice': {'client_direct': true},
            }),
            configStatus,
          );
        case '/api/audio/voice-config':
          return http.Response(
            jsonEncode({
              'ok': true,
              'stt': {
                'mode': 'relay',
                'reason': 'x',
                'streaming': voiceConfigStreaming,
              },
              'tts': {'mode': 'relay', 'reason': 'x'},
            }),
            200,
          );
        case '/api/auth/ws-ticket':
          return http.Response(jsonEncode({'ticket': 'ws-1'}), 200);
      }
      return http.Response('{}', 404);
    }),
  );

  Future<(Object, HermesServerDictationConfigurationResult)> tap({
    String profile = 'default',
  }) async {
    final owner = Object();
    final preparation = voice.beginHermesServerDictationPreparation(
      owner: owner,
    );
    final result = await configureHermesServerDictation(
      voice: voice,
      owner: owner,
      preparation: preparation,
      connection: _connection,
      preferences: prefs,
      profile: profile,
      dashboardFactory: dashboardFor,
      clientDirectCache: VoiceClientConfigCache(),
      liveSocketConnector: (uri, _) {
        socketUris.add(uri);
        return socket;
      },
    );
    return (owner, result);
  }

  bool requested(String path) =>
      paths.any((url) => Uri.parse(url).path == path);

  setUp(() async {
    now = DateTime.utc(2026, 10, 26, 12);
    paths = [];
    configStreaming = true;
    configStatus = 200;
    voiceConfigStreaming = true;
    socketUris = [];
    socket = _Socket();
    HermesDictationProbeCache.resetForTesting(now: () => now);
    HermesLiveDictationGateCache.resetForTesting(now: () => now);
    SharedPreferences.setMockInitialValues({'app_locale': 'es'});
    prefs = await SharedPreferences.getInstance();
    await const VoiceSettings(
      sttEngine: SttEngineKind.hermesServer,
    ).save(prefs);
    voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    identity = nativeVoicePreferenceIdentity(
      dashboardFor(_connection).baseUrl,
      profile: 'default',
    );
    paths.clear();
    await NativeVoiceConsentStore(
      prefs,
    ).write(identity, NativeVoiceConsent.accepted);
  });

  test('stt.streaming on in /api/config installs live dictation without '
      'asking for voice-config (no provider key)', () async {
    final (_, result) = await tap();
    expect(result, HermesServerDictationConfigurationResult.configured);
    expect(voice.hermesServerLiveDictationReady, isTrue);
    expect(requested('/api/config'), isTrue);
    expect(requested('/api/audio/voice-config'), isFalse);
  });

  test('stt.streaming off keeps the recorded dictation only', () async {
    configStreaming = false;
    final (_, result) = await tap();
    expect(result, HermesServerDictationConfigurationResult.configured);
    expect(voice.hermesServerDictationReady, isTrue);
    expect(voice.hermesServerLiveDictationReady, isFalse);
  });

  test('a failed config read keeps dictation, without live text', () async {
    configStatus = 500;
    final (_, result) = await tap();
    expect(result, HermesServerDictationConfigurationResult.configured);
    expect(voice.hermesServerLiveDictationReady, isFalse);
  });

  test('the /api/config verdict is held for 60 s', () async {
    await tap();
    await tap();
    expect(
      paths.where((url) => Uri.parse(url).path == '/api/config'),
      hasLength(1),
    );
    now = now.add(const Duration(seconds: 60));
    configStreaming = false;
    await tap();
    expect(voice.hermesServerLiveDictationReady, isFalse);
  });

  test('a failed read is not held', () async {
    configStatus = 500;
    await tap();
    configStatus = 200;
    await tap();
    expect(voice.hermesServerLiveDictationReady, isTrue);
  });

  test('with direct voice accepted the gate is voice-config stt.streaming, '
      'as in Desktop', () async {
    await ClientDirectVoiceConsentStore(
      prefs,
    ).write(identity, ClientDirectVoiceConsent.accepted);
    configStreaming = true;
    voiceConfigStreaming = false;
    await tap();
    expect(voice.hermesServerLiveDictationReady, isFalse);
    expect(requested('/api/audio/voice-config'), isTrue);
    expect(requested('/api/config'), isFalse);

    voiceConfigStreaming = true;
    await tap();
    expect(voice.hermesServerLiveDictationReady, isTrue);
  });

  test('without the server-voice consent nothing is read', () async {
    await NativeVoiceConsentStore(
      prefs,
    ).write(identity, NativeVoiceConsent.rejected);
    final (_, result) = await tap();
    expect(result, isNot(HermesServerDictationConfigurationResult.configured));
    expect(requested('/api/config'), isFalse);
    expect(voice.hermesServerLiveDictationReady, isFalse);
  });

  test('releasing the dictation drops the live opener too', () async {
    final (owner, _) = await tap();
    expect(voice.hermesServerLiveDictationReady, isTrue);
    voice.disableHermesServerDictation(owner: owner);
    expect(voice.hermesServerLiveDictationReady, isFalse);
  });

  test('the live socket is this Dashboard, profile and ticket', () async {
    final work = nativeVoicePreferenceIdentity(
      dashboardFor(_connection).baseUrl,
      profile: 'work',
    );
    await NativeVoiceConsentStore(
      prefs,
    ).write(work, NativeVoiceConsent.accepted);
    final (_, result) = await tap(profile: 'work');
    expect(result, HermesServerDictationConfigurationResult.configured);
    expect(
      paths.any((url) {
        final uri = Uri.parse(url);
        return uri.path == '/api/config' &&
            uri.queryParameters['profile'] == 'work';
      }),
      isTrue,
    );

    final session = await voice.debugHermesDictationLive!(
      sampleRate: 16000,
      onPartial: (_) {},
    );
    expect(session, isNotNull);
    expect(socketUris.single.path, '/api/audio/transcribe-stream');
    expect(socketUris.single.queryParameters['ticket'], 'ws-1');
    expect(socketUris.single.queryParameters['profile'], 'work');
    expect(jsonDecode(socket.sent.first as String), {'sample_rate': 16000});
    session!.cancel();
    expect(socket.closed, isTrue);
  });

  test('the gate never throws and reads truthy strings', () async {
    expect(
      await hermesLiveDictationOffered(
        identity: 'w',
        clientDirectAccepted: false,
        loadVoiceConfig: () async => null,
        loadServerConfig: () async => {
          'stt': {'streaming': 'yes'},
        },
      ),
      isTrue,
    );
    expect(
      await hermesLiveDictationOffered(
        identity: 'y',
        clientDirectAccepted: true,
        loadVoiceConfig: () async => throw StateError('x'),
        loadServerConfig: () async => throw StateError('never'),
      ),
      isFalse,
    );
    expect(
      await hermesLiveDictationOffered(
        identity: 'z',
        clientDirectAccepted: false,
        loadVoiceConfig: () async => null,
        loadServerConfig: () async => throw StateError('down'),
      ),
      isFalse,
    );
    expect(HermesLiveDictationGateCache.read('z'), isNull);
  });
}
