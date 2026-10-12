import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice_session_configurator.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'dictation-cache',
  label: 'Hermes',
  host: '192.168.1.20',
  port: 8642,
  apiKey: 'test-key',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late int probes;
  late int probeStatus;
  late SharedPreferences prefs;
  late VoiceService voice;
  late String identity;

  DashboardClient dashboardFor(SavedConnection _) => DashboardClient(
    host: '192.168.1.20',
    port: 9119,
    manualToken: 'test-token',
    httpClientOverride: MockClient((request) async {
      if (request.url.path == '/api/audio/transcribe') probes++;
      return http.Response('{}', probeStatus);
    }),
  );

  Future<HermesServerDictationConfigurationResult> tap() async {
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
      profile: 'default',
      dashboardFactory: dashboardFor,
    );
    if (result == HermesServerDictationConfigurationResult.configured) {
      voice.disableHermesServerDictation(owner: owner);
    }
    return result;
  }

  setUp(() async {
    now = DateTime.utc(2026, 10, 1, 12);
    probes = 0;
    probeStatus = 400;
    HermesDictationProbeCache.resetForTesting(now: () => now);
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
    await NativeVoiceConsentStore(
      prefs,
    ).write(identity, NativeVoiceConsent.accepted);
  });

  test('repeated dictation taps probe the endpoint once', () async {
    for (var i = 0; i < 3; i++) {
      expect(await tap(), HermesServerDictationConfigurationResult.configured);
    }
    // Before: one POST /api/audio/transcribe per tap (3).
    expect(probes, 1);
  });

  test('the cached verdict expires and is probed again', () async {
    await tap();
    now = now.add(HermesDictationProbeCache.maxAge);
    await tap();
    expect(probes, 2);
  });

  test('a negative verdict is never cached', () async {
    probeStatus = 404;
    expect(await tap(), HermesServerDictationConfigurationResult.unavailable);
    expect(await tap(), HermesServerDictationConfigurationResult.unavailable);
    expect(probes, 2);
  });

  test('withdrawn consent drops the cached verdict', () async {
    await tap();
    await NativeVoiceConsentStore(
      prefs,
    ).write(identity, NativeVoiceConsent.rejected);
    expect(await tap(), HermesServerDictationConfigurationResult.unavailable);
    await NativeVoiceConsentStore(
      prefs,
    ).write(identity, NativeVoiceConsent.accepted);
    await tap();
    expect(probes, 2);
  });

  test('switching the engine away drops the cached verdict', () async {
    await tap();
    await voice.saveSettings(
      voice.settings.copyWith(sttEngine: SttEngineKind.system),
    );
    expect(await tap(), HermesServerDictationConfigurationResult.unavailable);
    await voice.saveSettings(
      voice.settings.copyWith(sttEngine: SttEngineKind.hermesServer),
    );
    await tap();
    expect(probes, 2);
  });
}
