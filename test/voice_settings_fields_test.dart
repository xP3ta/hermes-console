// Voice settings as two questions with the same shape: where dictation is
// transcribed and where the reply voice comes from. Each offers "Servidor
// Hermes" and "En este teléfono"; only the chosen one shows its rows, which
// are Hermes Desktop's fields as pickers or the phone's model or voice.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/voice_settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/server_voice_fields.dart';
import 'package:hermes_android/core/services/voice/stt_sherpa.dart';
import 'package:hermes_android/core/services/voice/tts_model_manager.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _base = 'http://hermes-demo.local:9119';

/// A Hermes Dashboard that keeps one voice config: it answers the reads and
/// applies the patches the screen writes, like the real one.
class _Server {
  _Server({required this.config, this.live, this.voice = true});

  Map<String, dynamic> config;

  /// Body of the voice-live status, or `null` for a server without GPT-Live.
  final Map<String, dynamic>? live;

  /// Whether the server has the audio routes at all.
  final bool voice;
  final List<http.Request> requests = [];
  final List<http.Request> writes = [];
  bool writeFails = false;

  /// The voice chat mode the screen wrote, which the status reports back.
  String? writtenMode;

  /// While set, no request is answered: the server is slow or unreachable.
  Completer<void>? hold;

  late final DashboardClient client = DashboardClient(
    host: 'hermes-demo.local',
    manualToken: 'test-token',
    httpClientOverride: MockClient(_answer),
  );

  static http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  static void _merge(Map<String, dynamic> into, Map<dynamic, dynamic> patch) {
    for (final entry in patch.entries) {
      final key = entry.key as String;
      final value = entry.value;
      final existing = into[key];
      if (value is Map && existing is Map<String, dynamic>) {
        _merge(existing, value);
      } else if (value is Map) {
        final created = <String, dynamic>{};
        _merge(created, value);
        into[key] = created;
      } else {
        into[key] = value;
      }
    }
  }

  Future<http.Response> _answer(http.Request request) async {
    requests.add(request);
    await hold?.future;
    final path = request.url.path;
    if (request.method == 'GET' && path == '/api/config') {
      return _json(config);
    }
    if (path == '/api/config/schema') return _json(const {'fields': {}});
    if (request.method == 'PUT' && path == '/api/config') {
      writes.add(request);
      if (writeFails) return _json(const {}, 500);
      final patch = (jsonDecode(request.body) as Map)['config'] as Map;
      _merge(config, patch);
      final voicePatch = patch['voice'];
      if (voicePatch is Map && voicePatch['voice_chat_mode'] is String) {
        writtenMode = voicePatch['voice_chat_mode'] as String;
      }
      return _json(const {'ok': true});
    }
    if (path == '/api/audio/voice-live/status') {
      final status = live;
      return status == null
          ? _json(const {}, 404)
          : _json({...status, 'mode': writtenMode ?? status['mode']});
    }
    if (request.method == 'POST' && path.startsWith('/api/audio/')) {
      return _json(const {}, voice ? 422 : 404);
    }
    return _json(const {}, 404);
  }

  Map<String, dynamic> lastPatch() =>
      (jsonDecode(writes.last.body) as Map)['config'] as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SavedConnection connection({bool readOnly = false}) => SavedConnection(
    id: 'demo-node',
    label: 'Server',
    host: 'hermes-demo.local',
    port: 8642,
    apiKey: 'test-key',
    dashboardUrl: _base,
    readOnly: readOnly,
  );

