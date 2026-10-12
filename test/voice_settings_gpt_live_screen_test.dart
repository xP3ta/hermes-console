import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'support/design_shots.dart' show loadDesignFonts;
import 'package:hermes_android/core/services/voice/voice_settings.dart';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/voice_settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/live/voice_chat_mode_store.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_protocol.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _toggleKey = ValueKey('voice_gpt_live_enabled');
const _chainedKey = ValueKey('voice_conversation_chained');
const _modeRowKey = ValueKey('voice_advanced_chat_mode');
const _reasonKey = ValueKey('voice_live_reason');
const _addKeyKey = ValueKey('voice_live_add_key');

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  readOnly: readOnly,
  id: 'gpt-live-node',
  label: 'Server',
  host: 'hermes-demo.local',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://hermes-demo.local:9119',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadDesignFonts();
    final fallback = FontLoader('Ahem')
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await fallback.load();
  });

  late List<Uri> statusRequests;
  late List<http.Request> configWrites;

  /// Writes of a provider key (`PUT /api/env`), and whether the fake server
  /// has one now.
  late List<http.Request> envWrites;
  late bool keyStored;
  late bool envWriteFails;

  /// What the profile's `voice.voice_chat_mode` is on the fake server.
  late String serverMode;
  late bool writeFails;

  Future<VoiceService> pump(
    WidgetTester tester, {
    required FutureOr<http.Response> Function(http.Request) status,
    String mode = 'chained',
    bool readOnly = false,
    bool serverRoute = false,
    Locale locale = const Locale('es'),
    Map<String, Object> initial = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      ...initial,
      if (serverRoute)
        'native_voice_consent::http://hermes-demo.local:9119::profile=ops':
            'accepted',
      if (serverRoute)
        'native_voice_mode_v1::http://hermes-demo.local:9119::profile=ops':
            'server',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    statusRequests = [];
    configWrites = [];
    serverMode = mode;
    writeFails = false;
    envWrites = [];
    keyStored = false;
    envWriteFails = false;
    final dashboard = DashboardClient(
      host: 'hermes-demo.local',
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        if (request.url.path == '/api/audio/voice-live/status') {
          expect(request.method, 'GET');
          statusRequests.add(request.url);
          return status(request);
        }
        if (request.method == 'PUT' && request.url.path == '/api/config') {
          configWrites.add(request);
          if (writeFails) return http.Response('{}', 500);
          final config = (jsonDecode(request.body) as Map)['config'] as Map;
          serverMode = (config['voice'] as Map)['voice_chat_mode'] as String;
          return http.Response('{"ok":true}', 200);
        }
        if (request.method == 'PUT' && request.url.path == '/api/env') {
          envWrites.add(request);
          if (envWriteFails) return http.Response('{}', 500);
          keyStored = true;
          return http.Response('{"ok":true}', 200);
        }
        expect(
          request.method,
          'GET',
          reason: 'settings never opens paid audio or other provider state',
        );
        return http.Response('{}', 404);
      }),
    );
    addTearDown(dashboard.close);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('voice-review-render'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: locale,
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark').copyWith(
            listTileTheme: AppTheme.fromId('dark').listTileTheme.copyWith(
              titleTextStyle: AppTheme.fromId(
                'dark',
              ).listTileTheme.titleTextStyle?.copyWith(fontFamily: 'Inter'),
              subtitleTextStyle: AppTheme.fromId(
                'dark',
              ).listTileTheme.subtitleTextStyle?.copyWith(fontFamily: 'Inter'),
            ),
          ),
          home: VoiceSettingsScreen(
            voiceService: voice,
            connection: _connection(readOnly: readOnly),
            preferences: prefs,
            dashboardClientFactory: (_) => dashboard,
            profile: 'ops',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return voice;
  }

  /// The status the fake server answers for its current mode.
  http.Response ok({bool available = true, String? reason}) => http.Response(
    '{"ok":true,"mode":"$serverMode","available":$available,'
    '"reason":${reason == null ? 'null' : '"$reason"'}}',
    200,
  );

  VoiceChatMode? remembered(SharedPreferences prefs) => VoiceChatModeStore(
    prefs,
  ).read(VoiceChatModeStore.identity('gpt-live-node', 'ops'));

  Future<void> reveal(WidgetTester tester) async {
    final toggle = find.byKey(_toggleKey, skipOffstage: false);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
  }

  Future<void> openAdvanced(WidgetTester tester) async {
    final row = find.byKey(const ValueKey('voice_main_advanced'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice_page_advanced')), findsOneWidget);
  }

  Future<void> backToMain(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice_main_list')), findsOneWidget);
  }

  // Whether the option is the selected one: both the segment of the main
  // screen and the radio row of Advanced expose it to accessibility.
  bool selected(WidgetTester tester, Key key) {
    final option = find.byKey(key);
    final semantics = tester.widget(option) is InkWell
        ? find.ancestor(of: option, matching: find.byType(Semantics))
        : find.descendant(of: option, matching: find.byType(Semantics));
    return tester.widget<Semantics>(semantics.first).properties.selected!;
  }

  // Whether the segment can be tapped: a GPT-Live that cannot start is
  // shown, as in Desktop, but not selectable.
  bool tappable(WidgetTester tester, Key key) =>
      tester
          .widget<InkWell>(
            find.descendant(
              of: find.byKey(key),
              matching: find.byType(InkWell),
            ),
          )
          .onTap !=
      null;

  // The reason Hermes really sends when the OpenAI key is missing.
  const noKeyReason =
      'no OpenAI API key (set OPENAI_API_KEY or voice.gpt_live.api_key)';

  // The status the fake server answers while it has no OpenAI key, and once
  // it has one.
  http.Response keyed() =>
      keyStored ? ok() : ok(available: false, reason: noKeyReason);
  const saveFailed =
      'No se pudo cambiar la conversación de voz en el servidor.';

  testWidgets('shows the server mode when GPT-Live is available', (
    tester,
  ) async {
    await pump(tester, status: (_) => ok());
    await reveal(tester);
    expect(find.text('Conversación de voz'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('GPT-Live'), findsOneWidget);
    expect(selected(tester, _chainedKey), isTrue);
    expect(selected(tester, _toggleKey), isFalse);
    // Plain words only on the main screen, and no status while it works.
    for (final jargon in const ['full-duplex', 'encadenada', 'Motor']) {
      expect(find.textContaining(jargon), findsNothing, reason: jargon);
    }
    expect(find.text('Disponible en este servidor'), findsNothing);
    // What the screen read is what the next conversation starts from.
    final prefs = await SharedPreferences.getInstance();
    expect(
      remembered(prefs),
      const VoiceChatMode(mode: VoiceLiveMode.chained, available: true),
    );
  });

  testWidgets('a profile set to gpt-live on the server shows GPT-Live, '
      'whatever an old local preference said', (tester) async {
    await pump(
      tester,
      mode: 'gpt-live',
      status: (_) => ok(),
      initial: {'voice_gpt_live_enabled_v1': false},
    );
    await reveal(tester);
    expect(selected(tester, _toggleKey), isTrue);
    expect(selected(tester, _chainedKey), isFalse);
    // The lock-screen switch is offered in every mode.
    expect(
      find.byKey(const ValueKey('voice_continue_when_locked')),
      findsOneWidget,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(remembered(prefs)!.startsLive, isTrue);
    expect(configWrites, isEmpty);
  });

  testWidgets('an old local opt-in does not select GPT-Live', (tester) async {
    await pump(
      tester,
      status: (_) => ok(),
      initial: {'voice_gpt_live_enabled_v1': true},
    );
    await reveal(tester);
    expect(selected(tester, _chainedKey), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(remembered(prefs)!.startsLive, isFalse);
  });

  testWidgets('changing the choice writes the profile config key and '
      're-reads the status', (tester) async {
    await pump(tester, status: (_) => ok());
    await reveal(tester);
    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();

    expect(configWrites, hasLength(1));
    final write = configWrites.single;
    expect(write.url.queryParameters, {'profile': 'ops'});
    expect(jsonDecode(write.body), {
      'config': {
        'voice': {'voice_chat_mode': 'gpt-live'},
      },
    });
    expect(statusRequests, hasLength(2));
    expect(
      statusRequests.every((url) => url.queryParameters['profile'] == 'ops'),
      isTrue,
    );
    expect(selected(tester, _toggleKey), isTrue);
    expect(
      find.byKey(const ValueKey('voice_continue_when_locked')),
      findsOneWidget,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(remembered(prefs)!.startsLive, isTrue);
    // No app-local switch is kept any more.
    expect(prefs.getKeys().where((key) => key.contains('gpt_live')), isEmpty);

    await tester.tap(find.byKey(_chainedKey));
    await tester.pumpAndSettle();
    expect(configWrites, hasLength(2));
    expect(jsonDecode(configWrites.last.body), {
      'config': {
        'voice': {'voice_chat_mode': 'chained'},
      },
    });
    expect(selected(tester, _chainedKey), isTrue);
    expect(remembered(prefs)!.startsLive, isFalse);
    expect(
      find.byKey(const ValueKey('voice_continue_when_locked')),
      findsOneWidget,
    );
    expect(find.text(saveFailed), findsNothing);
  });

  testWidgets('a read-only connection sees the choice but cannot write it', (
    tester,
  ) async {
    await pump(tester, readOnly: true, status: (_) => ok());
    await reveal(tester);
    expect(find.text('Conversación de voz'), findsOneWidget);
    expect(selected(tester, _chainedKey), isTrue);
    await tester.tap(find.byKey(_toggleKey), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(configWrites, isEmpty);
    expect(selected(tester, _chainedKey), isTrue);
    expect(statusRequests, hasLength(1));

    // The choice is on the main list, so Advanced does not repeat it.
    await openAdvanced(tester);
    expect(find.byKey(_modeRowKey), findsNothing);
    expect(configWrites, isEmpty);
  });

  testWidgets('a failed write restores the selection and says so once', (
    tester,
  ) async {
    await pump(tester, status: (_) => ok());
    writeFails = true;
    await reveal(tester);
    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();

    expect(configWrites, hasLength(1));
    expect(selected(tester, _chainedKey), isTrue);
    expect(selected(tester, _toggleKey), isFalse);
    expect(find.text(saveFailed), findsOneWidget);
    expect(statusRequests, hasLength(1));
    final prefs = await SharedPreferences.getInstance();
    expect(remembered(prefs)!.startsLive, isFalse);
  });

  for (final locale in [const Locale('es'), const Locale('en')]) {
    testWidgets('unavailable GPT-Live is shown, cannot be chosen and says why '
        '${locale.languageCode}', (tester) async {
      await pump(tester, locale: locale, status: (_) => keyed());
      final es = locale.languageCode == 'es';
      await reveal(tester);
      // Both options are there, as in Desktop; GPT-Live cannot be chosen.
      expect(
        find.text(es ? 'Conversación de voz' : 'Voice conversation'),
        findsOneWidget,
      );
      expect(find.text('GPT-Live'), findsOneWidget);
      expect(selected(tester, _chainedKey), isTrue);
      expect(tappable(tester, _chainedKey), isTrue);
      expect(tappable(tester, _toggleKey), isFalse);
      // One line right under the row says why, in plain words, with the
      // button that fixes it.
      final reason = find.descendant(
        of: find.byKey(_reasonKey),
        matching: find.text(
          es
              ? 'GPT-Live necesita una clave de OpenAI en el servidor'
              : 'GPT-Live needs an OpenAI key on the server',
        ),
      );
      expect(reason, findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(_reasonKey)).dy,
        greaterThan(tester.getBottomLeft(find.byKey(_toggleKey)).dy),
      );
      expect(
        tester.getTopLeft(find.byKey(_reasonKey)).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('voice_main_dictation')))
              .dy,
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(_addKeyKey),
          matching: find.text(es ? 'Añadir clave' : 'Add key'),
        ),
        findsOneWidget,
      );
      // None of the server's English reaches the screen, and this reason
      // hides nothing behind details.
      for (final raw in const [
        'no OpenAI API key',
        'OPENAI_API_KEY',
        'voice.gpt_live',
        'No disponible:',
        'Unavailable:',
      ]) {
        expect(find.textContaining(raw), findsNothing, reason: raw);
      }
      expect(
        find.byKey(const ValueKey('voice_live_reason_toggle')),
        findsNothing,
      );
      await tester.tap(find.byKey(_toggleKey), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(configWrites, isEmpty);
      expect(envWrites, isEmpty);
      expect(selected(tester, _chainedKey), isTrue);
      expect(statusRequests, hasLength(1));

      // Advanced does not repeat the mode, and has nothing of GPT-Live to
      // set while it cannot start.
      await openAdvanced(tester);
      expect(find.byKey(_modeRowKey), findsNothing);
      expect(find.byKey(_toggleKey), findsNothing);
      expect(find.textContaining('GPT-Live'), findsNothing);
    });
  }

  testWidgets('saving the key re-reads the status and GPT-Live can be chosen', (
    tester,
  ) async {
    const secret = 'sk-test-0123456789abcdef';
    await pump(tester, status: (_) => keyed());
    await reveal(tester);
    expect(tappable(tester, _toggleKey), isFalse);

    await tester.tap(find.byKey(_addKeyKey));
    await tester.pumpAndSettle();
    // The same dialog as the reply voice: one field, never readable.
    expect(
      find.byKey(const ValueKey('voice_server_key_dialog')),
      findsOneWidget,
    );
    final field = find.byKey(const ValueKey('voice_server_key_field'));
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    await tester.enterText(field, '  $secret ');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('voice_server_key_save')));
    await tester.pumpAndSettle();

    // Saved on the server, for the active profile, in the variable GPT-Live
    // resolves its key from.
    expect(envWrites, hasLength(1));
    expect(jsonDecode(envWrites.single.body), {
      'key': 'VOICE_TOOLS_OPENAI_KEY',
      'value': secret,
      'profile': 'ops',
    });
    // The status was read again, for the same profile...
    expect(statusRequests, hasLength(2));
    expect(statusRequests.last.queryParameters['profile'], 'ops');
    // ...so the reason and its button are gone and the option can be chosen
    // without leaving the screen.
    expect(find.byKey(_reasonKey), findsNothing);
    expect(find.byKey(_addKeyKey), findsNothing);
    expect(find.byKey(const ValueKey('voice_server_key_dialog')), findsNothing);
    expect(tappable(tester, _toggleKey), isTrue);
    // The key is nowhere: not on screen, not in the phone's preferences.
    expect(find.textContaining(secret), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs
          .getKeys()
          .map(prefs.get)
          .where((value) => '$value'.contains(secret)),
      isEmpty,
    );
    expect(remembered(prefs)!.available, isTrue);

    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();
    expect(serverMode, 'gpt-live');
    expect(selected(tester, _toggleKey), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a key that could not be saved leaves the reason and says so', (
    tester,
  ) async {
    await pump(tester, status: (_) => keyed());
    envWriteFails = true;
    await reveal(tester);
    await tester.tap(find.byKey(_addKeyKey));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('voice_server_key_field')),
      'sk-test-0123456789abcdef',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('voice_server_key_save')));
    await tester.pumpAndSettle();

    expect(envWrites, hasLength(1));
    expect(
      find.text('No se pudo guardar la clave en el servidor.'),
      findsOneWidget,
    );
    expect(statusRequests, hasLength(1));
    expect(find.byKey(_reasonKey), findsOneWidget);
    expect(find.byKey(_addKeyKey), findsOneWidget);
    expect(tappable(tester, _toggleKey), isFalse);
  });

  testWidgets('a read-only connection sees the reason but no key button', (
    tester,
  ) async {
    await pump(tester, readOnly: true, status: (_) => keyed());
    await reveal(tester);
    expect(find.text('GPT-Live'), findsOneWidget);
    expect(
      find.text('GPT-Live necesita una clave de OpenAI en el servidor'),
      findsOneWidget,
    );
    expect(find.byKey(_addKeyKey), findsNothing);
    expect(find.text('Añadir clave'), findsNothing);
    await tester.tap(find.byKey(_toggleKey), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(configWrites, isEmpty);
    expect(envWrites, isEmpty);
  });

  testWidgets('the row and its reason paint from the last known status', (
    tester,
  ) async {
    final gate = Completer<http.Response>();
    await pump(
      tester,
      status: (_) => gate.future,
      initial: {
        'voice_live_status_v1::gpt-live-node::ops': jsonEncode({
          'mode': 'chained',
          'available': false,
          'reason': noKeyReason,
        }),
      },
    );
    // The server has not answered yet.
    expect(statusRequests, hasLength(1));
    expect(find.text('GPT-Live'), findsOneWidget);
    expect(tappable(tester, _toggleKey), isFalse);
    expect(
      find.text('GPT-Live necesita una clave de OpenAI en el servidor'),
      findsOneWidget,
    );
    expect(find.byKey(_addKeyKey), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Its answer replaces what was remembered.
    gate.complete(ok());
    await tester.pumpAndSettle();
    expect(find.byKey(_reasonKey), findsNothing);
    expect(tappable(tester, _toggleKey), isTrue);
  });

  testWidgets('with GPT-Live on offer, Advanced does not repeat the choice', (
    tester,
  ) async {
    await pump(tester, status: (_) => ok());
    await openAdvanced(tester);
    expect(find.byKey(_modeRowKey), findsNothing);
    expect(find.byKey(_toggleKey), findsNothing);
    expect(find.text('Modo de chat de voz'), findsNothing);
    // The choice is still on the main list.
    await backToMain(tester);
    expect(selected(tester, _chainedKey), isTrue);
    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();
    expect(serverMode, 'gpt-live');
    expect(selected(tester, _toggleKey), isTrue);
  });

  testWidgets('gpt-live chosen but unable to start stays chosen and says why', (
    tester,
  ) async {
    await pump(tester, mode: 'gpt-live', status: (_) => keyed());
    await reveal(tester);
    // The row shows what the profile is set to, even though it cannot run.
    expect(selected(tester, _toggleKey), isTrue);
    expect(tappable(tester, _toggleKey), isFalse);
    expect(
      find.text('GPT-Live necesita una clave de OpenAI en el servidor'),
      findsOneWidget,
    );
    expect(find.textContaining('no OpenAI API key'), findsNothing);
    expect(
      find.byKey(const ValueKey('voice_continue_when_locked')),
      findsOneWidget,
    );
    // The normal conversation can still be chosen; GPT-Live stays offered
    // with its reason.
    await tester.tap(find.byKey(_chainedKey));
    await tester.pumpAndSettle();
    expect(serverMode, 'chained');
    expect(selected(tester, _chainedKey), isTrue);
    expect(tappable(tester, _toggleKey), isFalse);
    expect(find.byKey(_reasonKey), findsOneWidget);

    await openAdvanced(tester);
    expect(find.byKey(_modeRowKey), findsNothing);
    expect(
      find.byKey(const ValueKey('voice_barge_in_enabled')),
      findsOneWidget,
    );
  });

  testWidgets('any other reason is a plain line, with the server text behind '
      'details', (tester) async {
    const serverText = 'realtime quota exhausted for this organisation';
    await pump(tester, status: (_) => ok(available: false, reason: serverText));
    await reveal(tester);
    expect(tappable(tester, _toggleKey), isFalse);
    expect(
      find.text('GPT-Live no está disponible en este servidor'),
      findsOneWidget,
    );
    // A key would not fix this one.
    expect(find.byKey(_addKeyKey), findsNothing);
    expect(find.textContaining('quota'), findsNothing);

    final details = find.byKey(const ValueKey('voice_live_reason_toggle'));
    expect(
      find.descendant(of: details, matching: find.text('Ver detalles')),
      findsOneWidget,
    );
    await tester.ensureVisible(details);
    await tester.pumpAndSettle();
    await tester.tap(details);
    await tester.pumpAndSettle();
    // The server's own text, whole and selectable.
    final detail = find.byKey(const ValueKey('voice_live_reason_detail'));
    expect(tester.widget<SelectableText>(detail).data, serverText);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(detail, findsNothing);
    expect(configWrites, isEmpty);
  });

  testWidgets('unavailable without a reason is the plain line and nothing '
      'else', (tester) async {
    await pump(tester, status: (_) => ok(available: false));
    await reveal(tester);
    expect(
      find.text('GPT-Live no está disponible en este servidor'),
      findsOneWidget,
    );
    expect(find.byKey(_addKeyKey), findsNothing);
    expect(
      find.byKey(const ValueKey('voice_live_reason_toggle')),
      findsNothing,
    );
  });

  testWidgets('hidden when the server has no GPT-Live route (404)', (
    tester,
  ) async {
    await pump(
      tester,
      status: (_) => http.Response('not found', 404),
      initial: {'voice_gpt_live_enabled_v1': true},
    );
    expect(find.byKey(_toggleKey, skipOffstage: false), findsNothing);
    // A server without the feature is remembered as the normal conversation.
    final prefs = await SharedPreferences.getInstance();
    expect(
      remembered(prefs),
      const VoiceChatMode(mode: VoiceLiveMode.chained, available: false),
    );
    // Nothing about GPT-Live is shown for a server without the route, now or
    // the next time the screen opens.
    expect(find.textContaining('GPT-Live'), findsNothing);
    expect(find.byKey(_reasonKey), findsNothing);
    expect(
      VoiceChatModeStore(
        prefs,
      ).lastStatus(VoiceChatModeStore.identity('gpt-live-node', 'ops')),
      isNull,
    );
    await openAdvanced(tester);
    expect(find.byKey(_toggleKey, skipOffstage: false), findsNothing);
    expect(find.textContaining('GPT-Live'), findsNothing);
  });

  testWidgets('hidden when the status read fails with a network error', (
    tester,
  ) async {
    await pump(tester, status: (_) => throw const SocketException('offline'));
    expect(tester.takeException(), isNull);
    expect(find.byKey(_toggleKey, skipOffstage: false), findsNothing);
    // A failed read is not an answer: nothing is remembered.
    final prefs = await SharedPreferences.getInstance();
    expect(remembered(prefs), isNull);
  });

  testWidgets('hidden when the route answers 405', (tester) async {
    await pump(tester, status: (_) => http.Response('no', 405));
    expect(find.byKey(_toggleKey, skipOffstage: false), findsNothing);
  });

  testWidgets('one status fetch on open', (tester) async {
    await pump(tester, status: (_) => ok());
    await openAdvanced(tester);
    await backToMain(tester);
    expect(statusRequests, hasLength(1));
    expect(statusRequests.single.queryParameters['profile'], 'ops');
  });

  testWidgets('background invalidates a late UI probe across resume', (
    tester,
  ) async {
    final gate = Completer<http.Response>();
    await pump(tester, mode: 'gpt-live', status: (_) => gate.future);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    gate.complete(ok());
    await tester.pumpAndSettle();
    expect(find.byKey(_toggleKey), findsNothing);
    expect(statusRequests, hasLength(1));
    // The retry is deliberate and lives in Advanced, not on the main list.
    expect(find.byKey(const ValueKey('voice_gpt_live_retry')), findsNothing);
    await openAdvanced(tester);
    expect(find.byKey(const ValueKey('voice_gpt_live_retry')), findsOneWidget);
  });

  testWidgets('transient status exposes deliberate retry without polling', (
    tester,
  ) async {
    var reads = 0;
    await pump(
      tester,
      mode: 'gpt-live',
      status: (_) => ++reads == 1 ? http.Response('{}', 503) : ok(),
    );
    expect(tester.takeException(), isNull);
    final strings = lookupStrings(const Locale('es'));
    final retry = find.byKey(const ValueKey('voice_gpt_live_retry'));
    expect(retry, findsNothing);
    await openAdvanced(tester);
    expect(retry, findsOneWidget);
    expect(find.text(strings.voiceGuardProbeTransient), findsOneWidget);
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(statusRequests, hasLength(2));
    expect(
      statusRequests.every((url) => url.queryParameters['profile'] == 'ops'),
      isTrue,
    );
    expect(retry, findsNothing);
    expect(find.text(strings.voiceGuardProbeTransient), findsNothing);
    await backToMain(tester);
    expect(selected(tester, _toggleKey), isTrue);
  });

  testWidgets('GPT-Live that will start keeps the phone switches on offer', (
    tester,
  ) async {
    await pump(
      tester,
      mode: 'gpt-live',
      serverRoute: true,
      status: (_) => ok(),
    );
    expect(
      find.byKey(const ValueKey('voice_continue_when_locked')),
      findsOneWidget,
    );
    await openAdvanced(tester);
    expect(
      find.byKey(const ValueKey('voice_barge_in_enabled')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('voice_vad_enabled')), findsOneWidget);
  });

  testWidgets(
    'choosing GPT-Live and coming back preserves every other voice setting',
    (tester) async {
      final voice = await pump(
        tester,
        status: (_) => ok(),
        locale: const Locale('en'),
        initial: {'voice_stt_engine': 'system', 'voice_tts_engine': 'device'},
      );
      final before = voice.settings;
      final prefsBefore = await SharedPreferences.getInstance();
      await before.save(prefsBefore);
      bool voiceSetting(String key) =>
          !key.startsWith('voice_chat_mode_v1::') &&
          !key.startsWith('voice_live_status_v1::');
      final preserved = {
        for (final key in prefsBefore.getKeys().where(voiceSetting))
          key: prefsBefore.get(key),
      };
      expect(find.text('Voice conversation'), findsOneWidget);
      expect(find.text('Chained conversation'), findsNothing);
      await tester.ensureVisible(find.byKey(_toggleKey));
      await tester.tap(find.byKey(_toggleKey));
      await tester.pumpAndSettle();
      expect(serverMode, 'gpt-live');
      // Dictation and the reply voice stay one tap away either way.
      expect(find.text('Android recognizer'), findsOneWidget);
      expect(find.text('Android voice'), findsOneWidget);
      final chained = find.byKey(_chainedKey);
      await tester.ensureVisible(chained);
      await tester.tap(chained);
      await tester.pumpAndSettle();
      expect(serverMode, 'chained');
      final prefs = await SharedPreferences.getInstance();
      final restored = VoiceSettings.load(prefs);
      expect(restored.sttEngine, before.sttEngine);
      expect(restored.ttsEngine, before.ttsEngine);
      expect(restored.streamingTtsProfile, before.streamingTtsProfile);
      expect(restored.serverSttUrl, before.serverSttUrl);
      expect({
        for (final key in prefs.getKeys().where(voiceSetting))
          key: prefs.get(key),
      }, preserved);
      expect(statusRequests, hasLength(3));
    },
  );

  for (final locale in [const Locale('es'), const Locale('en')]) {
    testWidgets('the main list keeps its order with GPT-Live on offer '
        '${locale.languageCode}', (tester) async {
      final voice = await pump(
        tester,
        status: (_) => ok(),
        locale: locale,
        initial: {'voice_tts_engine': 'device'},
      );
      final es = locale.languageCode == 'es';
      final rows = [
        find.text(es ? 'Conversación de voz' : 'Voice conversation'),
        find.byKey(const ValueKey('voice_main_dictation')),
        find.byKey(const ValueKey('voice_main_reply_voice')),
        find.byKey(const ValueKey('voice_auto_speak')),
        find.byKey(const ValueKey('voice_continue_when_locked')),
        find.byKey(const ValueKey('voice_main_advanced')),
      ];
      var previous = double.negativeInfinity;
      for (final row in rows) {
        expect(row, findsOneWidget);
        final top = tester.getTopLeft(row).dy;
        expect(top, greaterThan(previous));
        previous = top;
      }
      // The reply voice row names what speaks, in a word or two.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('voice_main_reply_voice')),
          matching: find.text(es ? 'Voz de Android' : 'Android voice'),
        ),
        findsOneWidget,
      );
      for (final jargon in const ['STT', 'TTS']) {
        expect(find.textContaining(jargon), findsNothing, reason: jargon);
      }
      // Nothing that moved one tap deeper is on the main screen.
      for (final key in [
        'voice_listening_section',
        'voice_reading_section',
        'voice_conversation_section',
        'voice_mode_phone_option',
        'voice_dictation_phone_option',
        'voice_setup_test_action',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(voice.microphoneCapturing.value, isFalse);
      expect(voice.speaking.value, isFalse);
      expect(voice.nativeVoiceActive, isFalse);
      expect(statusRequests, hasLength(1));
    });
  }

  for (final lang in ['es', 'en']) {
    for (final live in [false, true]) {
      testWidgets(
        'real Flutter review render $lang ${live ? 'live' : 'chained'}',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844) * 3;
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async =>
                '${Directory.current.path}/build/voice-settings-fixture',
          );
          addTearDown(
            () =>
                tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                  const MethodChannel('plugins.flutter.io/path_provider'),
                  null,
                ),
          );
          await loadDesignFonts();
          final voice = await pump(
            tester,
            status: (_) => ok(),
            locale: Locale(lang),
            mode: live ? 'gpt-live' : 'chained',
            initial: {
              'voice_stt_engine': 'system',
              'voice_tts_engine': 'device',
            },
          );
          expect(tester.takeException(), isNull);
          expect(voice.microphoneCapturing.value, isFalse);
          expect(voice.speaking.value, isFalse);
          expect(voice.nativeVoiceActive, isFalse);
          if (const bool.fromEnvironment('VOICE_REVIEW_RENDER')) {
            await tester.runAsync(() async {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey('voice-review-render')),
              );
              final image = await boundary.toImage(pixelRatio: 2);
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final path =
                  'build/voice-settings-review/$lang-${live ? 'live' : 'chained'}.png';
              final file = File(path);
              await file.parent.create(recursive: true);
              await file.writeAsBytes(png!.buffer.asUint8List());
              image.dispose();
            });
          }
        },
      );
    }
  }

  for (final extension in <Object>[
    true,
    'unknown',
    {'supported': true},
  ]) {
    testWidgets('unknown rapid-turn extension is inert: $extension', (
      tester,
    ) async {
      final voice = await pump(
        tester,
        mode: 'gpt-live',
        status: (request) => http.Response(
          jsonEncode({
            'ok': true,
            'mode': serverMode,
            'available': true,
            'voice_turn': extension,
          }),
          200,
        ),
      );
      expect(statusRequests, hasLength(1));
      expect(statusRequests.single.path, '/api/audio/voice-live/status');
      expect(statusRequests.single.queryParameters, {'profile': 'ops'});
      expect(voice.microphoneCapturing.value, isFalse);
      expect(voice.speaking.value, isFalse);
      expect(voice.nativeVoiceActive, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().where((key) => key.contains('voice_turn')),
        isEmpty,
      );
      expect(selected(tester, _toggleKey), isTrue);
      await tester.tap(find.byKey(_chainedKey));
      await tester.pumpAndSettle();
      expect(serverMode, 'chained');
      expect(voice.microphoneCapturing.value, isFalse);
      expect(voice.nativeVoiceActive, isFalse);
    });
  }

  testWidgets('Live access required is not unsupported and opens no audio', (
    tester,
  ) async {
    final voice = await pump(
      tester,
      mode: 'gpt-live',
      status: (_) => http.Response('{}', 401),
    );
    final strings = lookupStrings(const Locale('es'));
    await openAdvanced(tester);
    expect(find.text(strings.voiceGuardProbeAccess), findsOneWidget);
    expect(find.text(strings.voiceLiveUnavailable), findsNothing);
    expect(voice.microphoneCapturing.value, isFalse);
    expect(voice.speaking.value, isFalse);
    expect(voice.nativeVoiceActive, isFalse);
    // Dashboard's existing auth path retries one GET; no session/provider POST.
    expect(statusRequests, hasLength(2));
    expect(
      statusRequests.every((url) => url.queryParameters['profile'] == 'ops'),
      isTrue,
    );
    await tester.pump(const Duration(minutes: 1));
    expect(statusRequests, hasLength(2));
  });

  testWidgets('English copy', (tester) async {
    await pump(tester, status: (_) => ok(), locale: const Locale('en'));
    await reveal(tester);
    expect(find.text('Voice conversation'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('GPT-Live'), findsOneWidget);
    await openAdvanced(tester);
    final strings = lookupStrings(const Locale('en'));
    expect(find.text('VOICE CONVERSATION'), findsOneWidget);
    expect(find.text('SPEECH TO TEXT'), findsOneWidget);
    expect(find.text(strings.voiceBargeInTitle), findsOneWidget);
    expect(find.text(strings.voiceVadTitle), findsOneWidget);
  });
}
