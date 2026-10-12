import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/read_aloud_session.dart';
import 'package:hermes_android/core/services/voice/read_aloud_voice_route.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Plays nothing and reports completion at once.
class _InstantPlayback implements TtsAudioPlayback {
  final _completed = StreamController<void>.broadcast();

  @override
  Stream<void> get onComplete => _completed.stream;

  @override
  Future<void> playBytes(Uint8List bytes, {required String mimeType}) async {
    scheduleMicrotask(() => _completed.add(null));
  }

  @override
  Future<void> playFile(String path) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _completed.close();
  }
}

const _base = 'http://hermes-demo.local:9119';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final connection = SavedConnection(
    id: 'demo-node',
    label: 'Server',
    host: 'hermes-demo.local',
    port: 8642,
    apiKey: 'test-key',
    dashboardUrl: _base,
  );

  late List<http.Request> requests;
  late bool serverHasVoice;
  late List<DashboardClient> clients;

  DashboardClient dashboard(SavedConnection _) {
    final client = DashboardClient(
      host: 'hermes-demo.local',
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path == '/api/audio/tts-lease') {
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        if (request.method == 'GET' && path.startsWith('/api/config')) {
          return http.Response(
            jsonEncode({
              'tts': {'provider': 'edge'},
            }),
            200,
          );
        }
        if (request.method == 'POST' && path.startsWith('/api/audio/')) {
          if (!serverHasVoice) return http.Response('{}', 404);
          if (request.body.trim().isEmpty || request.body.trim() == '{}') {
            return http.Response('{}', 400);
          }
          return http.Response(
            jsonEncode({'ok': true, 'data_url': 'data:audio/mpeg;base64,AAAA'}),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    clients.add(client);
    return client;
  }

  Future<(VoiceService, SharedPreferences)> rig(
    WidgetTester tester,
    Map<String, Object> stored,
  ) async {
    SharedPreferences.setMockInitialValues(stored);
    FlutterSecureStorage.setMockInitialValues({});
    final support = Directory.systemTemp.createTempSync('read-aloud-route-');
    addTearDown(() => support.deleteSync(recursive: true));
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
      pathProvider,
      (call) async => support.path,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
    ReadAloudVoiceRoute.resetForTesting();
    requests = [];
    clients = [];
    serverHasVoice = true;
    addTearDown(() {
      for (final client in clients) {
        client.close();
      }
    });
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage())
      ..debugNativePlaybackFactory = _InstantPlayback.new;
    addTearDown(voice.dispose);
    return (voice, prefs);
  }

  Future<void> align(
    VoiceService voice,
    SharedPreferences prefs, {
    String profile = '',
  }) => ReadAloudVoiceRoute.align(
    voice: voice,
    connection: connection,
    preferences: prefs,
    profile: profile,
    dashboardFactory: dashboard,
  );

  Future<void> readAloud(WidgetTester tester, VoiceService voice) async {
    await voice.toggleReadAloud(
      messageKey: 'chat:msg-1',
      revision: 'r1',
      markdown: 'Hola mundo.',
    );
    for (var i = 0; i < 50 && voice.readAloud.value.isActive; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
  }

  int spoken() => requests.where((request) {
    if (request.url.path != '/api/audio/speak') return false;
    final body = request.body.trim();
    return body.isNotEmpty && body != '{}';
  }).length;

  const server = {
    'native_voice_consent::$_base': 'accepted',
    'native_voice_mode_v1::$_base': 'server',
  };

  testWidgets('with the Hermes server chosen, a reply is read with the '
      'server voice outside a conversation', (tester) async {
    final (voice, prefs) = await rig(tester, server);
    expect(voice.nativeVoiceActive, isFalse);

    await tester.runAsync(() => align(voice, prefs));
    expect(voice.nativeVoiceActive, isTrue);
    await readAloud(tester, voice);
    expect(voice.readAloud.value.phase, isNot(ReadAloudPhase.failed));
    expect(spoken(), 1);

    // Already in place: the next read does not set the route up again.
    final before = requests.length;
    await tester.runAsync(() => align(voice, prefs));
    expect(requests.length, before);
    await tester.pump(const Duration(minutes: 10));
  });

  testWidgets('with this phone chosen, a server voice left installed is '
      'removed before reading', (tester) async {
    final (voice, prefs) = await rig(tester, const {});
    final client = dashboard(connection);
    voice.enableNativeVoice(
      speak: (text) => client.synthesizeSpeech(text),
      transcribe: (dataUrl, mimeType) =>
          client.transcribeAudio(dataUrl, mimeType: mimeType),
    );
    expect(voice.nativeVoiceActive, isTrue);

    await tester.runAsync(() => align(voice, prefs));
    expect(voice.nativeVoiceActive, isFalse);
    expect(spoken(), 0);
  });

  testWidgets('the choice is per profile', (tester) async {
    final (voice, prefs) = await rig(tester, const {
      'native_voice_consent::$_base::profile=work': 'accepted',
      'native_voice_mode_v1::$_base::profile=work': 'server',
    });
    await tester.runAsync(() => align(voice, prefs));
    expect(voice.nativeVoiceActive, isFalse, reason: 'default profile: phone');

    await tester.runAsync(() => align(voice, prefs, profile: 'work'));
    expect(voice.nativeVoiceActive, isTrue);
    expect(
      requests
          .where((request) => request.url.path.startsWith('/api/config'))
          .every((request) => request.url.queryParameters['profile'] == 'work'),
      isTrue,
    );
    voice.disableNativeVoice();
    await tester.runAsync(pumpEventQueue);
  });

  testWidgets('a server without voice leaves the phone voice in place', (
    tester,
  ) async {
    final (voice, prefs) = await rig(tester, server);
    serverHasVoice = false;
    await tester.runAsync(() => align(voice, prefs));
    expect(voice.nativeVoiceActive, isFalse);
    expect(spoken(), 0);
  });

  testWidgets('choosing the server without accepting it sends nothing', (
    tester,
  ) async {
    final (voice, prefs) = await rig(tester, const {
      'native_voice_mode_v1::$_base': 'server',
    });
    await tester.runAsync(() => align(voice, prefs));
    expect(voice.nativeVoiceActive, isFalse);
    expect(requests, isEmpty);
  });
}
