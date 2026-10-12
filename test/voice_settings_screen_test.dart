import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesStatusText;
import 'package:hermes_android/core/screens/voice_settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/hermes_speech_stream.dart';
import 'package:hermes_android/core/services/voice/read_aloud_session.dart';
import 'package:hermes_android/core/services/voice/server_voice_config.dart';
import 'package:hermes_android/core/services/voice/stt_sherpa.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';
import 'package:hermes_android/core/services/voice/tts_model_manager.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/quiet_feedback.dart';

class _HangingPreviewEngine implements TtsEngine {
  final Completer<void> _speaking = Completer<void>();

  @override
  Future<void> speak(String text) => _speaking.future;

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _ServerPreviewEngine implements TtsEngine {
  _ServerPreviewEngine(this.synthesize);

  final HermesSpeakRequest synthesize;
  bool stopped = false;

  @override
  Future<void> speak(String text) async {
    await synthesize(text);
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> dispose() async {}
}

class _FastTimeoutVoiceService extends VoiceService {
  _FastTimeoutVoiceService(SharedPreferences prefs)
    : super(prefs, SecureStorage());

  @override
  Future<TtsEngine?> buildOnnxPreview(NeuralVoice voice) async =>
      _HangingPreviewEngine();

  @override
  Future<void> previewTts(
    TtsEngine engine,
    String text, {
    Duration timeout = const Duration(seconds: 20),
  }) =>
      super.previewTts(engine, text, timeout: const Duration(milliseconds: 10));
}

class _TrackingHttpClient extends http.BaseClient {
  _TrackingHttpClient(this._delegate);

  final http.Client _delegate;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _delegate.send(request);

  @override
  void close() {
    closed = true;
    _delegate.close();
  }
}

/// Plays nothing and reports completion at once: enough for read-aloud tests.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host({
    Locale locale = const Locale('es'),
    VoiceService? voiceService,
    SavedConnection? connection,
    DashboardClientFactory? dashboardClientFactory,
    SharedPreferences? preferences,
    String? profile,
    Key? screenKey,
    HermesServerPreviewEngineFactory? serverPreviewEngineFactory,
  }) => MaterialApp(
    locale: locale,
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.fromId('dark'),
    home: VoiceSettingsScreen(
      key: screenKey,
      voiceService: voiceService,
      connection: connection,
      dashboardClientFactory: dashboardClientFactory,
      preferences: preferences,
      profile: profile,
      serverPreviewEngineFactory: serverPreviewEngineFactory,
    ),
  );

  // The main screen is a short list; everything else lives one tap deeper.
  // `page` is the main row to tap: dictation, reply_voice or advanced.
  const pageRoots = {
    'dictation': 'voice_page_dictation',
    'reply_voice': 'voice_page_speech',
    'advanced': 'voice_page_advanced',
  };

  Future<void> backToMain(WidgetTester tester) async {
    if (find.byKey(const ValueKey('voice_main_list')).evaluate().isNotEmpty) {
      return;
    }
    Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice_main_list')), findsOneWidget);
  }

  Future<void> openPage(WidgetTester tester, String page) async {
    final root = find.byKey(ValueKey(pageRoots[page]!));
    if (root.evaluate().isNotEmpty) return;
    await backToMain(tester);
    final row = find.byKey(ValueKey('voice_main_$page'));
    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(root, findsOneWidget);
  }

  Future<Finder> revealBlock(WidgetTester tester, String key) async {
    await openPage(tester, switch (key) {
      'voice_listening_section' => 'dictation',
      'voice_reading_section' => 'reply_voice',
      _ => 'advanced',
    });
    final section = find.byKey(ValueKey(key));
    expect(section, findsOneWidget);
    await Scrollable.ensureVisible(
      tester.element(section),
      alignment: 0.05,
      duration: Duration.zero,
    );
    await tester.pump();
    return section;
  }

  Future<void> openListeningStep(WidgetTester tester) async {
    await revealBlock(tester, 'voice_reading_section');
    expect(
      find.byKey(const ValueKey('voice_setup_test_action')),
      findsOneWidget,
    );
  }

  Future<void> openDictationSection(WidgetTester tester) =>
      revealBlock(tester, 'voice_listening_section');

  Future<void> openConversationSection(WidgetTester tester) =>
      revealBlock(tester, 'voice_conversation_section');

  bool isSelected(WidgetTester tester, String key) => tester
      .widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(Semantics),
            )
            .first,
      )
      .properties
      .selected!;

  /// Every string the screen has built, including the ones still folded
  /// behind an "Advanced" tile.
  Iterable<String> screenCopy(WidgetTester tester) sync* {
    for (final widget in tester.widgetList<Text>(
      find.byType(Text, skipOffstage: false),
    )) {
      yield widget.data ?? widget.textSpan!.toPlainText();
    }
    for (final widget in tester.widgetList<SelectableText>(
      find.byType(SelectableText, skipOffstage: false),
    )) {
      yield widget.data ?? widget.textSpan!.toPlainText();
    }
  }

  void expectNoJargon(WidgetTester tester) {
    final jargon = RegExp(
      r'\bSTT\b|\bTTS\b|endpoint|encadenad|chained',
      caseSensitive: false,
    );
    expect(screenCopy(tester).where(jargon.hasMatch), isEmpty);
  }

  test('deriva el perfil activo de la instancia y normaliza default', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final connection = SavedConnection(
      id: 'demo-node',
      label: 'Server',
      host: 'hermes-demo.local',
      port: 8642,
      apiKey: '',
    );
    await manager.setActiveProfile(connection.id, ' trabajo ');

    expect(
      resolveVoiceServerProfile(
        requestedProfile: null,
        manager: manager,
        connection: connection,
      ),
      'trabajo',
    );
    expect(
      resolveVoiceServerProfile(
        requestedProfile: 'default',
        manager: manager,
        connection: connection,
      ),
      isNull,
    );
    expect(
      resolveVoiceServerProfile(
        requestedProfile: 'explicito',
        manager: manager,
        connection: connection,
      ),
      'explicito',
    );
  });

  // What the short list may show, row by row, when GPT-Live is not on offer.
  List<String> mainListCopy(WidgetTester tester) => [
    for (final text in tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('voice_main_list')),
        matching: find.byType(Text),
      ),
    ))
      text.data ?? text.textSpan!.toPlainText(),
  ];

  testWidgets('the main screen is a short list of label and value', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump();

    final copy = mainListCopy(tester);
    expect(copy, hasLength(7));
    expect(copy.sublist(0, 2), ['Dictado', 'En este teléfono']);
    expect(copy[2], 'Voz de las respuestas');
    expect(copy[3], startsWith('En este teléfono · '));
    expect(copy.sublist(4), [
      'Leer respuestas en voz alta',
      'Seguir con la pantalla bloqueada',
      'Avanzado',
    ]);
    // Nothing else: no status while things work, no engine row without
    // GPT-Live, and none of the controls that moved one tap deeper.
    expect(find.byType(HermesStatusText), findsNothing);
    for (final key in const [
      'voice_conversation_chained',
      'voice_gpt_live_enabled',
      'voice_gpt_live_retry',
      'voice_mode_phone_option',
      'voice_mode_server_option',
      'voice_dictation_phone_option',
      'voice_setup_test_action',
      'voice_stt_location',
      'voice_barge_in_enabled',
      'voice_server_summary_card',
      'voice_conversation_enabled',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    expect(find.byKey(const ValueKey('voice_auto_speak')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice_continue_when_locked')),
      findsOneWidget,
    );
    final banned = RegExp(
      r'\bSTT\b|\bTTS\b|endpoint|encadenad|chained|full-duplex|instancia|'
      r'instance|proveedor|provider',
      caseSensitive: false,
    );
    expect(copy.where(banned.hasMatch), isEmpty);
    expect(find.text('Modo de voz'), findsNothing);
    expect(find.text('3. Probar'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('una URL pública HTTP inválida degrada voz sin pantallazo rojo', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final connection = SavedConnection(
      id: 'public-http',
      label: 'Public HTTP',
      host: 'example.com',
      port: 8642,
      apiKey: '',
      dashboardUrl: 'http://example.com:9119',
    );

    await tester.pumpWidget(host(connection: connection, preferences: prefs));
    await tester.pump();
    await openListeningStep(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.text('No se pudo leer ahora la configuración de voz.'),
      findsOneWidget,
    );
    final serverOption = tester.widget<InkWell>(
      find.byKey(const ValueKey('voice_mode_server_option')),
    );
    expect(serverOption.onTap, isNull);
  });

  testWidgets('la lista principal y sus pantallas están en inglés', (
    tester,
  ) async {
    await tester.pumpWidget(host(locale: const Locale('en')));
    await tester.pump();

    final copy = mainListCopy(tester);
    expect(copy.sublist(0, 3), ['Dictation', 'On this phone', 'Reply voice']);
    expect(copy[3], startsWith('On this phone · '));
    expect(copy.sublist(4), [
      'Read responses aloud',
      'Continue while the screen is locked',
      'Advanced',
    ]);
    expect(find.text('Voice mode'), findsNothing);

    // Dictation and reply voice ask the same thing, with the same words.
    await openDictationSection(tester);
    expect(find.text('Hermes server'), findsOneWidget);
    expect(find.text('On this phone'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Whisper base'), findsNWidgets(2));
    expect(find.text('Where dictation is transcribed'), findsNothing);
    expect(find.text('When audio is processed'), findsNothing);

    await openListeningStep(tester);
    expect(find.text('Hermes server'), findsOneWidget);
    expect(find.text('On this phone'), findsOneWidget);
    expect(find.text('Voice'), findsOneWidget);
    expect(find.text('Test'), findsOneWidget);

    await openPage(tester, 'advanced');
    for (final title in const ['VOICE CONVERSATION', 'SPEECH TO TEXT']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('TEXT TO SPEECH'), findsNothing);
    expect(find.text('Where voice is processed'), findsNothing);
    expect(find.text('All dictation engines'), findsNothing);
    expect(find.text('My transcription server'), findsNothing);
    expect(find.text('3. Test'), findsNothing);
    expect(find.textContaining('Three independent controls'), findsNothing);
    expectNoJargon(tester);
  });

  testWidgets('muestra la voz Edge real de Server con solo configurar y probar', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'native_voice_consent::http://hermes-demo.local:9119::profile=perfil-voz':
          'accepted',
      'native_voice_mode_v1::http://hermes-demo.local:9119::profile=perfil-voz':
          'server',
      'voice_sherpa_model': 'parakeet-v3',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    final requests = <http.Request>[];
    final dashboard = DashboardClient(
      host: 'hermes-demo.local',
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET' && request.url.path == '/api/config') {
          return http.Response(
            jsonEncode({
              'stt': {
                'provider': 'local',
                'local': {'model': 'whisper-small', 'language': 'en'},
              },
              'tts': {
                'provider': 'edge',
                'edge': {'voice': 'es-ES-ElviraNeural'},
              },
            }),
            200,
          );
        }
        if (request.method == 'GET' &&
            request.url.path == '/api/config/schema') {
          return http.Response(
            jsonEncode({
              'properties': {
                'stt': {
                  'properties': {
                    'provider': {
                      'enum': ['local', 'groq'],
                    },
                  },
                },
                'tts': {
                  'properties': {
                    'provider': {
                      'enum': ['edge', 'elevenlabs', 'custom_lab'],
                    },
                  },
                },
              },
            }),
            200,
          );
        }
        if (request.method == 'PUT' && request.url.path == '/api/config') {
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        if (request.method == 'POST' &&
            request.url.path == '/api/audio/speak') {
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        if (request.method == 'POST' &&
            request.url.path == '/api/audio/transcribe') {
          return http.Response('{}', 400);
        }
        return http.Response('{}', 404);
      }),
    );
    addTearDown(dashboard.close);
    final connection = SavedConnection(
      id: 'demo-node',
      label: 'Server',
      host: 'hermes-demo.local',
      port: 8642,
      apiKey: '',
      dashboardUrl: 'http://hermes-demo.local:9119',
    );

    await tester.pumpWidget(
      host(
        voiceService: voice,
        connection: connection,
        preferences: prefs,
        dashboardClientFactory: (_) => dashboard,
        profile: 'perfil-voz',
        serverPreviewEngineFactory: _ServerPreviewEngine.new,
      ),
    );
    await tester.pumpAndSettle();

    final schemaIndex = requests.indexWhere(
      (request) => request.url.path == '/api/config/schema',
    );
    final configIndex = requests.indexWhere(
      (request) => request.url.path == '/api/config',
    );
    expect(schemaIndex, greaterThanOrEqualTo(0));
    expect(configIndex, greaterThan(schemaIndex));
    expect(
      requests
          .where(
            (request) =>
                request.url.path.startsWith('/api/audio/') ||
                request.url.path.startsWith('/api/config'),
          )
          .every(
            (request) => request.url.queryParameters['profile'] == 'perfil-voz',
          ),
      isTrue,
    );

    // The main row names the voice in two words: provider and voice, no
    // model and nothing cut short.
    final copy = mainListCopy(tester);
    expect(copy.sublist(0, 4), [
      'Dictado',
      'En este teléfono',
      'Voz de las respuestas',
      'Edge · Elvira',
    ]);
    expect(find.textContaining('Endpoints'), findsNothing);
    expect(
      find.text(
        'El servidor escucha en Inglés; la app está en Español. '
        'Toca Voz de las respuestas.',
      ),
      findsOneWidget,
    );

    // Reply voice: two options, each with its voice; only the chosen one
    // shows how to change and test it.
    final reading = await revealBlock(tester, 'voice_reading_section');
    final serverVoice = find.byKey(const ValueKey('voice_server_summary_card'));
    final serverOption = find.byKey(const ValueKey('voice_mode_server_option'));
    final phoneOption = find.byKey(const ValueKey('voice_mode_phone_option'));
    expect(isSelected(tester, 'voice_mode_server_option'), isTrue);
    expect(isSelected(tester, 'voice_mode_phone_option'), isFalse);
    expect(
      find.descendant(of: serverOption, matching: find.text('Edge · Elvira')),
      findsOneWidget,
    );
    expect(find.descendant(of: reading, matching: serverVoice), findsOneWidget);
    // Desktop's fields for this provider are rows under the option.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('voice_field_tts.provider')),
        matching: find.text('Edge'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('voice_field_tts.edge.voice')),
        matching: find.text('Elvira · es-ES'),
      ),
      findsOneWidget,
    );
    expect(find.text('Cambiar voz'), findsNothing);
    expect(find.text('Probar'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice_phone_voice_picker')),
      findsNothing,
    );
    expect(find.text('Voz de Android'), findsNothing);
    expect(find.text('Voz para leer respuestas en el chat'), findsNothing);
    expect(
      tester.getTopLeft(phoneOption).dy,
      greaterThan(tester.getBottomLeft(serverVoice).dy),
    );
    // One line says what else the server does in a conversation.
    expect(
      find.text('En la conversación de voz, el servidor también te escucha.'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: reading,
        matching: find.byKey(const ValueKey('voice_server_language_mismatch')),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('voice_fix_server_language')),
      findsOneWidget,
    );
    expect(find.text('No disponible · audio por frases'), findsNothing);
    final details = find.byKey(const ValueKey('voice_server_details_toggle'));
    expect(find.descendant(of: serverVoice, matching: details), findsOneWidget);
    await Scrollable.ensureVisible(
      tester.element(details),
      alignment: 0.5,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(details);
    await tester.pump();
    expect(find.text('No disponible · audio por frases'), findsOneWidget);
    expectNoJargon(tester);

    // Dictation keeps its own engine; the selected shortcut needs no value.
    await openDictationSection(tester);
    expect(isSelected(tester, 'voice_dictation_phone_option'), isTrue);
    expect(
      find.byKey(const ValueKey('voice_applied_dictation_value')),
      findsNothing,
    );

    await revealBlock(tester, 'voice_reading_section');
    // Changing the voice no longer opens a separate manager.
    expect(
      find.byKey(const ValueKey('voice_manage_server_voice')),
      findsNothing,
    );
    // The wrong transcription language is fixed with a language picker.
    final fixLanguage = find.byKey(const ValueKey('voice_fix_server_language'));
    await Scrollable.ensureVisible(
      tester.element(fixLanguage),
      alignment: 0.5,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(fixLanguage);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice_field_options')), findsOneWidget);
    expect(find.text('Automático'), findsOneWidget);
    Navigator.of(
      tester.element(find.byKey(const ValueKey('voice_field_options'))),
    ).pop();
    await tester.pumpAndSettle();

    final testServerVoice = find.byKey(
      const ValueKey('voice_test_server_voice'),
    );
    await tester.ensureVisible(testServerVoice);
    await tester.pump();
    expect(
      find.descendant(of: testServerVoice, matching: find.text('Probar')),
      findsOneWidget,
    );
    expect(find.text('Probar voz del servidor'), findsNothing);
    await tester.tap(testServerVoice);
    await tester.pumpAndSettle();
    expectRoutineFeedback(tester, 'La prueba de voz se reprodujo.');
    expect(
      requests.where((request) {
        if (request.url.path != '/api/audio/speak' || request.body.isEmpty) {
          return false;
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return (body['text'] as String?)?.isNotEmpty == true;
      }),
      isNotEmpty,
    );
    expect(
      requests.where(
        (request) =>
            request.method == 'PUT' && request.url.path == '/api/config',
      ),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  // Pumps the screen on the Hermes server route with an OpenAI server voice
  // whose synthesis answers [detail] until [failing] is switched off.
  Future<void> pumpServerRoute(
    WidgetTester tester, {
    required String detail,
    required bool Function() failing,
    Locale locale = const Locale('es'),
  }) async {
    SharedPreferences.setMockInitialValues({
      'native_voice_consent::http://hermes-demo.local:9119': 'accepted',
      'native_voice_mode_v1::http://hermes-demo.local:9119': 'server',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    final dashboard = DashboardClient(
      host: 'hermes-demo.local',
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/config') {
          return http.Response(
            jsonEncode({
              'tts': {
                'provider': 'openai',
                'openai': {'voice': 'marin'},
              },
            }),
            200,
          );
        }
        if (request.url.path == '/api/config/schema') {
          return http.Response('{}', 200);
        }
        if (request.method == 'POST' &&
            request.url.path == '/api/audio/speak') {
          if (request.body.isEmpty || request.body == '{}') {
            return http.Response('{}', 422);
          }
          return failing()
              ? http.Response(jsonEncode({'detail': detail}), 400)
              : http.Response(jsonEncode({'ok': true}), 200);
        }
        if (request.method == 'POST' &&
            request.url.path.startsWith('/api/audio/')) {
          return http.Response('{}', 422);
        }
        return http.Response('{}', 404);
      }),
    );
    addTearDown(dashboard.close);
    await tester.pumpWidget(
      host(
        locale: locale,
        voiceService: voice,
        connection: SavedConnection(
          id: 'demo-node',
          label: 'Server',
          host: 'hermes-demo.local',
          port: 8642,
          apiKey: 'test-key',
          dashboardUrl: 'http://hermes-demo.local:9119',
        ),
        preferences: prefs,
        dashboardClientFactory: (_) => dashboard,
        serverPreviewEngineFactory: _ServerPreviewEngine.new,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapInView(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await Scrollable.ensureVisible(
      tester.element(target),
      alignment: 0.5,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> tapServerVoiceTest(WidgetTester tester) async {
    await tapInView(tester, 'voice_test_server_voice');
    // A failure is announced as a floating notice; clear it so it cannot sit
    // over the next tap target.
    HermesNotice.of(
      tester.element(find.byType(Scaffold).last),
    ).clearSnackBars();
    await tester.pumpAndSettle();
  }

  Future<void> toggleServerDetails(WidgetTester tester) =>
      tapInView(tester, 'voice_server_details_toggle');

  testWidgets(
    'a failed server test shows one plain line and keeps the server text '
    'behind details',
    (tester) async {
      const detail =
          'TTS configuration error (openai): tts is configured to use nous '
          'but it is not available';
      var speakFails = true;
      await pumpServerRoute(tester, detail: detail, failing: () => speakFails);
      const mainProblem = 'La prueba falló. Toca Voz de las respuestas.';

      // The main row says what really speaks in the conversation.
      expect(mainListCopy(tester).sublist(2, 4), [
        'Voz de las respuestas',
        'OpenAI · marin',
      ]);
      expect(find.text(mainProblem), findsNothing);

      final reading = await revealBlock(tester, 'voice_reading_section');
      final failed = find.descendant(
        of: reading,
        matching: find.text('La prueba falló'),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('voice_mode_server_option')),
          matching: find.text('OpenAI · marin'),
        ),
        findsOneWidget,
      );
      // No key is asked for while nothing says one is missing.
      expect(find.byKey(const ValueKey('voice_server_add_key')), findsNothing);
      // A healthy server voice announces nothing.
      expect(failed, findsNothing);
      expect(find.text('Servidor disponible'), findsNothing);

      await tapServerVoiceTest(tester);

      // An unrecognised reason gets the generic line, never the raw text.
      expect(failed, findsOneWidget);
      expect(find.textContaining('TTS configuration error'), findsNothing);
      expect(
        find.textContaining('El servidor de Hermes respondió'),
        findsNothing,
      );

      await toggleServerDetails(tester);
      final serverText = tester.widget<SelectableText>(
        find.byKey(const ValueKey('voice_server_test_error_detail')),
      );
      expect(serverText.data, detail);
      expect(find.text('Respuesta del servidor'), findsOneWidget);

      // The main screen names the problem and the row that fixes it.
      await backToMain(tester);
      expect(find.text(mainProblem), findsOneWidget);
      expect(find.textContaining('TTS configuration error'), findsNothing);

      // The user can retry from the same place once the provider is fixed.
      speakFails = false;
      await revealBlock(tester, 'voice_reading_section');
      await tapServerVoiceTest(tester);
      expect(failed, findsNothing);
      expect(
        find.byKey(const ValueKey('voice_server_test_error_detail')),
        findsNothing,
      );
      await backToMain(tester);
      expect(find.text(mainProblem), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in const [Locale('es'), Locale('en')]) {
    testWidgets('a server test without the provider key names the missing key '
        '(${locale.languageCode})', (tester) async {
      // The real Hermes text for an OpenAI voice without its key: longer
      // than any status line could hold.
      const detail =
          'TTS chunk 1 failed (openai): TTS configuration error (openai): '
          'tts is configured to use openai (set via hermes tools), but '
          'neither tts.openai.api_key in config nor '
          'VOICE_TOOLS_OPENAI_KEY/OPENAI_API_KEY is set. '
          "Run 'hermes tools' to change it.";
      expect(detail.length, greaterThan(200));
      await pumpServerRoute(
        tester,
        detail: detail,
        failing: () => true,
        locale: locale,
      );
      await revealBlock(tester, 'voice_reading_section');
      await tapServerVoiceTest(tester);

      final es = locale.languageCode == 'es';
      final summary = es
          ? 'Falta la clave de OpenAI en el servidor'
          : 'The OpenAI key is missing on the server';
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('voice_reading_section')),
          matching: find.text(summary),
        ),
        findsOneWidget,
      );
      // Nothing of the server's English is on screen until asked for.
      for (final raw in const ['OPENAI_API_KEY', 'TTS chunk', 'hermes tools']) {
        expect(find.textContaining(raw), findsNothing, reason: raw);
      }
      // The sentence comes with the one action that fixes it.
      expect(
        find.byKey(const ValueKey('voice_server_add_key')),
        findsOneWidget,
      );
      expect(find.text(es ? 'Añadir clave' : 'Add key'), findsOneWidget);

      await toggleServerDetails(tester);
      final serverText = tester.widget<SelectableText>(
        find.byKey(const ValueKey('voice_server_test_error_detail')),
      );
      // Whole, selectable, and never cut in the middle of a word.
      expect(serverText.data, detail);
      expect(serverText.data, isNot(contains('…')));

      await backToMain(tester);
      expect(
        find.text(
          es
              ? '$summary. Toca Voz de las respuestas.'
              : '$summary. Tap Reply voice.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('OPENAI_API_KEY'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  group('adding the missing server voice key', () {
    const missingKey =
        'TTS configuration error (openai): tts is configured to use openai '
        '(set via hermes tools), but neither tts.openai.api_key in config nor '
        'VOICE_TOOLS_OPENAI_KEY/OPENAI_API_KEY is set.';
    const secret = 'sk-test-0123456789abcdef';

    // Pumps a server route whose voice fails for lack of a key, with a
    // Dashboard that records every write of an environment variable.
    Future<List<http.Request>> pumpMissingKey(
      WidgetTester tester, {
      required bool Function() writeFails,
      String? profile,
      bool readOnly = false,
    }) async {
      final suffix = profile == null ? '' : '::profile=$profile';
      SharedPreferences.setMockInitialValues({
        'native_voice_consent::http://hermes-demo.local:9119$suffix':
            'accepted',
        'native_voice_mode_v1::http://hermes-demo.local:9119$suffix': 'server',
      });
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      addTearDown(voice.dispose);
      final writes = <http.Request>[];
      var keyStored = false;
      final dashboard = DashboardClient(
        host: 'hermes-demo.local',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'PUT' && path == '/api/env') {
            writes.add(request);
            if (writeFails()) return http.Response('{}', 500);
            keyStored = true;
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          if (request.method == 'GET' && path == '/api/config') {
            return http.Response(
              jsonEncode({
                'tts': {
                  'provider': 'openai',
                  'openai': {'voice': 'marin'},
                },
              }),
              200,
            );
          }
          if (path == '/api/config/schema') return http.Response('{}', 200);
          if (request.method == 'POST' && path == '/api/audio/speak') {
            if (request.body.isEmpty || request.body == '{}') {
              return http.Response('{}', 422);
            }
            return keyStored
                ? http.Response(jsonEncode({'ok': true}), 200)
                : http.Response(jsonEncode({'detail': missingKey}), 400);
          }
          if (request.method == 'POST' && path.startsWith('/api/audio/')) {
            return http.Response('{}', 422);
          }
          return http.Response('{}', 404);
        }),
      );
      addTearDown(dashboard.close);
      await tester.pumpWidget(
        host(
          voiceService: voice,
          connection: SavedConnection(
            id: 'demo-node',
            label: 'Server',
            host: 'hermes-demo.local',
            port: 8642,
            apiKey: 'test-key',
            dashboardUrl: 'http://hermes-demo.local:9119',
            readOnly: readOnly,
          ),
          preferences: prefs,
          dashboardClientFactory: (_) => dashboard,
          profile: profile,
          serverPreviewEngineFactory: _ServerPreviewEngine.new,
        ),
      );
      await tester.pumpAndSettle();
      await revealBlock(tester, 'voice_reading_section');
      await tapServerVoiceTest(tester);
      return writes;
    }

    Future<void> typeKeyAndSave(WidgetTester tester) async {
      await tapInView(tester, 'voice_server_add_key');
      expect(
        find.byKey(const ValueKey('voice_server_key_dialog')),
        findsOneWidget,
      );
      final field = find.byKey(const ValueKey('voice_server_key_field'));
      // One field, and what is typed is never readable.
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      await tester.enterText(field, '  $secret ');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('voice_server_key_save')));
      await tester.pumpAndSettle();
    }

    testWidgets('writes the provider variable for the active profile and '
        'never echoes the value', (tester) async {
      final writes = await pumpMissingKey(
        tester,
        writeFails: () => false,
        profile: 'work',
      );
      const sentence = 'Falta la clave de OpenAI en el servidor';
      expect(find.text(sentence), findsOneWidget);

      await typeKeyAndSave(tester);

      expect(writes, hasLength(1));
      expect(jsonDecode(writes.single.body), {
        'key': 'VOICE_TOOLS_OPENAI_KEY',
        'value': secret,
        'profile': 'work',
      });
      // The dialog is gone and the key is nowhere: not on screen, not in the
      // phone's preferences.
      expect(
        find.byKey(const ValueKey('voice_server_key_dialog')),
        findsNothing,
      );
      expect(find.textContaining(secret), findsNothing);
      expect(
        screenCopy(tester).where((text) => text.contains(secret)),
        isEmpty,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs
            .getKeys()
            .map(prefs.get)
            .where((value) => '$value'.contains(secret)),
        isEmpty,
      );
      // The server check ran again: the failure and its button are gone.
      expect(find.text(sentence), findsNothing);
      expect(find.byKey(const ValueKey('voice_server_add_key')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed write says so in one sentence and keeps the '
        'problem', (tester) async {
      final writes = await pumpMissingKey(tester, writeFails: () => true);
      await typeKeyAndSave(tester);

      expect(writes, hasLength(1));
      expect(jsonDecode(writes.single.body), {
        'key': 'VOICE_TOOLS_OPENAI_KEY',
        'value': secret,
      });
      expect(
        find.text('No se pudo guardar la clave en el servidor.'),
        findsOneWidget,
      );
      expect(find.textContaining(secret), findsNothing);
      expect(
        find.text('Falta la clave de OpenAI en el servidor'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('voice_server_add_key')),
        findsOneWidget,
      );
    });

    testWidgets('an empty key cannot be saved', (tester) async {
      final writes = await pumpMissingKey(tester, writeFails: () => false);
      await tapInView(tester, 'voice_server_add_key');
      await tester.tap(
        find.byKey(const ValueKey('voice_server_key_save')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('voice_server_key_dialog')),
        findsOneWidget,
      );
      expect(writes, isEmpty);
    });

    testWidgets('a read-only connection is not offered the key', (
      tester,
    ) async {
      final writes = await pumpMissingKey(
        tester,
        writeFails: () => false,
        readOnly: true,
      );
      expect(
        find.text('Falta la clave de OpenAI en el servidor'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('voice_server_add_key')), findsNothing);
      expect(writes, isEmpty);
    });
  });

  testWidgets('distingue autenticación del Dashboard de servidor caído', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'native_voice_consent::http://auth.local:9119': 'accepted',
      'native_voice_mode_v1::http://auth.local:9119': 'server',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    final dashboard = DashboardClient(
      host: 'auth.local',
      httpClientOverride: MockClient((_) async => http.Response('{}', 401)),
    );
    addTearDown(dashboard.close);
    final connection = SavedConnection(
      id: 'auth',
      label: 'Server',
      host: 'auth.local',
      port: 8642,
      apiKey: '',
      dashboardUrl: 'http://auth.local:9119',
    );

    await tester.pumpWidget(
      host(
        voiceService: voice,
        connection: connection,
        preferences: prefs,
        dashboardClientFactory: (_) => dashboard,
      ),
    );
    await tester.pumpAndSettle();

    // The main screen says what is wrong and where to fix it, in one line.
    expect(
      find.text(
        'Falta iniciar sesión en el servidor. Toca Voz de las respuestas.',
      ),
      findsOneWidget,
    );
    await revealBlock(tester, 'voice_reading_section');
    expect(find.text('Falta iniciar sesión en el servidor'), findsOneWidget);
    final auth = find.byKey(const ValueKey('voice_server_auth_action'));
    expect(auth, findsOneWidget);
    expect(find.text('Configurar acceso al Dashboard'), findsOneWidget);
    tester.widget<OutlinedButton>(auth).onPressed!();
    await tester.pump();
    expect(
      find.textContaining('El Dashboard requiere iniciar sesión'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('explica cómo activar voz cuando Hermes no publica endpoints', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'native_voice_consent::http://legacy.local:9119': 'accepted',
      'native_voice_mode_v1::http://legacy.local:9119': 'server',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    final dashboard = DashboardClient(
      host: 'legacy.local',
      manualToken: 'test-token',
      httpClientOverride: MockClient((_) async => http.Response('{}', 404)),
    );
    addTearDown(dashboard.close);
    final connection = SavedConnection(
      id: 'legacy',
      label: 'Hermes antiguo',
      host: 'legacy.local',
      port: 8642,
      apiKey: '',
      dashboardUrl: 'http://legacy.local:9119',
    );

    await tester.pumpWidget(
      host(
        voiceService: voice,
        connection: connection,
        preferences: prefs,
        dashboardClientFactory: (_) => dashboard,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('El servidor no ofrece voz ahora. Toca Voz de las respuestas.'),
      findsOneWidget,
    );
    await revealBlock(tester, 'voice_reading_section');
    expect(find.text('El servidor no ofrece voz ahora'), findsOneWidget);
    final update = find.byKey(const ValueKey('voice_server_update_action'));
    expect(update, findsOneWidget);
    expect(find.text('Cómo activar voz en Hermes'), findsOneWidget);
    tester.widget<OutlinedButton>(update).onPressed!();
    await tester.pump();

    expect(
      find.textContaining('La voz del servidor forma parte'),
      findsOneWidget,
    );
    expect(find.textContaining('endpoints'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no cierra un DashboardClient inyectado al desmontar', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    final httpClient = _TrackingHttpClient(
      MockClient((_) async => http.Response('{}', 404)),
    );
    final dashboard = DashboardClient(
      host: 'hermes-demo.local',
      manualToken: 'test-token',
      httpClientOverride: httpClient,
    );
    addTearDown(dashboard.close);
    final connection = SavedConnection(
      id: 'demo-node',
      label: 'Server',
      host: 'hermes-demo.local',
      port: 8642,
      apiKey: '',
      dashboardUrl: 'http://hermes-demo.local:9119',
    );

    await tester.pumpWidget(
      host(
        voiceService: voice,
        connection: connection,
        preferences: prefs,
        dashboardClientFactory: (_) => dashboard,
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(httpClient.closed, isFalse);
  });

  testWidgets(
    'no reutiliza PCM del proveedor A al recrearse con configuración B',
    (tester) async {
      HermesSpeechStreamEvidence.debugClear();
      addTearDown(HermesSpeechStreamEvidence.debugClear);
      SharedPreferences.setMockInitialValues({
        'native_voice_consent::http://hermes-demo.local:9119': 'accepted',
        'native_voice_mode_v1::http://hermes-demo.local:9119': 'server',
      });
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      addTearDown(voice.dispose);
      const schema = <String, dynamic>{
        'fields': {
          'tts.provider': {
            'options': ['openai'],
          },
          'tts.openai.model': {'type': 'string'},
          'tts.openai.voice': {'type': 'string'},
        },
      };
      Map<String, dynamic> config = {
        'tts': {
          'provider': 'openai',
          'openai': {'model': 'tts-A', 'voice': 'alloy'},
        },
      };
      final signatureA = hermesServerTtsConfigurationSignature(
        sanitizeHermesServerVoiceConfig(config, schema),
      );
      HermesSpeechStreamEvidence.notePcmObserved(
        'http://hermes-demo.local:9119',
        ttsConfigurationSignature: signatureA,
      );
      final dashboard = DashboardClient(
        host: 'hermes-demo.local',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          if (request.url.path == '/api/config/schema') {
            return http.Response(jsonEncode(schema), 200);
          }
          if (request.url.path == '/api/config') {
            return http.Response(jsonEncode(config), 200);
          }
          if (request.method == 'POST' &&
              request.url.path.startsWith('/api/audio/')) {
            return http.Response('{}', 400);
          }
          return http.Response('{}', 404);
        }),
      );
      addTearDown(dashboard.close);
      final connection = SavedConnection(
        id: 'demo-node',
        label: 'Server',
        host: 'hermes-demo.local',
        port: 8642,
        apiKey: '',
        dashboardUrl: 'http://hermes-demo.local:9119',
      );

      await tester.pumpWidget(
        host(
          screenKey: const ValueKey('provider-A'),
          voiceService: voice,
          connection: connection,
          preferences: prefs,
          dashboardClientFactory: (_) => dashboard,
        ),
      );
      await tester.pumpAndSettle();
      await revealBlock(tester, 'voice_reading_section');
      final details = find.byKey(const ValueKey('voice_server_details_toggle'));
      await Scrollable.ensureVisible(
        tester.element(details),
        alignment: 0.5,
        duration: Duration.zero,
      );
      await tester.pump();
      await tester.tap(details);
      await tester.pump();
      expect(find.text('Activo · PCM en directo comprobado'), findsOneWidget);

      config = {
        'tts': {
          'provider': 'openai',
          'openai': {'model': 'tts-B', 'voice': 'nova'},
        },
      };
      await tester.pumpWidget(
        host(
          screenKey: const ValueKey('provider-B'),
          voiceService: voice,
          connection: connection,
          preferences: prefs,
          dashboardClientFactory: (_) => dashboard,
        ),
      );
      await tester.pumpAndSettle();
      // The sub-screen that was open left with the screen that owned it.
      expect(find.byKey(const ValueKey('voice_main_list')), findsOneWidget);
      await revealBlock(tester, 'voice_reading_section');
      final updatedDetails = find.byKey(
        const ValueKey('voice_server_details_toggle'),
      );
      await Scrollable.ensureVisible(
        tester.element(updatedDetails),
        alignment: 0.5,
        duration: Duration.zero,
      );
      await tester.pump();
      await tester.tap(updatedDetails);
      await tester.pump();

      expect(find.text('Activo · PCM en directo comprobado'), findsNothing);
      expect(find.text('Pendiente · se comprobará al hablar'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // Auditoría de voz 29/09: elegir «Servidor Hermes» instalaba la voz sobre
  // el cliente del Dashboard de esta pantalla, que se cierra al salir. Desde
  // ese momento «Leer en voz alta» fallaba en silencio hasta reiniciar.
  testWidgets('leer en voz alta sigue funcionando tras salir de Ajustes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // Ajustes consulta modelos locales al montar; sin disco en tests.
    final support = Directory.systemTemp.createTempSync('voice-settings-');
    addTearDown(() => support.deleteSync(recursive: true));
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
      pathProvider,
      (call) async => support.path,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
    final voice = VoiceService(prefs, SecureStorage())
      ..debugNativePlaybackFactory = _InstantPlayback.new;
    addTearDown(voice.dispose);
    var speakRequests = 0;
    final clients = <DashboardClient>[];
    final transports = <_TrackingHttpClient>[];
    final leaseStates = <bool>[];
    DashboardClient makeDashboard(SavedConnection _) {
      final transport = _TrackingHttpClient(
        MockClient((request) async {
          if (request.url.path == '/api/audio/tts-lease') {
            leaseStates.add(jsonDecode(request.body)['active'] as bool);
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          if (request.method == 'GET' && request.url.path == '/api/config') {
            return http.Response(
              jsonEncode({
                'stt': {'provider': 'local'},
                'tts': {'provider': 'edge'},
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/config/schema') {
            return http.Response(jsonEncode({'properties': {}}), 200);
          }
          if (request.method == 'POST' &&
              request.url.path == '/api/audio/speak') {
            if (request.body.trim() == '{}' || request.body.isEmpty) {
              return http.Response('{}', 400);
            }
            speakRequests++;
            return http.Response(
              jsonEncode({
                'ok': true,
                'data_url': 'data:audio/mpeg;base64,AAAA',
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/api/audio/transcribe') {
            return http.Response('{}', 400);
          }
          return http.Response('{}', 404);
        }),
      );
      transports.add(transport);
      final client = DashboardClient(
        host: 'hermes-demo.local',
        manualToken: 'test-token',
        httpClientOverride: transport,
      );
      clients.add(client);
      return client;
    }

    addTearDown(() {
      for (final client in clients) {
        client.close();
      }
    });
    final connection = SavedConnection(
      id: 'demo-node',
      label: 'Server',
      host: 'hermes-demo.local',
      port: 8642,
      apiKey: 'test-key',
      dashboardUrl: 'http://hermes-demo.local:9119',
    );
    final screenKey = GlobalKey();
    await tester.pumpWidget(
      host(
        voiceService: voice,
        connection: connection,
        dashboardClientFactory: makeDashboard,
        preferences: prefs,
        screenKey: screenKey,
      ),
    );
    await tester.pumpAndSettle();
    await openListeningStep(tester);
    await tester.tap(find.byKey(const ValueKey('voice_mode_server_option')));
    await tester.pumpAndSettle();
    expect(voice.nativeVoiceActive, isTrue);

    // Salir de Ajustes desmonta la pantalla y cierra su propio cliente (el
    // primero que creó); la fábrica inyectada no es de su propiedad, así que
    // el test reproduce ese cierre explícitamente.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    clients.first.close();

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
    expect(voice.readAloud.value.phase, isNot(ReadAloudPhase.failed));
    expect(speakRequests, greaterThanOrEqualTo(1));

    // La voz es dueña de su cliente: al desactivarla lo cierra ella.
    expect(transports, hasLength(2));
    expect(transports.last.closed, isFalse);
    voice.disableNativeVoice();
    // El cierre espera al release del lease TTS enviado por ese cliente.
    await tester.runAsync(pumpEventQueue);
    expect(transports.last.closed, isTrue);
    expect(leaseStates, [
      true,
      false,
    ], reason: 'the voice client warms TTS and releases it before closing');
    // Deja vencer el temporizador de descarga de modelos que arma el fin de
    // la lectura; el tearDown libera el servicio.
    await tester.pump(const Duration(minutes: 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('alterna servidor y móvil sin mezclar sus configuraciones', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    final dashboard = DashboardClient(
      host: 'hermes-demo.local',
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/config') {
          return http.Response(
            jsonEncode({
              'stt': {
                'provider': 'local',
                'local': {'model': 'whisper-small'},
              },
              'tts': {
                'provider': 'edge',
                'edge': {'voice': 'es-ES-ElviraNeural'},
              },
            }),
            200,
          );
        }
        if (request.method == 'GET' &&
            request.url.path == '/api/config/schema') {
          return http.Response(jsonEncode({'properties': {}}), 200);
        }
        if (request.method == 'POST' &&
            (request.url.path == '/api/audio/speak' ||
                request.url.path == '/api/audio/transcribe')) {
          return http.Response('{}', 400);
        }
        return http.Response('{}', 404);
      }),
    );
    addTearDown(dashboard.close);
    final connection = SavedConnection(
      id: 'demo-node',
      label: 'Server',
      host: 'hermes-demo.local',
      port: 8642,
      apiKey: '',
      dashboardUrl: 'http://hermes-demo.local:9119',
    );

    await tester.pumpWidget(
      host(
        voiceService: voice,
        connection: connection,
        dashboardClientFactory: (_) => dashboard,
        preferences: prefs,
      ),
    );
    await tester.pumpAndSettle();
    const consentKey = 'native_voice_consent::http://hermes-demo.local:9119';
    const modeKey = 'native_voice_mode_v1::http://hermes-demo.local:9119';
    final serverVoice = find.byKey(const ValueKey('voice_server_summary_card'));
    expect(mainListCopy(tester)[1], 'En este teléfono');

    // Where the voice comes from is chosen in Reply voice.
    await openListeningStep(tester);
    await tapInView(tester, 'voice_mode_server_option');
    expect(prefs.getString(consentKey), 'accepted');
    expect(prefs.getString(modeKey), 'server');

    // Its voice, with the manager and the test, shows under that option;
    // the phone voices fold away.
    expect(serverVoice, findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice_phone_voice_picker')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('voice_field_tts.provider')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('voice_test_server_voice')),
      findsOneWidget,
    );

    await openDictationSection(tester);
    await tapInView(tester, 'voice_dictation_server_option');
    expect(voice.settings.sttEngine, SttEngineKind.hermesServer);
    expect(
      prefs.getString(modeKey),
      'server',
      reason: 'cambiar Dictado no modifica Modo Voz',
    );
    await backToMain(tester);
    expect(mainListCopy(tester)[1], 'Servidor Hermes');

    await revealBlock(tester, 'voice_reading_section');
    await tapInView(tester, 'voice_mode_phone_option');
    expect(prefs.getString(modeKey), 'phone');
    expect(
      prefs.getString(consentKey),
      'accepted',
      reason: 'cambiar de motor no reescribe el consentimiento histórico',
    );
    expect(
      voice.settings.sttEngine,
      SttEngineKind.hermesServer,
      reason: 'cambiar Modo Voz no modifica Dictado',
    );

    await openDictationSection(tester);
    await tapInView(tester, 'voice_dictation_phone_option');
    // Back on the phone with the model it had: nothing was swapped for it.
    expect(voice.settings.sttEngine, SttEngineKind.sherpaLive);
    expect(voice.settings.sherpaModel, SherpaModelKind.whisperBase);
    expect(prefs.getString(modeKey), 'phone');

    await openListeningStep(tester);
    expect(serverVoice, findsNothing);
    await backToMain(tester);
    expect(mainListCopy(tester)[1], 'En este teléfono');
    expect(tester.takeException(), isNull);
  });

  testWidgets('no expone un interruptor redundante para ocultar conversación', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'voice_stt_engine': SttEngineKind.sherpaLive.id,
      'voice_tts_engine': TtsEngineKind.device.id,
      'voice_auto_speak': true,
    });
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);

    await tester.pumpWidget(host(voiceService: voice));
    await tester.pump();
    expect(
      find.byKey(
        const ValueKey('voice_conversation_enabled'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    expect(voice.settings.sttEngine, SttEngineKind.sherpaLive);
    expect(voice.settings.ttsEngine, TtsEngineKind.device);
    expect(voice.settings.autoSpeak, isTrue);
    expect(
      find.byKey(
        const ValueKey('voice_continue_when_locked'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  testWidgets('barge-in es opt-in y cambia sin reiniciar la app', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);

    await tester.pumpWidget(host(voiceService: voice));
    await tester.pump();
    await openConversationSection(tester);

    final toggle = find.byKey(const ValueKey('voice_barge_in_enabled'));
    expect(toggle, findsOneWidget);
    expect(voice.settings.bargeInEnabled, isFalse);

    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(voice.settings.bargeInEnabled, isTrue);
    expect(voice.bargeInEnabled.value, isTrue);
    expect(prefs.getBool('voice_barge_in_enabled_v2'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('la selección legacy del servidor migra a la voz descargada', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'voice_tts_engine': 'hermes_server',
      'voice_onnx_voice_id': 'es_ES-carlfm-x_low',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);

    await tester.pumpWidget(host(voiceService: voice));
    await tester.pump();
    await openListeningStep(tester);
    expect(voice.settings.ttsEngine, TtsEngineKind.onnx);
    expect(prefs.getString('voice_tts_engine'), TtsEngineKind.onnx.id);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('voice_phone_voice')),
        matching: find.text(neuralVoiceById('es_ES-carlfm-x_low')!.displayName),
      ),
      findsOneWidget,
    );
    expect(find.text('Voz de mi servidor Hermes'), findsNothing);
    expect(find.text('Cambiar motor del servidor'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el recorrido no desborda con 320 px y texto al 200%', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await openListeningStep(tester);
    expect(tester.takeException(), isNull);
    final phoneOption = tester.getRect(
      find.byKey(const ValueKey('voice_mode_phone_option')),
    );
    final serverOption = tester.getRect(
      find.byKey(const ValueKey('voice_mode_server_option')),
    );
    // Radio rows, one under the other, with the server first.
    expect(phoneOption.top, greaterThanOrEqualTo(serverOption.bottom));
    expect(phoneOption.left, serverOption.left);

    await openDictationSection(tester);
    expect(tester.takeException(), isNull);
    await openListeningStep(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('voice_setup_test_action')),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'una prueba sin audio sale de Preparando voz y muestra el error',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'voice_tts_engine': TtsEngineKind.onnx.id,
        'voice_onnx_voice_id': 'es_ES-carlfm-x_low',
      });
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final voice = _FastTimeoutVoiceService(prefs);
      addTearDown(voice.dispose);

      await tester.pumpWidget(host(voiceService: voice));
      await tester.pump();
      await openListeningStep(tester);
      final button = find.byKey(const ValueKey('voice_setup_test_action'));
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pump();

      expect(find.text('Preparando voz…'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      expect(find.text('Preparando voz…'), findsNothing);
      expect(
        find.descendant(of: button, matching: find.text('Probar')),
        findsOneWidget,
      );
      expect(
        find.text(
          'No se pudo reproducir: La voz no produjo audio a tiempo. Comprueba '
          'que el modelo esté descargado y vuelve a probar.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a saved voice or dictation service of the user\'s own is moved '
      'without a word when the screen opens', (tester) async {
    SharedPreferences.setMockInitialValues({
      'voice_tts_engine': TtsEngineKind.elevenlabs.id,
      'voice_eleven_voice_id': 'voice-123',
      'voice_stt_engine': SttEngineKind.server.id,
      'voice_server_stt_url': 'ws://192.168.1.40:9123',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // Nothing is downloaded on this phone.
    final support = Directory.systemTemp.createTempSync('voice-removed-');
    addTearDown(() => support.deleteSync(recursive: true));
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
      pathProvider,
      (call) async => support.path,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    await voice.setElevenKey('eleven-secret');

    await tester.pumpWidget(host(voiceService: voice, preferences: prefs));
    // The move looks at what is downloaded: real file reads, whose answers
    // only continue when the test pumps.
    for (
      var attempt = 0;
      attempt < 200 &&
          (voice.settings.ttsEngine != TtsEngineKind.device ||
              voice.settings.sttEngine != SttEngineKind.system);
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(voice.settings.ttsEngine, TtsEngineKind.device);
    expect(voice.settings.sttEngine, SttEngineKind.system);
    expect(prefs.getString('voice_tts_engine'), TtsEngineKind.device.id);
    expect(prefs.getString('voice_stt_engine'), SttEngineKind.system.id);
    // What the user had typed is still stored.
    expect(prefs.getString('voice_eleven_voice_id'), 'voice-123');
    expect(prefs.getString('voice_server_stt_url'), 'ws://192.168.1.40:9123');
    expect(await voice.elevenKey(), 'eleven-secret');
    // The list shows what is in use now and says nothing about the change.
    expect(mainListCopy(tester).sublist(0, 4), [
      'Dictado',
      'Reconocedor de Android',
      'Voz de las respuestas',
      'Voz de Android',
    ]);
    expect(find.byType(HermesStatusText), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reading replies aloud is a switch on the main list', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);

    await tester.pumpWidget(host(voiceService: voice));
    await tester.pump();
    final autoSpeak = find.byKey(const ValueKey('voice_auto_speak'));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('voice_main_list')),
        matching: autoSpeak,
      ),
      findsOneWidget,
    );
    expect(voice.settings.autoSpeak, isFalse);
    await tester.tap(autoSpeak);
    await tester.pumpAndSettle();
    expect(voice.settings.autoSpeak, isTrue);
    expect(prefs.getBool('voice_auto_speak'), isTrue);
    expect(tester.takeException(), isNull);
  });
}
