import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/voice_settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _toggleKey = ValueKey('voice_gpt_live_enabled');

SavedConnection _connection() => SavedConnection(
  id: 'gpt-live-node',
  label: 'Server',
  host: 'hermes-demo.local',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://hermes-demo.local:9119',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Uri> statusRequests;

  Future<VoiceService> pump(
    WidgetTester tester, {
    required http.Response Function(http.Request) status,
    bool enabled = false,
    Locale locale = const Locale('es'),
  }) async {
    SharedPreferences.setMockInitialValues({
      if (enabled) 'voice_gpt_live_enabled_v1': true,
    });
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    statusRequests = [];
    final dashboard = DashboardClient(
      host: 'hermes-demo.local',
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        if (request.url.path == '/api/audio/voice-live/status') {
          statusRequests.add(request.url);
          return status(request);
        }
        return http.Response('{}', 404);
      }),
    );
    addTearDown(dashboard.close);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: VoiceSettingsScreen(
          voiceService: voice,
          connection: _connection(),
          preferences: prefs,
          dashboardClientFactory: (_) => dashboard,
          profile: 'ops',
        ),
      ),
    );
    await tester.pumpAndSettle();
    return voice;
  }

  http.Response ok({bool available = true, String? reason}) => http.Response(
    '{"ok":true,"mode":"chained","available":$available,'
    '"reason":${reason == null ? 'null' : '"$reason"'}}',
    200,
  );

  Future<void> reveal(WidgetTester tester) async {
    final toggle = find.byKey(_toggleKey, skipOffstage: false);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
  }

  testWidgets('shows an off toggle when the server supports GPT-Live', (
    tester,
  ) async {
    final voice = await pump(tester, status: (_) => ok());
    expect(find.byKey(_toggleKey), findsOneWidget);
    await reveal(tester);
    expect(find.text('Voz GPT-Live (experimental)'), findsOneWidget);
    expect(voice.settings.gptLiveEnabled, isFalse);
    // Off: the description, never the status.
    expect(find.text('Disponible en este servidor'), findsNothing);
    expect(
      find.text(
        'Conversación bidireccional con el modelo de voz. '
        'La voz por turnos sigue de respaldo.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('toggling on persists and shows the availability', (
    tester,
  ) async {
    final voice = await pump(tester, status: (_) => ok());
    await reveal(tester);
    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();
    expect(voice.settings.gptLiveEnabled, isTrue);
    expect(find.text('Disponible en este servidor'), findsOneWidget);
  });

  testWidgets('on + unavailable shows the server reason', (tester) async {
    await pump(
      tester,
      enabled: true,
      status: (_) => ok(available: false, reason: 'no OpenAI API key'),
    );
    await reveal(tester);
    expect(find.text('No disponible: no OpenAI API key'), findsOneWidget);
  });

  testWidgets('hidden when the server has no GPT-Live route (404)', (
    tester,
  ) async {
    await pump(tester, status: (_) => http.Response('not found', 404));
    expect(find.byKey(_toggleKey, skipOffstage: false), findsNothing);
  });

  testWidgets('hidden when the status read fails with a network error', (
    tester,
  ) async {
    await pump(tester, status: (_) => throw const SocketException('offline'));
    expect(tester.takeException(), isNull);
    expect(find.byKey(_toggleKey, skipOffstage: false), findsNothing);
  });

  testWidgets('hidden when the route answers 405', (tester) async {
    await pump(tester, status: (_) => http.Response('no', 405));
    expect(find.byKey(_toggleKey, skipOffstage: false), findsNothing);
  });

  testWidgets('already on but unsupported keeps the toggle to switch off', (
    tester,
  ) async {
    await pump(
      tester,
      enabled: true,
      status: (_) => http.Response('not found', 404),
    );
    await reveal(tester);
    expect(find.byKey(_toggleKey), findsOneWidget);
    expect(find.text('No disponible en este servidor'), findsOneWidget);
  });

  testWidgets('one status fetch on open, none while toggling', (tester) async {
    await pump(tester, status: (_) => ok());
    await reveal(tester);
    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();
    expect(statusRequests, hasLength(1));
    expect(statusRequests.single.queryParameters['profile'], 'ops');
  });

  testWidgets('English copy', (tester) async {
    await pump(tester, status: (_) => ok(), locale: const Locale('en'));
    await reveal(tester);
    expect(find.text('GPT-Live voice (experimental)'), findsOneWidget);
  });
}