  /// Opens voice settings against [server]. [stored] is what the phone
  /// already remembers; [serverVoice] chooses "Servidor Hermes" as the reply
  /// voice of this connection.
  Future<(VoiceService, SharedPreferences)> open(
    WidgetTester tester,
    _Server server, {
    Map<String, Object> stored = const {},
    bool serverVoice = false,
    bool readOnly = false,
    bool settle = true,
    Locale locale = const Locale('es'),
    String? profile,
    VoiceTryChatOpener? opener,
  }) async {
    SharedPreferences.setMockInitialValues({
      'voice_tts_engine': TtsEngineKind.device.id,
      'voice_stt_engine': SttEngineKind.system.id,
      if (serverVoice) ...{
        'native_voice_consent::$_base': 'accepted',
        'native_voice_mode_v1::$_base': 'server',
      },
      ...stored,
    });
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    addTearDown(server.client.close);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: VoiceSettingsScreen(
          voiceService: voice,
          connection: connection(readOnly: readOnly),
          preferences: prefs,
          dashboardClientFactory: (_) => server.client,
          profile: profile,
          voiceTryChatOpener: opener,
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
    return (voice, prefs);
  }

  Future<void> openPage(WidgetTester tester, String row) async {
    final finder = find.byKey(ValueKey('voice_main_$row'));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    expect(finder, findsOneWidget, reason: key);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// The label and value a field row shows.
  List<String> rowCopy(WidgetTester tester, String key) => [
    for (final text in tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Text),
      ),
    ))
      text.data ?? '',
  ];

  /// Whether the row can be tapped to change its value.
  bool opens(WidgetTester tester, String key) =>
      tester.widget<InkWell>(find.byKey(ValueKey(key))).onTap != null;

  /// Every label in the option list that is open.
  List<String> optionLabels(WidgetTester tester, String surface) => [
    for (final text in tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(ValueKey(surface)),
        matching: find.byType(Text),
      ),
    ))
      text.data ?? '',
  ];

  Iterable<String> screenCopy(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '');

  Map<String, dynamic> openAiVoice() => {
    'tts': {
      'provider': 'openai',
      'openai': {'model': 'gpt-4o-mini-tts', 'voice': 'marin'},
    },
    'stt': {
      'enabled': true,
      'echo_transcripts': false,
      'streaming': false,
      'provider': 'local',
      'local': {'model': 'small', 'language': 'es'},
    },
    'voice': {
      'voice_chat_mode': 'chained',
      'max_recording_seconds': 120,
      'gpt_live': {'voice': 'cedar', 'instructions': ''},
    },
  };

  group('painting before the server answers', () {
    testWidgets('the main list shows its rows with the last known values', (
      tester,
    ) async {
      final server = _Server(config: openAiVoice())..hold = Completer<void>();
      final known = ServerVoiceFields.read({
        'tts': {
          'provider': 'openai',
          'openai': {'model': 'gpt-4o-mini-tts', 'voice': 'nova'},
        },
        'stt': {
          'provider': 'local',
          'local': {'model': 'base', 'language': ''},
        },
      }, const {});

      await open(
        tester,
        server,
        serverVoice: true,
        settle: false,
        stored: {
          'server_voice_fields_v1::$_base': known.encode(),
          'voice_chat_mode_v1::demo-node::': 'gpt-live',
          'voice_stt_engine': SttEngineKind.hermesServer.id,
        },
      );

      // Not one response has arrived, and this is the first frame.
      expect(server.writes, isEmpty);
      for (final key in const [
        'voice_conversation_chained',
        'voice_gpt_live_enabled',
        'voice_main_dictation',
        'voice_main_reply_voice',
        'voice_auto_speak',
        'voice_continue_when_locked',
        'voice_main_advanced',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(rowCopy(tester, 'voice_main_reply_voice'), [
        'Voz de las respuestas',
        'OpenAI · nova',
      ]);
      expect(rowCopy(tester, 'voice_main_dictation'), [
        'Dictado',
        'Servidor Hermes',
      ]);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);

      // The sub-screens paint the same way, with the fields last read.
      await openPage(tester, 'reply_voice');
      expect(rowCopy(tester, 'voice_field_tts.provider'), [
        'Proveedor',
        'OpenAI',
      ]);
      expect(rowCopy(tester, 'voice_field_tts.openai.voice'), ['Voz', 'nova']);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
      await tester.pumpAndSettle();
      await openPage(tester, 'dictation');
      expect(rowCopy(tester, 'voice_field_stt.local.model'), [
        'Modelo',
        'base',
      ]);
      expect(rowCopy(tester, 'voice_field_stt.local.language'), [
        'Idioma',
        'Automático',
      ]);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // When the server answers, the rows take what it says now.
      server.hold!.complete();
      server.hold = null;
      await tester.pumpAndSettle();
      expect(rowCopy(tester, 'voice_field_stt.local.model'), [
        'Modelo',
        'small',
      ]);
      Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
      await tester.pumpAndSettle();
      expect(rowCopy(tester, 'voice_main_reply_voice').last, 'OpenAI · marin');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a first visit shows the rows too, with nothing to wait for', (
      tester,
    ) async {
      final server = _Server(config: openAiVoice())..hold = Completer<void>();
      await open(tester, server, settle: false);

      for (final key in const [
        'voice_main_dictation',
        'voice_main_reply_voice',
        'voice_auto_speak',
        'voice_continue_when_locked',
        'voice_main_advanced',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(rowCopy(tester, 'voice_main_reply_voice').last, 'Voz de Android');
      expect(find.byType(CircularProgressIndicator), findsNothing);

      server.hold!.complete();
      server.hold = null;
      await tester.pumpAndSettle();
      // What was read is remembered for the next visit.
      final prefs = await SharedPreferences.getInstance();
      final remembered = ServerVoiceFieldsStore(prefs).read(_base)!;
      expect(remembered.text('tts.openai.voice'), 'marin');
      expect(tester.takeException(), isNull);
    });
  });

  group('reply voice from the Hermes server', () {
    testWidgets('shows Desktop\'s fields as pickers and writes the choice for '
        'the profile', (tester) async {
      final server = _Server(config: openAiVoice());
      await open(tester, server, serverVoice: true);
      await openPage(tester, 'reply_voice');

      // Only the chosen option shows its rows; the other is one line.
      expect(
        find.byKey(const ValueKey('voice_phone_voice_picker')),
        findsNothing,
      );
      expect(rowCopy(tester, 'voice_mode_phone_option'), [
        'En este teléfono',
        'Voz de Android',
      ]);
      expect(rowCopy(tester, 'voice_mode_server_option'), [
        'Servidor Hermes',
        'OpenAI · marin',
      ]);
      expect(rowCopy(tester, 'voice_field_tts.provider'), [
        'Proveedor',
        'OpenAI',
      ]);
      expect(rowCopy(tester, 'voice_field_tts.openai.model'), [
        'Modelo',
        'gpt-4o-mini-tts',
      ]);
      expect(rowCopy(tester, 'voice_field_tts.openai.voice'), ['Voz', 'marin']);
      expect(
        find.byKey(const ValueKey('voice_test_server_voice')),
        findsOneWidget,
      );
      // Nothing is typed anywhere on this screen.
      expect(find.byType(TextField), findsNothing);

      await tapKey(tester, 'voice_field_tts.openai.voice');
      // The list is Desktop's, in its order; the rest scrolls or is searched.
      expect(
        optionLabels(tester, 'voice_field_options'),
        containsAllInOrder(kServerVoiceOptions['tts.openai.voice']!.take(5)),
      );
      await tapKey(tester, 'voice_option_echo');

      expect(server.writes, hasLength(1));
      expect(server.writes.single.url.path, '/api/config');
      expect(server.lastPatch(), {
        'tts': {
          'openai': {'voice': 'echo'},
        },
      });
      expect(rowCopy(tester, 'voice_field_tts.openai.voice'), ['Voz', 'echo']);
      expect(rowCopy(tester, 'voice_mode_server_option').last, 'OpenAI · echo');
      expect(tester.takeException(), isNull);
    });

    testWidgets('another provider brings its own fields', (tester) async {
      final config = openAiVoice();
      (config['tts'] as Map<String, dynamic>)['edge'] = {
        'voice': 'es-ES-ElviraNeural',
      };
      final server = _Server(config: config);
      await open(tester, server, serverVoice: true);
      await openPage(tester, 'reply_voice');

      await tapKey(tester, 'voice_field_tts.provider');
      expect(optionLabels(tester, 'voice_field_options'), contains('Edge'));
      await tapKey(tester, 'voice_option_edge');

      expect(server.lastPatch(), {
        'tts': {'provider': 'edge'},
      });
      expect(rowCopy(tester, 'voice_field_tts.provider').last, 'Edge');
      expect(rowCopy(tester, 'voice_field_tts.edge.voice'), [
        'Voz',
        'Elvira · es-ES',
      ]);
      expect(
        find.byKey(const ValueKey('voice_field_tts.openai.voice')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('voice_field_tts.openai.model')),
        findsNothing,
      );
    });

    testWidgets('a field without options is shown and cannot be changed, and '
        'one the server does not report is not shown', (tester) async {
      final server = _Server(
        config: {
          'tts': {
            'provider': 'elevenlabs',
            'elevenlabs': {'voice_id': 'cloned-voice'},
          },
        },
      );
      await open(tester, server, serverVoice: true);
      await openPage(tester, 'reply_voice');

      expect(rowCopy(tester, 'voice_field_tts.elevenlabs.voice_id'), [
        'Voz',
        'cloned-voice',
      ]);
      expect(opens(tester, 'voice_field_tts.elevenlabs.voice_id'), isFalse);
      // The server said nothing about a model: no row for it.
      expect(
        find.byKey(const ValueKey('voice_field_tts.elevenlabs.model_id')),
        findsNothing,
      );
      expect(opens(tester, 'voice_field_tts.provider'), isTrue);
    });

    testWidgets('a failed write keeps the value and says so', (tester) async {
      final server = _Server(config: openAiVoice())..writeFails = true;
      await open(tester, server, serverVoice: true);
      await openPage(tester, 'reply_voice');

      await tapKey(tester, 'voice_field_tts.openai.voice');
      await tapKey(tester, 'voice_option_echo');

      expect(server.writes, hasLength(1));
      expect(rowCopy(tester, 'voice_field_tts.openai.voice'), ['Voz', 'marin']);
      expect(
        find.text(
          'No se pudo guardar la configuración. Los valores anteriores '
          'siguen activos.',
        ),
        findsOneWidget,
      );
      HermesNotice.of(
        tester.element(find.byType(Scaffold).last),
      ).clearSnackBars();
      await tester.pumpAndSettle();
    });

    testWidgets('a read-only connection sees the fields and cannot change '
        'them', (tester) async {
      final server = _Server(config: openAiVoice());
      await open(tester, server, serverVoice: true, readOnly: true);
      await openPage(tester, 'reply_voice');

      expect(rowCopy(tester, 'voice_field_tts.openai.voice'), ['Voz', 'marin']);
      for (final key in const [
        'voice_field_tts.provider',
        'voice_field_tts.openai.model',
        'voice_field_tts.openai.voice',
      ]) {
        expect(opens(tester, key), isFalse, reason: key);
      }
      await tester.tap(
        find.byKey(const ValueKey('voice_field_tts.openai.voice')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('voice_field_options')), findsNothing);
      expect(server.writes, isEmpty);
    });
  });

  group('reply voice from this phone', () {
    testWidgets('is one voice row and the test, with no explanations', (
      tester,
    ) async {
      final server = _Server(config: openAiVoice());
      final (voice, _) = await open(tester, server);
      await openPage(tester, 'reply_voice');

      // The server option is one collapsed line.
      expect(
        find.byKey(const ValueKey('voice_server_summary_card')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('voice_field_tts.provider')),
        findsNothing,
      );
      expect(rowCopy(tester, 'voice_mode_server_option'), [
        'Servidor Hermes',
        'OpenAI · marin',
      ]);
      expect(rowCopy(tester, 'voice_phone_voice'), ['Voz', 'Voz de Android']);
      expect(
        find.byKey(const ValueKey('voice_setup_test_action')),
        findsOneWidget,
      );
      // Two options, one row and one button: nothing else is said.
      final copy = screenCopy(tester).toList();
      expect(copy, [
        'Servidor Hermes',
        'OpenAI · marin',
        'En este teléfono',
        'Voz de Android',
        'Voz',
        'Voz de Android',
        'Probar',
        'Voz de las respuestas',
      ]);

      await tapKey(tester, 'voice_phone_voice');
      final names = optionLabels(tester, 'voice_phone_voice_options');
      expect(names, contains('Voz de Android'));
      for (final neural in kNeuralVoices) {
        expect(names, contains(neural.displayName));
      }
      for (final noise in const ['GrapheneOS', 'Google', 'motor', 'Piper']) {
        expect(
          names.where(
            (name) => name.toLowerCase().contains(noise.toLowerCase()),
          ),
          isEmpty,
          reason: noise,
        );
      }
      await tapKey(tester, 'voice_phone_voice_android');
      expect(voice.settings.ttsEngine, TtsEngineKind.device);
      expect(tester.takeException(), isNull);
    });

    testWidgets('choosing "Servidor Hermes" folds the phone rows and opens '
        'the server\'s', (tester) async {
      final server = _Server(config: openAiVoice());
      final (_, prefs) = await open(tester, server);
      await openPage(tester, 'reply_voice');

      await tapKey(tester, 'voice_mode_server_option');

      expect(prefs.getString('native_voice_mode_v1::$_base'), 'server');
      expect(
        find.byKey(const ValueKey('voice_phone_voice_picker')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('voice_server_summary_card')),
        findsOneWidget,
      );
      expect(rowCopy(tester, 'voice_field_tts.openai.voice'), ['Voz', 'marin']);

      await tapKey(tester, 'voice_mode_phone_option');
      expect(prefs.getString('native_voice_mode_v1::$_base'), 'phone');
      expect(
        find.byKey(const ValueKey('voice_server_summary_card')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('voice_phone_voice_picker')),
        findsOneWidget,
      );
    });
  });

  group('dictation', () {
    testWidgets('through the Hermes server shows Desktop\'s speech-to-text '
        'fields as pickers', (tester) async {
      final server = _Server(config: openAiVoice());
      final (voice, _) = await open(
        tester,
        server,
        stored: {
          'voice_stt_engine': SttEngineKind.hermesServer.id,
          'native_voice_consent::$_base': 'accepted',
        },
      );
      await openPage(tester, 'dictation');

      expect(
        find.byKey(const ValueKey('voice_phone_dictation_picker')),
        findsNothing,
      );
      expect(rowCopy(tester, 'voice_dictation_server_option'), [
        'Servidor Hermes',
        'Whisper · small',
      ]);
      expect(rowCopy(tester, 'voice_field_stt.provider'), [
        'Proveedor',
        'Whisper',
      ]);
      expect(rowCopy(tester, 'voice_field_stt.local.model'), [
        'Modelo',
        'small',
      ]);
      expect(rowCopy(tester, 'voice_field_stt.local.language'), [
        'Idioma',
        'Español',
      ]);
      expect(find.byType(TextField), findsNothing);

      // The language is a picker with "automatic", which is stored empty.
      await tapKey(tester, 'voice_field_stt.local.language');
      expect(
        optionLabels(tester, 'voice_field_options'),
        containsAllInOrder([
          'Idioma',
          'Automático',
          'Español',
          'Inglés',
          'Français',
          'Deutsch',
          'Português',
          'Italiano',
        ]),
      );
      await tapKey(tester, 'voice_option_');
      expect(server.lastPatch(), {
        'stt': {
          'local': {'language': ''},
        },
      });
      expect(
        rowCopy(tester, 'voice_field_stt.local.language').last,
        'Automático',
      );

      await tapKey(tester, 'voice_field_stt.local.model');
      expect(
        optionLabels(tester, 'voice_field_options'),
        containsAll(kServerVoiceOptions['stt.local.model']!),
      );
      await tapKey(tester, 'voice_option_turbo');
      expect(server.lastPatch(), {
        'stt': {
          'local': {'model': 'turbo'},
        },
      });
      expect(
        rowCopy(tester, 'voice_dictation_server_option').last,
        'Whisper · turbo',
      );
      expect(voice.settings.sttEngine, SttEngineKind.hermesServer);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a literal "auto" language is repaired by choosing automatic', (
      tester,
    ) async {
      final config = openAiVoice();
      ((config['stt'] as Map)['local'] as Map)['language'] = 'auto';
      final server = _Server(config: config);
      await open(
        tester,
        server,
        stored: {
          'voice_stt_engine': SttEngineKind.hermesServer.id,
          'native_voice_consent::$_base': 'accepted',
        },
      );
      await openPage(tester, 'dictation');

      expect(
        rowCopy(tester, 'voice_field_stt.local.language').last,
        'Automático',
      );
      await tapKey(tester, 'voice_field_stt.local.language');
      await tapKey(tester, 'voice_option_');
      expect(server.lastPatch(), {
        'stt': {
          'local': {'language': ''},
        },
      });
    });

    testWidgets('on this phone is one model row with every model by name', (
      tester,
    ) async {
      final server = _Server(config: openAiVoice());
      final (voice, _) = await open(tester, server);
      await openPage(tester, 'dictation');

      expect(
        find.byKey(const ValueKey('voice_dictation_server_fields')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('voice_field_stt.provider')),
        findsNothing,
      );
      expect(screenCopy(tester).toList(), [
        'Servidor Hermes',
        'Whisper · small',
        'En este teléfono',
        'Reconocedor de Android',
        'Modelo',
        'Reconocedor de Android',
        'Dictado',
      ]);

      await tapKey(tester, 'voice_phone_dictation_model');
      final names = optionLabels(tester, 'voice_phone_dictation_options');
      for (final model in kSherpaSttModels) {
        expect(names, contains(model.displayName));
      }
      expect(names, containsAll(['Whisper tiny', 'Reconocedor de Android']));
      for (final noise in const ['GrapheneOS', 'Google', 'sherpa', 'motor']) {
        expect(
          names.where(
            (name) => name.toLowerCase().contains(noise.toLowerCase()),
          ),
          isEmpty,
          reason: noise,
        );
      }

      // A model that transcribes when you finish: one tap sets engine and size.
      await tapKey(tester, 'voice_option_whisper_tiny');
      expect(voice.settings.sttEngine, SttEngineKind.whisper);
      expect(voice.settings.whisperModel, SttModelSize.tiny);
      expect(rowCopy(tester, 'voice_phone_dictation_model'), [
        'Modelo',
        'Whisper tiny',
      ]);
      expect(
        rowCopy(tester, 'voice_dictation_phone_option').last,
        'Whisper tiny',
      );

      await tapKey(tester, 'voice_phone_dictation_model');
      await tapKey(tester, 'voice_option_system');
      expect(voice.settings.sttEngine, SttEngineKind.system);
      expect(tester.takeException(), isNull);
    });

    testWidgets('going to the server and back returns to the phone model '
        'that was in use', (tester) async {
      final server = _Server(config: openAiVoice());
      final (voice, prefs) = await open(tester, server);
      await openPage(tester, 'dictation');

      await tapKey(tester, 'voice_dictation_server_option');
      expect(voice.settings.sttEngine, SttEngineKind.hermesServer);
      expect(prefs.getString('native_voice_consent::$_base'), 'accepted');
      expect(
        find.byKey(const ValueKey('voice_phone_dictation_picker')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('voice_dictation_server_fields')),
        findsOneWidget,
      );
      expect(rowCopy(tester, 'voice_dictation_phone_option'), [
        'En este teléfono',
        'Reconocedor de Android',
      ]);

      await tapKey(tester, 'voice_dictation_phone_option');
      expect(voice.settings.sttEngine, SttEngineKind.system);
      expect(
        find.byKey(const ValueKey('voice_dictation_server_fields')),
        findsNothing,
      );
    });

    testWidgets('a server without transcription cannot be chosen', (
      tester,
    ) async {
      final server = _Server(config: openAiVoice(), voice: false);
      final (voice, _) = await open(tester, server);
      await openPage(tester, 'dictation');

      expect(opens(tester, 'voice_dictation_server_option'), isFalse);
      await tester.tap(
        find.byKey(const ValueKey('voice_dictation_server_option')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(voice.settings.sttEngine, SttEngineKind.system);
    });
  });

  group('advanced', () {
    testWidgets('holds Desktop\'s remaining fields as plain rows and the two '
        'phone switches', (tester) async {
      final server = _Server(
        config: openAiVoice(),
        live: const {
          'ok': true,
          'mode': 'chained',
          'available': true,
          'reason': null,
        },
      );
      final (voice, _) = await open(tester, server);
      await openPage(tester, 'advanced');

      // Desktop's titles, and under them only labels and values.
      expect(screenCopy(tester).toList(), [
        'CONVERSACIÓN POR VOZ',
        'Duración máxima de grabación',
        '120 s',
        'Interrumpir hablando',
        'VOZ A TEXTO',
        'Voz a texto',
        'Eco de transcripciones',
        'Transcripción en directo',
        'Parar al detectar silencio',
        'Avanzado',
      ]);
      // The mode and, with GPT-Live, its voice and personality are on the
      // main list: nothing of GPT-Live is repeated here.
      expect(
        find.byKey(const ValueKey('voice_advanced_chat_mode')),
        findsNothing,
      );
      expect(find.textContaining('GPT-Live'), findsNothing);
      // What "Dictado" and "Voz de las respuestas" already show is not here.
      for (final key in const [
        'voice_field_voice.gpt_live.voice',
        'voice_field_voice.gpt_live.instructions',
        'voice_field_tts.provider',
        'voice_field_tts.openai.voice',
        'voice_field_stt.provider',
        'voice_field_stt.local.model',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }

      await tapKey(tester, 'voice_field_voice.max_recording_seconds');
      await tapKey(tester, 'voice_option_60');
      expect(server.lastPatch(), {
        'voice': {'max_recording_seconds': 60},
      });
      expect(find.text('60 s'), findsOneWidget);

      await tapKey(tester, 'voice_field_stt.echo_transcripts');
      expect(server.lastPatch(), {
        'stt': {'echo_transcripts': true},
      });
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('voice_field_stt.echo_transcripts')),
            )
            .value,
        isTrue,
      );

      // The two phone switches are the phone's own settings.
      final writes = server.writes.length;
      await tapKey(tester, 'voice_barge_in_enabled');
      await tapKey(tester, 'voice_vad_enabled');
      expect(voice.settings.bargeInEnabled, isTrue);
      expect(voice.settings.vadEnabled, isFalse);
      expect(server.writes, hasLength(writes));
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows no GPT-Live field on a server without it, and only '
        'what the server reports', (tester) async {
      final server = _Server(
        config: {
          'tts': {'provider': 'edge'},
          'stt': {'enabled': true},
        },
      );
      await open(tester, server);
      await openPage(tester, 'advanced');

      expect(screenCopy(tester).toList(), [
        'CONVERSACIÓN POR VOZ',
        'Interrumpir hablando',
        'VOZ A TEXTO',
        'Voz a texto',
        'Parar al detectar silencio',
        'Avanzado',
      ]);
    });

    testWidgets('does not repeat the voice chat mode, which is on the main '
        'list even when GPT-Live cannot start', (tester) async {
      final server = _Server(
        config: openAiVoice(),
        live: const {
          'ok': true,
          'mode': 'chained',
          'available': false,
          'reason': 'OpenAI API key is not configured',
        },
      );
      await open(tester, server);
      // On the main list: both options, and why GPT-Live cannot be chosen.
      expect(
        find.byKey(const ValueKey('voice_gpt_live_enabled')),
        findsOneWidget,
      );
      expect(
        find.text('GPT-Live necesita una clave de OpenAI en el servidor'),
        findsOneWidget,
      );
      await openPage(tester, 'advanced');

      expect(
        find.byKey(const ValueKey('voice_advanced_chat_mode')),
        findsNothing,
      );
      expect(find.text('Modo de chat de voz'), findsNothing);
      // Unavailable: no GPT-Live voice or personality to set.
      expect(
        find.byKey(const ValueKey('voice_field_voice.gpt_live.voice')),
        findsNothing,
      );
      expect(find.textContaining('GPT-Live'), findsNothing);
      expect(server.writes, isEmpty);
    });

    testWidgets('keeps the server\'s speech-to-text fields reachable when it '
        'listens only in the conversation', (tester) async {
      final server = _Server(config: openAiVoice());
      await open(tester, server, serverVoice: true);
      await openPage(tester, 'advanced');

      // Dictation is on the phone, so these are not under "Dictado"; the
      // server still listens in a voice conversation.
      expect(rowCopy(tester, 'voice_field_stt.provider'), [
        'Proveedor',
        'Whisper',
      ]);
      expect(rowCopy(tester, 'voice_field_stt.local.language'), [
        'Idioma',
        'Español',
      ]);
      await tapKey(tester, 'voice_field_stt.local.language');
      await tapKey(tester, 'voice_option_en');
      expect(server.lastPatch(), {
        'stt': {
          'local': {'language': 'en'},
        },
      });
    });

    testWidgets('a read-only connection cannot change a server field', (
      tester,
    ) async {
      final server = _Server(config: openAiVoice());
      await open(tester, server, readOnly: true);
      await openPage(tester, 'advanced');

      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('voice_field_stt.enabled')),
            )
            .onChanged,
        isNull,
      );
      await tester.tap(
        find.byKey(const ValueKey('voice_field_voice.max_recording_seconds')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('voice_field_options')), findsNothing);
      expect(server.writes, isEmpty);
    });
  });

  group('GPT-Live on the main list', () {
    Map<String, dynamic> liveStatus({
      String mode = 'gpt-live',
      bool available = true,
      String? reason,
    }) => {
      'ok': true,
      'mode': mode,
      'available': available,
      'reason': reason,
      'voice': 'cedar',
    };

    const setupKeys = [
      'voice_field_voice.gpt_live.voice',
      'voice_field_voice.gpt_live.instructions',
      'voice_live_try',
    ];

    void expectNoSetupRows() {
      for (final key in setupKeys) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(find.text('Abre una conversación de voz'), findsNothing);
    }

    testWidgets('chosen and available, it shows its voice, its personality '
        'and the test under the row, and Advanced no longer has them', (
      tester,
    ) async {
      final server = _Server(config: openAiVoice(), live: liveStatus());
      await open(tester, server);

      // Right under the choice and above the next row of the list.
      var previous = tester
          .getBottomLeft(find.byKey(const ValueKey('voice_gpt_live_enabled')))
          .dy;
      for (final key in setupKeys) {
        final row = find.byKey(ValueKey(key));
        expect(row, findsOneWidget, reason: key);
        expect(tester.getTopLeft(row).dy, greaterThanOrEqualTo(previous));
        previous = tester.getBottomLeft(row).dy;
      }
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('voice_main_dictation')))
            .dy,
        greaterThan(previous),
      );
      expect(rowCopy(tester, 'voice_field_voice.gpt_live.voice'), [
        'Voz',
        'cedar',
      ]);
      expect(rowCopy(tester, 'voice_field_voice.gpt_live.instructions'), [
        'Personalidad',
        'Por defecto',
      ]);
      expect(rowCopy(tester, 'voice_live_try'), ['Probar']);
      // One short line says what the button does; nothing about prices.
      expect(find.text('Abre una conversación de voz'), findsOneWidget);

      // The voice is a picker with GPT-Live's voices.
      await tapKey(tester, 'voice_field_voice.gpt_live.voice');
      expect(
        optionLabels(tester, 'voice_field_options'),
        containsAllInOrder([
          'Voz de GPT-Live',
          ...kServerVoiceOptions['voice.gpt_live.voice']!.take(5),
        ]),
      );
      await tapKey(tester, 'voice_option_marin');
      expect(server.lastPatch(), {
        'voice': {
          'gpt_live': {'voice': 'marin'},
        },
      });
      expect(rowCopy(tester, 'voice_field_voice.gpt_live.voice').last, 'marin');

      // The personality is the one-field dialog.
      await tapKey(tester, 'voice_field_voice.gpt_live.instructions');
      expect(find.text('Personalidad de GPT-Live'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('voice_live_personality_field')),
        '  Habla despacio.  ',
      );
      await tester.tap(
        find.byKey(const ValueKey('voice_live_personality_save')),
      );
      await tester.pumpAndSettle();
      expect(server.lastPatch(), {
        'voice': {
          'gpt_live': {'instructions': 'Habla despacio.'},
        },
      });
      expect(
        rowCopy(tester, 'voice_field_voice.gpt_live.instructions').last,
        'Habla despacio.',
      );

      // Nothing appears twice: Advanced has neither field.
      await openPage(tester, 'advanced');
      for (final key in setupKeys) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(find.textContaining('GPT-Live'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('"Probar" opens a new chat for the active profile with the '
        'voice conversation starting', (tester) async {
      final opened = <(SavedConnection, Session)>[];
      final server = _Server(config: openAiVoice(), live: liveStatus());
      await open(
        tester,
        server,
        profile: 'work',
        opener: (context, connection, session) =>
            opened.add((connection, session)),
      );

      await tapKey(tester, 'voice_live_try');

      expect(opened, hasLength(1));
      final (connection, session) = opened.single;
      expect(connection.id, 'demo-node');
      // A new conversation of the profile whose GPT-Live was just set up.
      expect(session.profile, 'work');
      expect(session.messageCount, 0);
      expect(session.id, isNotEmpty);
      expect(session.source, 'mobile');
      // What it opens is the app's own voice entry: the chat starts the
      // voice conversation by itself, with its consent and microphone steps.
      final chat = VoiceSettingsScreen.voiceTryChat(connection, session);
      expect(chat.initialVoiceMode, isTrue);
      expect(chat.initialDictation, isFalse);
      expect(chat.session, same(session));
      expect(chat.connection, same(connection));
      // The settings screen itself opened no audio and wrote nothing.
      expect(server.writes, isEmpty);
      expect(
        server.requests.where(
          (request) =>
              request.method == 'POST' &&
              request.url.path.startsWith('/api/audio/voice-live'),
        ),
        isEmpty,
      );
      // The status the conversation starts from is the one just read.
      expect(
        server.requests
            .where(
              (request) => request.url.path == '/api/audio/voice-live/status',
            )
            .every(
              (request) => request.url.queryParameters['profile'] == 'work',
            ),
        isTrue,
      );
    });

    testWidgets('"Probar" on the default profile opens a default-profile '
        'chat', (tester) async {
      final opened = <Session>[];
      final server = _Server(config: openAiVoice(), live: liveStatus());
      await open(
        tester,
        server,
        opener: (context, connection, session) => opened.add(session),
      );
      await tapKey(tester, 'voice_live_try');
      expect(opened.single.profile, 'default');
    });

    testWidgets('with Normal chosen the row stays one line', (tester) async {
      final server = _Server(
        config: openAiVoice(),
        live: liveStatus(mode: 'chained'),
      );
      await open(tester, server);
      expect(
        find.byKey(const ValueKey('voice_gpt_live_enabled')),
        findsOneWidget,
      );
      expectNoSetupRows();
      expect(find.byKey(const ValueKey('voice_live_reason')), findsNothing);

      // Choosing GPT-Live opens its rows; going back folds them.
      await tapKey(tester, 'voice_gpt_live_enabled');
      expect(server.lastPatch(), {
        'voice': {'voice_chat_mode': 'gpt-live'},
      });
      for (final key in setupKeys) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      await tapKey(tester, 'voice_conversation_chained');
      expectNoSetupRows();
    });

    testWidgets('unavailable shows the reason and its key button, and none '
        'of the three rows', (tester) async {
      final server = _Server(
        config: openAiVoice(),
        live: liveStatus(
          available: false,
          reason:
              'no OpenAI API key (set OPENAI_API_KEY or '
              'voice.gpt_live.api_key)',
        ),
      );
      await open(tester, server);
      expect(
        find.text('GPT-Live necesita una clave de OpenAI en el servidor'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('voice_live_add_key')), findsOneWidget);
      expectNoSetupRows();
    });

    testWidgets('a read-only connection sees the voice and the personality, '
        'cannot change them and has nothing to try', (tester) async {
      final server = _Server(config: openAiVoice(), live: liveStatus());
      await open(tester, server, readOnly: true);

      expect(rowCopy(tester, 'voice_field_voice.gpt_live.voice'), [
        'Voz',
        'cedar',
      ]);
      expect(opens(tester, 'voice_field_voice.gpt_live.voice'), isFalse);
      expect(opens(tester, 'voice_field_voice.gpt_live.instructions'), isFalse);
      expect(find.byKey(const ValueKey('voice_live_try')), findsNothing);
      expect(find.text('Abre una conversación de voz'), findsNothing);
      expect(server.writes, isEmpty);
    });

    testWidgets('the rows paint from what the app last knew', (tester) async {
      final server = _Server(config: openAiVoice(), live: liveStatus())
        ..hold = Completer<void>();
      await open(
        tester,
        server,
        settle: false,
        stored: {
          'voice_live_status_v1::demo-node::': jsonEncode({
            'mode': 'gpt-live',
            'available': true,
            'reason': null,
            'voice': 'willow',
          }),
        },
      );

      // No response yet: the voice is the one the server last reported.
      expect(rowCopy(tester, 'voice_field_voice.gpt_live.voice'), [
        'Voz',
        'willow',
      ]);
      expect(rowCopy(tester, 'voice_field_voice.gpt_live.instructions'), [
        'Personalidad',
        'Por defecto',
      ]);
      expect(find.byKey(const ValueKey('voice_live_try')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      server.hold!.complete();
      server.hold = null;
      await tester.pumpAndSettle();
      expect(rowCopy(tester, 'voice_field_voice.gpt_live.voice').last, 'cedar');
    });
  });

  testWidgets('the lock-screen switch is on the main list with GPT-Live '
      'chosen too', (tester) async {
    final server = _Server(
      config: openAiVoice(),
      live: const {
        'ok': true,
        'mode': 'gpt-live',
        'available': true,
        'reason': null,
      },
    );
    await open(tester, server);

    expect(
      find.byKey(const ValueKey('voice_gpt_live_enabled')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('voice_continue_when_locked')),
      findsOneWidget,
    );
    expect(find.text('Seguir con la pantalla bloqueada'), findsOneWidget);
  });
}
