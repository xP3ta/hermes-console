import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice_session_configurator.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TrackingClient extends MockClient {
  _TrackingClient(super.handler);

  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}

Future<Map<String, dynamic>> _speak(String _) async => const {'ok': true};
Future<Map<String, dynamic>> _transcribe(String _, String _) async => const {
  'ok': true,
  'transcript': '',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('setTtsLease posts the lease and state to the profile route', () async {
    final requests = <http.Request>[];
    final dashboard = DashboardClient(
      host: 'hermes.test',
      port: 9119,
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({'ok': true, 'action': 'error', 'error': 'warm failed'}),
          200,
        );
      }),
    );
    addTearDown(dashboard.close);

    final body = await dashboard.setTtsLease(
      'console:voice:abc',
      active: true,
      profile: 'perfil',
    );

    expect(body['action'], 'error');
    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/api/audio/tts-lease');
    expect(requests.single.url.queryParameters['profile'], 'perfil');
    expect(jsonDecode(requests.single.body), {
      'lease': 'console:voice:abc',
      'active': true,
    });
  });

  test('server voice acquires on enable and releases on disable', () async {
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    final calls = <(String, bool)>[];
    var closed = false;

    expect(
      voice.enableNativeVoice(
        speak: _speak,
        transcribe: _transcribe,
        ttsLease: (lease, active) async {
          calls.add((lease, active));
          return const {};
        },
        onDispose: () {
          // The client must still be open while the release travels.
          expect(calls.where((c) => !c.$2), isNotEmpty);
          closed = true;
        },
      ),
      isTrue,
    );
    await pumpEventQueue();
    expect(calls, hasLength(1));
    expect(calls.single.$2, isTrue);
    expect(calls.single.$1, startsWith('console:voice:'));

    expect(voice.disableNativeVoice(), isTrue);
    await pumpEventQueue();
    expect(calls, [(calls.first.$1, true), (calls.first.$1, false)]);
    expect(closed, isTrue);
  });

  test('lease failures are silent and never block the voice route', () async {
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    var closed = false;
    final installed = voice.enableNativeVoice(
      speak: _speak,
      transcribe: _transcribe,
      ttsLease: (_, _) => Future.error(const DashboardHttpException(404)),
      onDispose: () => closed = true,
    );
    expect(installed, isTrue);
    expect(voice.nativeVoiceActive, isTrue);
    await pumpEventQueue();
    expect(voice.disableNativeVoice(), isTrue);
    await pumpEventQueue();
    expect(closed, isTrue);
  });

  test(
    'the lease id is stable per install and unique across installs',
    () async {
      final prefs = await SharedPreferences.getInstance();
      Future<String> leaseOf(SharedPreferences preferences) async {
        final voice = VoiceService(preferences, SecureStorage());
        final seen = Completer<String>();
        voice.enableNativeVoice(
          speak: _speak,
          transcribe: _transcribe,
          ttsLease: (lease, active) async {
            if (active && !seen.isCompleted) seen.complete(lease);
            return const {};
          },
        );
        final lease = await seen.future;
        await voice.dispose();
        return lease;
      }

      final first = await leaseOf(prefs);
      final again = await leaseOf(prefs);
      SharedPreferences.setMockInitialValues({});
      final other = await leaseOf(await SharedPreferences.getInstance());

      expect(again, first);
      expect(other, isNot(first));
    },
  );

  test('conversation setup warms TTS through the fake HTTP client', () async {
    final prefs = await SharedPreferences.getInstance();
    const identity = 'http://hermes.test:9119';
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
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    final leases = <Map<String, dynamic>>[];
    late _TrackingClient client;
    client = _TrackingClient((request) async {
      if (request.url.path == '/api/audio/tts-lease') {
        expect(client.closed, isFalse);
        leases.add(jsonDecode(request.body) as Map<String, dynamic>);
        // Hermes reports warm-up failures in the body, never as HTTP errors.
        return http.Response(
          jsonEncode({'ok': true, 'action': 'error', 'error': 'no provider'}),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    final connection = SavedConnection(
      id: 'lease-node',
      label: 'Hermes',
      host: 'hermes.test',
      port: 8642,
      apiKey: 'k',
    );

    final configured = await configureAcceptedNativeVoiceSession(
      voice: voice,
      connection: connection,
      preferences: prefs,
      profile: '',
      dashboardFactory: (_) => DashboardClient(
        host: 'hermes.test',
        port: 9119,
        manualToken: 'test-token',
        httpClientOverride: client,
      ),
    );
    expect(configured, isTrue);
    await pumpEventQueue();
    expect(leases, hasLength(1));
    expect(leases.single['active'], isTrue);

    voice.disableNativeVoice();
    await pumpEventQueue();
    expect(leases.map((l) => l['active']), [true, false]);
    expect(leases.last['lease'], leases.first['lease']);
    expect(client.closed, isTrue);
  });
}
