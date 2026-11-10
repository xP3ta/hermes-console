import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/voice_server_prefs.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:hermes_android/core/services/voice/voice_stop_phrases.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Desktop `store/voice-prefs.ts:93-146`: barge-in, its sensitivity and the
/// end-of-turn hold read from the profile's `/api/config`.
Map<String, Object?> _voice(Map<String, Object?> voice) => {'voice': voice};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('voice.barge_in (voice-prefs.ts:93-101)', () {
    test('armed unless explicitly false', () {
      expect(voiceBargeInFromConfig(null), isTrue);
      expect(voiceBargeInFromConfig(<String, Object?>{}), isTrue);
      for (final value in [true, null, 'false', 0, 'no']) {
        expect(
          voiceBargeInFromConfig(_voice({'barge_in': value})),
          isTrue,
          reason: '$value',
        );
      }
      expect(voiceBargeInFromConfig(_voice({'barge_in': false})), isFalse);
    });
  });

  group('voice.barge_in_threshold_multiplier (voice-prefs.ts:103-113)', () {
    double? read(Object? value) => voiceBargeInThresholdMultiplierFromConfig(
      _voice({'barge_in_threshold_multiplier': value}),
    );

    test('a positive number, read like JavaScript Number()', () {
      expect(read(2), 2);
      expect(read(4.5), 4.5);
      expect(read(' 2.5 '), 2.5);
      expect(read('1e1'), 10);
      // Number(true) is 1 in Desktop.
      expect(read(true), 1);
    });

    test('unset or invalid keeps the built-in levels', () {
      for (final value in [null, 0, -1, '', 'abc', false, 'Infinity', []]) {
        expect(read(value), isNull, reason: '$value');
      }
      expect(voiceBargeInThresholdMultiplierFromConfig(null), isNull);
    });

    test('the trigger scale is multiplier / 3 (voice-barge-in.ts:82-88)', () {
      expect(bargeInThresholdScale(null), 1);
      expect(bargeInThresholdScale(3), 1);
      expect(bargeInThresholdScale(1.5), 0.5);
      expect(bargeInThresholdScale(6), 2);
      expect(bargeInThresholdScale(0), 1);
      expect(bargeInThresholdScale(double.nan), 1);
    });
  });

  group('voice.silence_duration (voice-prefs.ts:115-146)', () {
    Duration read(Object? value, {Object? defaultSeconds = 3.0}) =>
        voiceSilenceFromConfig(
          _voice({'silence_duration': value}),
          defaultSeconds == null
              ? null
              : _voice({'silence_duration': defaultSeconds}),
        );

    test('the backend default keeps Desktop 1.25 s', () {
      expect(kDesktopVoiceSilence, const Duration(milliseconds: 1250));
      expect(read(3.0), kDesktopVoiceSilence);
      expect(read(3), kDesktopVoiceSilence);
      expect(
        voiceSilenceFromConfig(null, null),
        kDesktopVoiceSilence,
        reason: 'absent',
      );
    });

    test('a value the user changed replaces it', () {
      expect(read(2), const Duration(seconds: 2));
      expect(read('4.5'), const Duration(milliseconds: 4500));
      expect(read(0.8), const Duration(milliseconds: 800));
    });

    test('true, zero, negative and junk do not count', () {
      for (final value in [true, false, 0, -2, 'abc', null]) {
        expect(read(value), kDesktopVoiceSilence, reason: '$value');
      }
    });

    test('the default comes from /api/config/defaults, else 3.0', () {
      expect(read(2.0, defaultSeconds: 2.0), kDesktopVoiceSilence);
      expect(read(3.0, defaultSeconds: 2.0), const Duration(seconds: 3));
      expect(read(3.0, defaultSeconds: null), kDesktopVoiceSilence);
      expect(
        read(3.5, defaultSeconds: null),
        const Duration(milliseconds: 3500),
      );
    });
  });

  test('the state follows the selected profile only', () {
    final state = VoiceServerPrefsState();
    addTearDown(state.dispose);
    const custom = VoiceServerPrefs(
      bargeInThresholdMultiplier: 2,
      silence: Duration(seconds: 2),
    );
    expect(state.value, VoiceServerPrefs.desktopDefaults);
    state.select('a');
    expect(state.apply('a', custom), isTrue);
    expect(state.value, custom);
    state.select('b');
    expect(state.value, VoiceServerPrefs.desktopDefaults);
    expect(state.apply('a', custom), isFalse);
    expect(state.value, VoiceServerPrefs.desktopDefaults);
  });

  group('loadVoiceServerConfig', () {
    late List<Uri> requests;
    late int defaultsStatus;
    late int configStatus;

    DashboardClient dashboard() => DashboardClient(
      host: '192.168.1.20',
      port: 9119,
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request.url);
        if (request.url.path == '/api/config/defaults') {
          return http.Response(
            jsonEncode(
              _voice({
                'silence_duration': 3.0,
                'stop_phrases': ['stop'],
              }),
            ),
            defaultsStatus,
          );
        }
        return http.Response(
          jsonEncode(
            _voice({
              'barge_in': false,
              'barge_in_threshold_multiplier': 4.5,
              'silence_duration': 2,
              'stop_phrases': ['basta'],
            }),
          ),
          configStatus,
        );
      }),
    );

    setUp(() {
      requests = [];
      defaultsStatus = 200;
      configStatus = 200;
    });

    test('one read gives stop phrases, barge-in and prefs', () async {
      final client = dashboard();
      addTearDown(client.close);
      final read = await loadVoiceServerConfig(client, profile: 'work');

      expect(read, isNotNull);
      expect(read!.bargeIn, isFalse);
      expect(read.prefs.bargeInThresholdMultiplier, 4.5);
      expect(read.prefs.silence, const Duration(seconds: 2));
      expect(read.stopPhrases.mode, VoiceStopPhraseMode.custom);
      expect(requests.map((uri) => uri.path).toSet(), {
        '/api/config',
        '/api/config/defaults',
      });
      final config = requests.firstWhere((uri) => uri.path == '/api/config');
      expect(config.queryParameters['profile'], 'work');
      final defaults = requests.firstWhere(
        (uri) => uri.path == '/api/config/defaults',
      );
      expect(defaults.queryParameters, isEmpty);
    });

    test('defaults failing still read the config', () async {
      defaultsStatus = 500;
      final client = dashboard();
      addTearDown(client.close);
      final read = await loadVoiceServerConfig(client);
      expect(read!.prefs.silence, const Duration(seconds: 2));
    });

    test('the config failing is null and the stop phrases follow', () async {
      configStatus = 500;
      final client = dashboard();
      addTearDown(client.close);
      expect(await loadVoiceServerConfig(client), isNull);
      expect(await loadVoiceStopPhrases(client), isNull);
    });
  });

  group('barge-in seed (V0 decision 4)', () {
    late SharedPreferences prefs;
    late VoiceService voice;

    setUp(() async {
      SharedPreferences.setMockInitialValues({'app_locale': 'es'});
      prefs = await SharedPreferences.getInstance();
      voice = VoiceService(prefs, SecureStorage());
      addTearDown(voice.dispose);
    });

    test('the first server value seeds the switch, once', () async {
      expect(voice.bargeInEnabled.value, isFalse);
      expect(await voice.seedBargeInFromServer(true), isTrue);
      expect(voice.bargeInEnabled.value, isTrue);
      expect(voice.settings.bargeInEnabled, isTrue);
      expect(
        VoiceSettings.load(prefs).bargeInEnabled,
        isTrue,
        reason: 'persisted',
      );

      expect(await voice.seedBargeInFromServer(false), isFalse);
      expect(voice.bargeInEnabled.value, isTrue);
    });

    test('a seed equal to the switch still ends the seeding', () async {
      expect(await voice.seedBargeInFromServer(false), isFalse);
      expect(await voice.seedBargeInFromServer(true), isFalse);
      expect(voice.bargeInEnabled.value, isFalse);
    });

    test('a user choice is never overwritten by the server', () async {
      await voice.markBargeInChosen();
      expect(await voice.seedBargeInFromServer(true), isFalse);
      expect(voice.bargeInEnabled.value, isFalse);
    });
  });
}
