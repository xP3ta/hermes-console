import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice/voice_stop_phrases.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// `voice.stop_phrases`, copied from Hermes Desktop:
/// apps/desktop/src/store/voice-prefs.ts:18-91 (reading the config) and
/// apps/desktop/src/lib/voice-stop-word.ts:22-140 (the matcher).
void main() {
  VoiceStopPhraseConfig fromList(Object? phrases, {Object? defaults}) =>
      VoiceStopPhraseConfig.fromServerConfig(
        {
          'voice': {'stop_phrases': phrases},
        },
        defaults == null
            ? null
            : {
                'voice': {'stop_phrases': defaults},
              },
      );

  group('reading voice.stop_phrases (voice-prefs.ts:44-91)', () {
    test('absent, null or malformed means the backend default', () {
      for (final config in <Object?>[
        null,
        <String, dynamic>{},
        {'voice': null},
        {'voice': 'on'},
        {'voice': <String, dynamic>{}},
        {
          'voice': {'stop_phrases': null},
        },
        {
          'voice': {
            'stop_phrases': {'a': 'b'},
          },
        },
        {
          'voice': {'stop_phrases': 3},
        },
      ]) {
        final parsed = VoiceStopPhraseConfig.fromServerConfig(config);
        expect(parsed.mode, VoiceStopPhraseMode.defaults, reason: '$config');
        expect(parsed.noticePhrase, 'stop', reason: '$config');
      }
    });

    test('an empty list disables spoken and typed stop', () {
      final parsed = fromList(const <String>[]);
      expect(parsed.mode, VoiceStopPhraseMode.disabled);
      expect(parsed.noticePhrase, isNull);
    });

    test('a list of blanks is an empty list', () {
      expect(fromList(const ['  ', '']).mode, VoiceStopPhraseMode.disabled);
    });

    test('the backend default list keeps the built-in matcher', () {
      final parsed = fromList(const ['Stop']);
      expect(parsed.mode, VoiceStopPhraseMode.defaults);
      // The notice names the configured entry, as Desktop does.
      expect(parsed.noticePhrase, 'Stop');
    });

    test('the default is read from /api/config/defaults when it answers', () {
      final parsed = fromList(const ['halt'], defaults: const ['halt']);
      expect(parsed.mode, VoiceStopPhraseMode.defaults);
      expect(
        fromList(const ['stop'], defaults: const ['halt']).mode,
        VoiceStopPhraseMode.custom,
      );
    });

    test('any other list replaces the built-in one', () {
      final parsed = fromList(const ['отбой', 'хватит']);
      expect(parsed.mode, VoiceStopPhraseMode.custom);
      expect(parsed.phrases, ['отбой', 'хватит']);
      expect(parsed.noticePhrase, 'отбой');
    });

    test('a bare string counts as one phrase', () {
      final parsed = fromList('basta ya');
      expect(parsed.mode, VoiceStopPhraseMode.custom);
      expect(parsed.phrases, ['basta ya']);
    });

    test('non-text entries are skipped and numbers read as text', () {
      final parsed = fromList(<Object?>[
        null,
        true,
        {'a': 1},
        ['x'],
        ' para ya ',
        7,
        3.0,
        2.5,
      ]);
      expect(parsed.mode, VoiceStopPhraseMode.custom);
      expect(parsed.phrases, ['para ya', '7', '3', '2.5']);
    });
  });

  group('matching (voice-stop-word.ts:22-129)', () {
    const defaults = VoiceStopPhraseConfig.backendDefault;

    test('the Desktop English list matches in default mode', () {
      for (final phrase in const [
        'stop',
        'stop listening',
        'stop it',
        'stop please',
        'please stop',
        'stop stop',
        'that is all',
        "that's all",
        'never mind',
        'nevermind',
        'end conversation',
        'end the conversation',
        'goodbye',
        'good bye',
        'bye',
        'cancel',
      ]) {
        expect(isVoiceStopCommand(phrase, defaults), isTrue, reason: phrase);
      }
    });

    test('cállate stays only in default mode (the one Console extra)', () {
      expect(isVoiceStopCommand('Cállate.', defaults), isTrue);
      expect(isVoiceStopCommand('callate', defaults), isTrue);
      expect(isVoiceStopCommand('Cállate.', fromList(const ['отбой'])), false);
    });

    test('address prefixes are stripped, a bare address is not a stop', () {
      for (final phrase in const [
        'Hey Hermes, stop.',
        'hermes stop',
        'Hermes, stop!',
        'OK stop',
        'okay, stop',
        'hey stop',
      ]) {
        expect(isVoiceStopCommand(phrase, defaults), isTrue, reason: phrase);
      }
      for (final phrase in const ['hermes', 'Hey Hermes', 'ok', 'hey']) {
        expect(isVoiceStopCommand(phrase, defaults), isFalse, reason: phrase);
      }
    });

    test('only a whole utterance stops', () {
      for (final phrase in const [
        'stop the container',
        'how do I stop a running process',
        'okay stop the container',
        'cancel the reminder',
        'callate y dime otra cosa',
        'para',
        '',
        '...',
        '¿?',
      ]) {
        expect(isVoiceStopCommand(phrase, defaults), isFalse, reason: phrase);
      }
    });

    test('punctuation from any script is ignored on both sides', () {
      final russian = fromList(const ['«Отбой»']);
      expect(isVoiceStopCommand('отбой!', russian), isTrue);
      expect(isVoiceStopCommand('Hermes, «отбой»…', russian), isTrue);
      final chinese = fromList(const ['停止']);
      expect(isVoiceStopCommand('停止。', chinese), isTrue);
      expect(isVoiceStopCommand('「停止」！', chinese), isTrue);
      final custom = fromList(const ["that's it"]);
      expect(isVoiceStopCommand("That's it!", custom), isTrue);
    });

    test('full-width forms fold like NFKC', () {
      expect(isVoiceStopCommand('ＳＴＯＰ！', defaults), isTrue);
      expect(isVoiceStopCommand('hermes　stop', defaults), isTrue);
    });

    test('a custom list replaces the built-in one', () {
      final custom = fromList(const ['отбой', 'basta ya']);
      expect(isVoiceStopCommand('Отбой!', custom), isTrue);
      expect(isVoiceStopCommand('Basta ya.', custom), isTrue);
      expect(isVoiceStopCommand('hey hermes, basta ya', custom), isTrue);
      expect(isVoiceStopCommand('stop', custom), isFalse);
      expect(isVoiceStopCommand('goodbye', custom), isFalse);
      expect(isVoiceStopCommand('basta', custom), isFalse);
    });

    test('an empty list disables every stop phrase', () {
      final disabled = fromList(const <String>[]);
      for (final phrase in const ['stop', 'Stop.', 'cállate', 'bye']) {
        expect(isVoiceStopCommand(phrase, disabled), isFalse, reason: phrase);
      }
    });
  });

  group('VoiceStopPhraseState', () {
    VoiceStopPhraseConfig custom() => fromList(const ['отбой']);

    test('starts at the backend default', () {
      final state = VoiceStopPhraseState();
      addTearDown(state.dispose);
      expect(state.value.mode, VoiceStopPhraseMode.defaults);
      expect(state.value.noticePhrase, 'stop');
    });

    test('a loaded list applies only to the profile it was read for', () {
      final state = VoiceStopPhraseState();
      addTearDown(state.dispose);
      state.select('server-a');
      expect(state.apply('server-a', custom()), isTrue);
      expect(state.value.phrases, ['отбой']);

      // Re-entering the same profile keeps the last list while it reloads.
      state.select('server-a');
      expect(state.value.phrases, ['отбой']);

      // Another profile starts from the default until its own list loads,
      // and a late answer for the previous one is dropped.
      state.select('server-b');
      expect(state.value.mode, VoiceStopPhraseMode.defaults);
      expect(state.apply('server-a', custom()), isFalse);
      expect(state.value.mode, VoiceStopPhraseMode.defaults);
    });
  });

  group('loadVoiceStopPhrases (use-hermes-config.ts:80, :170)', () {
    test('reads the profile config and the defaults', () async {
      final requests = <http.Request>[];
      final dashboard = DashboardClient(
        host: 'hermes.test',
        port: 9119,
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          requests.add(request);
          // The Dashboard answers application/json, which package:http
          // reads as UTF-8. Without it the fake answer itself is encoded as
          // Latin-1 and cannot even be built with a Cyrillic phrase.
          const jsonHeaders = {'content-type': 'application/json'};
          if (request.url.path == '/api/config/defaults') {
            return http.Response(
              jsonEncode({
                'voice': {
                  'stop_phrases': ['stop'],
                },
              }),
              200,
              headers: jsonHeaders,
            );
          }
          return http.Response(
            jsonEncode({
              'voice': {
                'stop_phrases': ['отбой'],
              },
              'model': {'api_key': 'not-for-voice'},
            }),
            200,
            headers: jsonHeaders,
          );
        }),
      );
      addTearDown(dashboard.close);

      final loaded = await loadVoiceStopPhrases(dashboard, profile: 'work');

      expect(loaded?.mode, VoiceStopPhraseMode.custom);
      expect(loaded?.phrases, ['отбой']);
      expect(requests.map((r) => r.method), ['GET', 'GET']);
      final byPath = {for (final r in requests) r.url.path: r.url};
      expect(
        byPath.keys,
        unorderedEquals(['/api/config', '/api/config/defaults']),
      );
      // The profile scopes the config; the defaults are global, as in
      // Desktop's getHermesConfigDefaults (api/config.ts:165-170).
      expect(byPath['/api/config']!.queryParameters, {'profile': 'work'});
      expect(byPath['/api/config/defaults']!.queryParameters, isEmpty);
    });

    test('defaults that fail fall back to the backend default', () async {
      final dashboard = DashboardClient(
        host: 'hermes.test',
        port: 9119,
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          if (request.url.path == '/api/config/defaults') {
            return http.Response('nope', 500);
          }
          return http.Response(
            jsonEncode({
              'voice': {
                'stop_phrases': ['stop'],
              },
            }),
            200,
          );
        }),
      );
      addTearDown(dashboard.close);

      final loaded = await loadVoiceStopPhrases(dashboard);
      expect(loaded?.mode, VoiceStopPhraseMode.defaults);
    });

    test('a config that fails loads nothing', () async {
      final dashboard = DashboardClient(
        host: 'hermes.test',
        port: 9119,
        manualToken: 'test-token',
        httpClientOverride: MockClient(
          (request) async => http.Response('nope', 403),
        ),
      );
      addTearDown(dashboard.close);

      expect(await loadVoiceStopPhrases(dashboard, profile: 'work'), isNull);
    });
  });

  group('notice (use-composer-voice.ts:383-401)', () {
    test('names the first phrase, none when disabled', () {
      final es = lookupStrings(const Locale('es'));
      final en = lookupStrings(const Locale('en'));
      expect(
        voiceStopNotice(en, VoiceStopPhraseConfig.backendDefault),
        'Say "stop" to end the voice chat.',
      );
      expect(
        voiceStopNotice(es, fromList(const ['basta ya', 'fin'])),
        'Di «basta ya» para terminar el chat de voz.',
      );
      expect(voiceStopNotice(es, fromList(const <String>[])), isNull);
    });
  });
}
