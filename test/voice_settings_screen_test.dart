import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/voice_settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/hermes_speech_stream.dart';
import 'package:hermes_android/core/services/voice/server_voice_config.dart';
import 'package:hermes_android/core/services/voice/stt_sherpa.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';
import 'package:hermes_android/core/services/voice/tts_model_manager.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host({
    KokoroDiscoveryCallback? kokoroDiscover,
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
      kokoroDiscover: kokoroDiscover,
      voiceService: voiceService,
      connection: connection,
      dashboardClientFactory: dashboardClientFactory,
      preferences: preferences,
      profile: profile,
      serverPreviewEngineFactory: serverPreviewEngineFactory,
    ),
  );

  Future<Finder> scrollToText(WidgetTester tester, String text) async {
    final finder = find.text(text, skipOffstage: false);
    for (
      var attempt = 0;
      attempt < 12 && finder.evaluate().isEmpty;
      attempt++
    ) {
      await tester.drag(find.byType(ListView), const Offset(0, -350));
      await tester.pump();
    }
    expect(finder, findsOneWidget);
    await tester.ensureVisible(finder);
    await tester.pump();
    return finder;
  }

  Future<void> invokeSecondaryButton(WidgetTester tester, Finder finder) async {
    final callback = tester.widget<HermesSecondaryButton>(finder).onTap!;
    final result = Function.apply(callback, const []);
    if (result is Future) await result;
    await tester.pump();
  }

  Future<void> openListeningStep(WidgetTester tester) async {
    final section = find.byKey(const ValueKey('voice_reading_section'));
    for (
      var attempt = 0;
      attempt < 20 && section.evaluate().isEmpty;
      attempt++
    ) {
      await tester.drag(find.byType(ListView), const Offset(0, -350));
      await tester.pump();
    }
    expect(section, findsOneWidget);
    await Scrollable.ensureVisible(
      tester.element(section),
      alignment: 0.05,
      duration: Duration.zero,
    );
    await tester.pump();
    if (find
        .byKey(const ValueKey('voice_setup_test_action'))
        .evaluate()
        .isEmpty) {
      await tester.tap(section);
      await tester.pumpAndSettle();
    }
  }

  Future<void> openDictationSection(WidgetTester tester) async {
    final section = find.byKey(const ValueKey('voice_listening_section'));
    expect(section, findsOneWidget);
    await Scrollable.ensureVisible(
      tester.element(section),
      alignment: 0.05,
      duration: Duration.zero,
    );
    await tester.pump();
    if (find.byKey(const ValueKey('voice_stt_advanced')).evaluate().isEmpty) {
      await tester.tap(section);
      await tester.pumpAndSettle();
    }
  }

  Future<void> openConversationSection(WidgetTester tester) async {
    final section = find.byKey(const ValueKey('voice_conversation_section'));
    expect(section, findsOneWidget);
    await Scrollable.ensureVisible(
      tester.element(section),
      alignment: 0.05,
      duration: Duration.zero,
    );
    await tester.pump();
  }

  Future<void> openSttLocation(WidgetTester tester) async {
    await openDictationSection(tester);
    final advanced = find.byKey(
      const ValueKey('voice_stt_advanced'),
      skipOffstage: false,
    );
    final location = find.byKey(const ValueKey('voice_stt_location'));
    if (location.evaluate().isEmpty) {
      await tester.ensureVisible(advanced);
      await tester.pump();
      await tester.tap(advanced);
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(location);
    await tester.pump();
  }

  Future<void> openAdvancedTts(WidgetTester tester) async {
    final advanced = find.byKey(const ValueKey('voice_reading_advanced'));
    for (
      var attempt = 0;
      attempt < 20 && advanced.evaluate().isEmpty;
      attempt++
    ) {
      await tester.drag(find.byType(ListView), const Offset(0, -350));
      await tester.pump();
    }
    expect(advanced, findsOneWidget);
    await tester.ensureVisible(advanced);
    await tester.pump();
    await tester.tap(advanced);
    await tester.pumpAndSettle();
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

  testWidgets('separa el modo móvil sin mostrar configuración del servidor', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.text('Modo de voz'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice_mode_phone_option')),
      findsOneWidget,
    );
    expect(find.text('Servidor Hermes'), findsNWidgets(2));
    expect(find.text('Aplicado ahora'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice_applied_mode_value')),
      findsOneWidget,
    );
    expect(
      find.text('En este móvil · Whisper base', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Dictado del chat'), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('voice_reading_section'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('voice_server_summary_card')),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey('voice_conversation_enabled'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    expect(find.text('3. Probar'), findsNothing);
    expect(
      find.textContaining('Dictado en directo ·', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Falta descargar el modelo seleccionado'), findsWidgets);
    expect(
      find.textContaining('Voz sin conexión ·', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Dictado rápido'), findsNothing);
    await openDictationSection(tester);
    expect(find.text('Dictado rápido'), findsOneWidget);
    expect(find.text('Transcribir al terminar'), findsOneWidget);
    await openListeningStep(tester);
    expect(find.text('Voz sin conexión'), findsOneWidget);
    expect(find.text('Probar voz'), findsOneWidget);
    expect(find.text('Leer respuestas automáticamente'), findsOneWidget);
    expect(find.text('Dónde se transcribe'), findsNothing);

    await openSttLocation(tester);
    expect(find.text('Dónde se transcribe'), findsOneWidget);
    expect(find.text('Modelo del dictado en directo'), findsOneWidget);
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

  testWidgets('la nueva jerarquía está localizada en inglés', (tester) async {
    await tester.pumpWidget(host(locale: const Locale('en')));
    await tester.pump();

    expect(find.text('Voice mode'), findsNWidgets(2));
    expect(find.text('On this phone'), findsNWidgets(2));
    expect(find.text('Hermes server'), findsNWidgets(2));
    expect(find.text('Chat dictation'), findsNWidgets(2));
    expect(find.text('Chat reading', skipOffstage: false), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice_reading_section'), skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('voice_settings_intro')), findsNothing);
    expect(find.text('Advanced listening settings'), findsNothing);
    await openDictationSection(tester);
    expect(find.text('Advanced listening settings'), findsOneWidget);
    expect(find.text('Where transcription happens'), findsNothing);
    expect(find.text('3. Test'), findsNothing);
    expect(find.textContaining('Three independent controls'), findsNothing);
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

    expect(
      find.byKey(const ValueKey('voice_server_summary_card')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('voice_applied_mode_value')))
          .data,
      'Servidor Hermes',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('voice_applied_routes')),
        matching: find.text('En este móvil · Parakeet v3'),
      ),
      findsOneWidget,
    );
    expect(find.text('Whisper · whisper-small · en'), findsNothing);
    expect(find.text('Edge · Elvira · es-ES'), findsNothing);
    expect(find.text('No disponible · audio por frases'), findsNothing);
    expect(
      find.text('Endpoints y configuración detectados · se valida al hablar'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('voice_server_language_mismatch')),
      findsOneWidget,
    );
    expect(
      find.text('El servidor escucha en Inglés; la app está en Español.'),
      findsWidgets,
    );
    expect(
      find.byKey(const ValueKey('voice_fix_server_language')),
      findsOneWidget,
    );
    final details = find.byKey(const ValueKey('voice_server_details_toggle'));
    expect(details, findsOneWidget);
    await Scrollable.ensureVisible(
      tester.element(details),
      alignment: 0.5,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(details);
    await tester.pump();
    expect(find.text('Whisper · whisper-small · en'), findsOneWidget);
    expect(find.text('Edge · Elvira · es-ES'), findsOneWidget);
    expect(find.text('No disponible · audio por frases'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice_listening_section')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('voice_reading_section')), findsOneWidget);

    await openConversationSection(tester);
    final configure = find.byKey(const ValueKey('voice_manage_server_voice'));
    await Scrollable.ensureVisible(
      tester.element(configure),
      alignment: 0.5,
      duration: Duration.zero,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('voice_server_provider_catalog')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('voice_change_server_edge_voice')),
      findsNothing,
    );
    await tester.tap(configure);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('server-voice-control-surface')),
      findsOneWidget,
    );
    expect(find.text('Lo que te escucha'), findsOneWidget);
    expect(find.text('La voz que oyes'), findsOneWidget);
    Navigator.of(
      tester.element(
        find.byKey(const ValueKey('server-voice-control-surface')),
      ),
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
    expect(find.text('La prueba de voz se reprodujo.'), findsOneWidget);
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

  testWidgets('solo lectura permite inspeccionar el gestor sin mutar', (
    tester,
  ) async {
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
        if (request.url.path == '/api/config/schema') {
          return http.Response(
            jsonEncode({
              'fields': {
                'tts.provider': {
                  'options': ['edge'],
                },
              },
            }),
            200,
          );
        }
        if (request.url.path == '/api/config') {
          return http.Response(
            jsonEncode({
              'tts': {
                'provider': 'edge',
                'edge': {'voice': 'es-ES-ElviraNeural'},
              },
            }),
            200,
          );
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
      readOnly: true,
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
    final manage = find.byKey(const ValueKey('voice_manage_server_voice'));
    await tester.ensureVisible(manage);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(manage).onPressed, isNotNull);
    await tester.tap(manage);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('server-voice-manager')), findsOneWidget);
    expect(
      find.textContaining(
        RegExp('solo lectura', caseSensitive: false),
        findRichText: true,
      ),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
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

    expect(
      find.textContaining('El Dashboard requiere iniciar sesión'),
      findsOneWidget,
    );
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

    final update = find.byKey(const ValueKey('voice_server_update_action'));
    expect(update, findsOneWidget);
    expect(find.text('Cómo activar voz en Hermes'), findsOneWidget);
    tester.widget<OutlinedButton>(update).onPressed!();
    await tester.pump();

    expect(
      find.textContaining('Los endpoints de voz forman parte'),
      findsOneWidget,
    );
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
    expect(
      find.byKey(const ValueKey('voice_listening_section')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('voice_reading_section')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice_server_summary_card')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('voice_mode_server_option')));
    await tester.pumpAndSettle();
    expect(
      prefs.getString('native_voice_consent::http://hermes-demo.local:9119'),
      'accepted',
    );
    expect(
      prefs.getString('native_voice_mode_v1::http://hermes-demo.local:9119'),
      'server',
    );
    expect(
      find.byKey(const ValueKey('voice_server_summary_card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('voice_listening_section')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('voice_reading_section')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice_manage_server_voice')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('voice_test_server_voice')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('voice_server_catalog_help')),
      findsNothing,
    );

    final hermesDictation = find.byKey(
      const ValueKey('voice_dictation_server_option'),
    );
    await Scrollable.ensureVisible(
      tester.element(hermesDictation),
      alignment: 0.3,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(hermesDictation);
    await tester.pumpAndSettle();
    expect(voice.settings.sttEngine, SttEngineKind.hermesServer);
    expect(
      prefs.getString('native_voice_mode_v1::http://hermes-demo.local:9119'),
      'server',
      reason: 'cambiar Dictado no modifica Modo Voz',
    );

    final phoneMode = find.byKey(const ValueKey('voice_mode_phone_option'));
    await Scrollable.ensureVisible(
      tester.element(phoneMode),
      alignment: 0.35,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(phoneMode);
    await tester.pumpAndSettle();
    expect(
      prefs.getString('native_voice_mode_v1::http://hermes-demo.local:9119'),
      'phone',
    );
    expect(
      prefs.getString('native_voice_consent::http://hermes-demo.local:9119'),
      'accepted',
      reason: 'cambiar de motor no reescribe el consentimiento histórico',
    );
    expect(
      voice.settings.sttEngine,
      SttEngineKind.hermesServer,
      reason: 'cambiar Modo Voz no modifica Dictado',
    );

    final localDictation = find.byKey(
      const ValueKey('voice_dictation_phone_option'),
    );
    await Scrollable.ensureVisible(
      tester.element(localDictation),
      alignment: 0.3,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(localDictation);
    await tester.pumpAndSettle();
    expect(voice.settings.sttEngine, SttEngineKind.sherpaLive);
    expect(voice.settings.sherpaModel, SherpaModelKind.parakeetV3);
    expect(
      prefs.getString('native_voice_mode_v1::http://hermes-demo.local:9119'),
      'phone',
    );
    expect(
      find.byKey(const ValueKey('voice_server_summary_card')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('voice_listening_section')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('voice_reading_section')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expone dos opciones inequívocas y persiste reiniciar', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);

    await tester.pumpWidget(host(voiceService: voice));
    await tester.pump();
    await openListeningStep(tester);
    await openAdvancedTts(tester);

    final restart = await scrollToText(tester, 'Detener y reiniciar');
    expect(
      find.text('Pausar y continuar', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      voice.settings.readAloudStopBehavior,
      ReadAloudStopBehavior.pauseAndResume,
    );

    await tester.tap(restart);
    await tester.pumpAndSettle();

    expect(
      voice.settings.readAloudStopBehavior,
      ReadAloudStopBehavior.stopAndRestart,
    );
    expect(
      prefs.getString('voice_read_aloud_stop_behavior'),
      'stop_and_restart',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('no expone un interruptor redundante para ocultar conversación', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'voice_stt_engine': SttEngineKind.server.id,
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
    expect(voice.settings.sttEngine, SttEngineKind.server);
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

  testWidgets('la ruta aplicada no se recorta en ancho Pixel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(411, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(host());
    await tester.pump();

    final appliedRoutes = find.byKey(const ValueKey('voice_applied_routes'));
    final dictationLabel = find.descendant(
      of: appliedRoutes,
      matching: find.text('Dictado del chat'),
    );
    final dictationValue = find.byKey(
      const ValueKey('voice_applied_dictation_value'),
    );

    expect(dictationLabel, findsOneWidget);
    expect(dictationValue, findsOneWidget);
    expect(
      tester.widget<Text>(dictationValue).data,
      'En este móvil · Whisper base',
    );
    expect(
      tester.getTopLeft(dictationValue).dy,
      greaterThan(tester.getBottomLeft(dictationLabel).dy),
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

  testWidgets(
    'separa cuándo transcribe de dónde y oculta la ubicación al terminar',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'voice_stt_engine': SttEngineKind.server.id,
        'voice_server_stt_url': 'ws://192.168.1.40:9123',
      });
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      addTearDown(voice.dispose);

      await tester.pumpWidget(host(voiceService: voice));
      await tester.pump();

      await openDictationSection(tester);
      expect(find.text('Dictado rápido'), findsOneWidget);
      expect(find.text('Transcribir al terminar'), findsOneWidget);
      expect(find.text('Dónde se transcribe'), findsNothing);
      expect(
        find.text('Activo: Mi servidor STT · toca para configurar'),
        findsOneWidget,
      );
      await openSttLocation(tester);
      expect(find.text('Dónde se transcribe'), findsOneWidget);

      final afterSpeaking = find.text('Transcribir al terminar');
      await tester.ensureVisible(afterSpeaking);
      await tester.pump();
      await tester.tap(afterSpeaking);
      await tester.pumpAndSettle();
      expect(voice.settings.sttEngine, SttEngineKind.whisper);
      expect(find.text('Dónde se transcribe'), findsNothing);
      expect(find.text('Modelo para transcribir al terminar'), findsOneWidget);
      expect(find.text('Mi servidor STT'), findsNothing);
      expect(find.text('Reconocedor de Android'), findsNothing);

      final live = find.text('Dictado rápido');
      await tester.ensureVisible(live);
      await tester.pump();
      await tester.tap(live);
      await tester.pumpAndSettle();
      expect(voice.settings.sttEngine, SttEngineKind.server);
      expect(find.text('Dónde se transcribe'), findsOneWidget);
      expect(
        find.text('Activo: Mi servidor STT · toca para configurar'),
        findsOneWidget,
      );

      await openSttLocation(tester);
      expect(find.text('En este móvil'), findsNWidgets(3));
      expect(find.text('Mi servidor STT'), findsNWidgets(2));
      expect(find.text('Reconocedor de Android'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(find.text('Voz sin conexión'), findsOneWidget);
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
    expect(tester.takeException(), isNull);
    final phoneOption = tester.getRect(
      find.byKey(const ValueKey('voice_mode_phone_option')),
    );
    final serverOption = tester.getRect(
      find.byKey(const ValueKey('voice_mode_server_option')),
    );
    expect(serverOption.top, greaterThanOrEqualTo(phoneOption.bottom));

    await openListeningStep(tester);
    expect(tester.takeException(), isNull);
    await scrollToText(tester, 'Probar voz');
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
      final button = await scrollToText(tester, 'Probar voz');
      await tester.tap(button);
      await tester.pump();

      expect(find.text('Preparando voz…'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      expect(find.text('Preparando voz…'), findsNothing);
      expect(find.text('Probar voz'), findsOneWidget);
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

  testWidgets(
    'el recorrido normal es simple y las integraciones son opcionales',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pump();

      expect(find.text('Guía paso a paso'), findsNothing);

      for (final label in const ['Dictado rápido', 'Transcribir al terminar']) {
        expect(find.text(label, skipOffstage: false), findsOneWidget);
      }
      expect(find.text('Opciones avanzadas'), findsNothing);
      expect(find.text('Dónde se transcribe'), findsNothing);
      expect(find.text('Mi servidor STT'), findsNothing);
      expect(find.text('Reconocedor de Android'), findsNothing);
      await openSttLocation(tester);
      expect(find.text('En este móvil'), findsNWidgets(3));
      expect(find.text('Mi servidor STT'), findsOneWidget);
      expect(find.text('Reconocedor de Android'), findsOneWidget);

      await openListeningStep(tester);
      for (final label in const ['Voz de Android', 'Voz sin conexión']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Voz de mi servidor Hermes'), findsNothing);
      expect(find.text('Cambiar motor del servidor'), findsNothing);
      expect(find.text('Servicios externos (avanzado)'), findsNothing);
      for (final label in const [
        'Kokoro local · configuración guiada',
        'Otra API compatible con OpenAI',
        'ElevenLabs',
        'API TTS personalizada',
      ]) {
        expect(find.text(label), findsNothing);
      }

      await openAdvancedTts(tester);
      for (final label in const [
        'Kokoro local · configuración guiada',
        'Otra API compatible con OpenAI',
        'ElevenLabs',
        'API TTS personalizada',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'la lista de lectura completa también está localizada en inglés',
    (tester) async {
      await tester.pumpWidget(host(locale: const Locale('en')));
      await tester.pump();
      await openListeningStep(tester);

      for (final label in const ['Android voice', 'Offline voice']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Voice from my Hermes server'), findsNothing);
      expect(find.text('Change server engine'), findsNothing);
      expect(find.text('External services (advanced)'), findsNothing);

      await openAdvancedTts(tester);
      for (final label in const [
        'Local Kokoro · guided setup',
        'Another OpenAI-compatible API',
        'ElevenLabs',
        'Custom TTS API',
      ]) {
        expect(find.text(label, skipOffstage: false), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'abrir ajustes conserva device y cada opción selecciona su propio motor',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'voice_tts_engine': TtsEngineKind.device.id,
      });
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      addTearDown(voice.dispose);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: VoiceSettingsScreen(voiceService: voice),
        ),
      );
      await tester.pump();
      await openListeningStep(tester);

      expect(voice.settings.ttsEngine, TtsEngineKind.device);
      expect(prefs.getString('voice_tts_engine'), TtsEngineKind.device.id);

      await tester.tap(await scrollToText(tester, 'Voz sin conexión'));
      await tester.pumpAndSettle();
      expect(voice.settings.ttsEngine, TtsEngineKind.onnx);
      expect(prefs.getString('voice_tts_engine'), TtsEngineKind.onnx.id);

      await tester.tap(await scrollToText(tester, 'Voz de Android'));
      await tester.pumpAndSettle();
      expect(voice.settings.ttsEngine, TtsEngineKind.device);
      expect(prefs.getString('voice_tts_engine'), TtsEngineKind.device.id);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'la API personalizada muestra el editor guiado al seleccionarla',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pump();
      await openListeningStep(tester);
      await openAdvancedTts(tester);

      final custom = await scrollToText(tester, 'API TTS personalizada');
      await tester.tap(custom);
      await tester.pump();

      expect(find.text('URL donde se genera la voz'), findsOneWidget);
      expect(find.text('¿Tu servicio pide una clave?'), findsOneWidget);
      expect(find.text('Mi proveedor usa un formato especial'), findsOneWidget);
      expect(
        find.text('Plantilla de petición (solo según documentación)'),
        findsNothing,
      );
      expect(find.text('Devuelve un archivo de audio'), findsNothing);
      expect(find.text('Devuelve datos JSON'), findsNothing);

      await tester.tap(
        await scrollToText(tester, 'Mi proveedor usa un formato especial'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Plantilla de petición (solo según documentación)'),
        findsOneWidget,
      );
      expect(
        find.text(
          'La respuesta se detecta automáticamente: audio directo o los '
          'formatos habituales del proveedor.',
        ),
        findsOneWidget,
      );
      expect(find.text('Devuelve un archivo de audio'), findsNothing);
      expect(find.text('Devuelve datos JSON'), findsNothing);
      expect(find.text('URL DONDE SE GENERA LA VOZ'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Kokoro y OpenAI muestran recorridos distintos', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    await openListeningStep(tester);
    await openAdvancedTts(tester);

    final kokoro = await scrollToText(
      tester,
      'Kokoro local · configuración guiada',
    );
    await tester.tap(kokoro);
    await tester.pump();

    expect(find.text('Dirección del servidor'), findsOneWidget);
    expect(find.text('Puerto'), findsOneWidget);
    expect(find.text('Token (opcional; normalmente vacío)'), findsOneWidget);
    expect(find.text('Detectar y configurar Kokoro'), findsOneWidget);
    expect(find.text('modelo'), findsNothing);
    expect(find.text('URL base (/v1)'), findsNothing);

    final openAi = await scrollToText(tester, 'Otra API compatible con OpenAI');
    await tester.tap(openAi);
    await tester.pump();

    expect(find.text('URL base (/v1)'), findsOneWidget);
    expect(find.text('Voz'), findsWidgets);
    expect(find.text('modelo'), findsOneWidget);
    expect(find.text('Token API (opcional)'), findsOneWidget);
    expect(find.text('Dirección del servidor'), findsNothing);
    expect(find.text('Detectar y configurar Kokoro'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Kokoro -> OpenAI -> Kokoro mantiene valores independientes', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        kokoroDiscover:
            ({
              required String address,
              required String port,
              required String apiKey,
            }) async => const KokoroTtsDiscovery(
              baseUrl: 'http://192.168.1.20:8880/v1',
              voices: ['ef_dora'],
            ),
      ),
    );
    await tester.pump();
    await openListeningStep(tester);
    await openAdvancedTts(tester);

    final kokoro = await scrollToText(
      tester,
      'Kokoro local · configuración guiada',
    );
    await tester.tap(kokoro);
    await tester.pump();
    final detect = await scrollToText(tester, 'Detectar y configurar Kokoro');
    await tester.tap(detect);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stream_tts_url')))
          .controller
          ?.text,
      'http://192.168.1.20:8880/v1',
    );
    expect(find.text('ef_dora'), findsWidgets);
    // El aviso de Kokoro flota arriba y puede quedar sobre el destino del
    // siguiente toque: se retira antes (un toque o deslizar en el dispositivo).
    HermesNotice.of(
      tester.element(find.byType(Scaffold).last),
    ).clearSnackBars();
    await tester.pumpAndSettle();

    final openAi = await scrollToText(tester, 'Otra API compatible con OpenAI');
    await tester.tap(openAi);
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stream_tts_url')))
          .controller
          ?.text,
      isEmpty,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stream_tts_voice')))
          .controller
          ?.text,
      'alloy',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stream_tts_model')))
          .controller
          ?.text,
      'tts-1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('stream_tts_url')),
      'https://voice.example.com/v1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('stream_tts_voice')),
      'nova',
    );
    await tester.enterText(
      find.byKey(const ValueKey('stream_tts_model')),
      'gpt-4o-mini-tts',
    );
    final save = find.byKey(const ValueKey('stream_tts_save'));
    await tester.ensureVisible(save);
    await tester.pump();
    await invokeSecondaryButton(tester, save);

    await tester.tap(
      await scrollToText(tester, 'Kokoro local · configuración guiada'),
    );
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stream_tts_url')))
          .controller
          ?.text,
      'http://192.168.1.20:8880/v1',
    );
    expect(find.text('ef_dora'), findsWidgets);

    await tester.tap(
      await scrollToText(tester, 'Otra API compatible con OpenAI'),
    );
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stream_tts_url')))
          .controller
          ?.text,
      'https://voice.example.com/v1',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stream_tts_voice')))
          .controller
          ?.text,
      'nova',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stream_tts_model')))
          .controller
          ?.text,
      'gpt-4o-mini-tts',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('OpenAI no guarda una URL vacía o inválida', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    await openListeningStep(tester);
    await openAdvancedTts(tester);
    await tester.tap(
      await scrollToText(tester, 'Otra API compatible con OpenAI'),
    );
    await tester.pump();

    await scrollToText(tester, 'Guardar configuración');
    final save = find.byKey(const ValueKey('stream_tts_save'));
    await tester.ensureVisible(save);
    await tester.pump();
    await invokeSecondaryButton(tester, save);
    expect(
      find.text('Configura la URL del servidor de voz primero'),
      findsOneWidget,
    );
    expect(find.text('Voz por streaming guardada'), findsNothing);
    HermesNotice.of(
      tester.element(find.byType(Scaffold).last),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('stream_tts_url')),
      'esto no es una URL',
    );
    await tester.ensureVisible(save);
    await tester.pump();
    await invokeSecondaryButton(tester, save);
    expect(
      find.text(
        'Introduce una URL HTTP o HTTPS válida para el servidor de voz',
      ),
      findsOneWidget,
    );
    expect(find.text('Voz por streaming guardada'), findsNothing);
    HermesNotice.of(
      tester.element(find.byType(Scaffold).last),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('stream_tts_url')),
      'http://api.openai.com/v1',
    );
    await tester.ensureVisible(save);
    await tester.pump();
    await invokeSecondaryButton(tester, save);
    expect(
      find.text(
        'Para un servidor público usa HTTPS. HTTP solo se permite en tu red '
        'local o Tailscale.',
      ),
      findsOneWidget,
    );
    expect(find.text('Voz por streaming guardada'), findsNothing);
    HermesNotice.of(
      tester.element(find.byType(Scaffold).last),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('stream_tts_url')),
      'https://voice.example.com/v1',
    );
    await tester.enterText(find.byKey(const ValueKey('stream_tts_voice')), '');
    await tester.enterText(find.byKey(const ValueKey('stream_tts_model')), '');
    await tester.ensureVisible(save);
    await tester.pump();
    await invokeSecondaryButton(tester, save);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stream_tts_voice')))
          .controller
          ?.text,
      'alloy',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stream_tts_model')))
          .controller
          ?.text,
      'tts-1',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('salir durante detección Kokoro no usa controllers liberados', (
    tester,
  ) async {
    final discovery = Completer<KokoroTtsDiscovery>();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => VoiceSettingsScreen(
                    kokoroDiscover:
                        ({
                          required String address,
                          required String port,
                          required String apiKey,
                        }) => discovery.future,
                  ),
                ),
              ),
              child: const Text('Abrir voz'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir voz'));
    await tester.pumpAndSettle();
    await openListeningStep(tester);
    await openAdvancedTts(tester);
    final kokoro = await scrollToText(
      tester,
      'Kokoro local · configuración guiada',
    );
    await tester.tap(kokoro);
    await tester.pump();
    final detect = await scrollToText(tester, 'Detectar y configurar Kokoro');
    await tester.tap(detect);
    await tester.pump();

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    discovery.complete(
      const KokoroTtsDiscovery(
        baseUrl: 'http://192.168.1.20:8880/v1',
        voices: ['ef_dora'],
      ),
    );
    await tester.pump();

    expect(find.text('Abrir voz'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no guarda una plantilla REST inválida ni anuncia éxito', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump();
    await openListeningStep(tester);
    await openAdvancedTts(tester);
    final custom = await scrollToText(tester, 'API TTS personalizada');
    await tester.tap(custom);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('custom_tts_url')),
      'https://tts.example.com/speech',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(
      await scrollToText(tester, 'Mi proveedor usa un formato especial'),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('custom_tts_body')),
      '{json inválido',
    );
    final save = await scrollToText(tester, 'Guardar configuración');
    // Deja el botón dentro del viewport: el formulario avanzado es largo y
    // ensureVisible puede alinearlo justo por debajo del borde inferior.
    // Se arrastra hasta que el botón es realmente pulsable, en vez de fiarse
    // de un desplazamiento fijo (que se rompe al añadir cualquier fila).
    for (var attempt = 0; attempt < 15; attempt++) {
      final box = tester.getRect(save);
      final viewport = tester.getRect(find.byType(ListView).first);
      if (box.bottom <= viewport.bottom - 8 && box.top >= viewport.top + 8) {
        break;
      }
      // Arrastra hacia el lado que corresponda: si el botón quedó por debajo
      // del viewport hay que subir el contenido, y si quedó por encima, bajarlo.
      final dy = box.bottom > viewport.bottom - 8 ? -80.0 : 80.0;
      await tester.drag(find.byType(ListView), Offset(0, dy));
      await tester.pump();
    }
    await tester.tap(save);
    await tester.pump();

    expect(
      find.text(
        'Revisa la URL y el formato avanzado antes de guardar. La petición '
        'debe ser JSON válido y el nombre de cabecera debe ser correcto.',
      ),
      findsOneWidget,
    );
    expect(find.text('Configuración TTS personalizada guardada'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
