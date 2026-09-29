import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/server_voice_control_surface.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'inspeccionar no cambia proveedor y las credenciales son write-only',
    (tester) async {
      var activeTts = 'edge';
      final requests = <http.Request>[];
      final dashboard = DashboardClient(
        host: 'demo.local',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET' && request.url.path == '/api/config') {
            return http.Response(
              jsonEncode({
                'config': {
                  'stt': {
                    'provider': 'local',
                    'local': {'model': 'base', 'language': 'es'},
                  },
                  'tts': {
                    'provider': activeTts,
                    'edge': {'voice': 'es-ES-AlvaroNeural'},
                    'elevenlabs': {
                      'voice_id': 'voice-default',
                      'model_id': 'eleven_flash_v2_5',
                    },
                  },
                },
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/config/schema') {
            return http.Response(
              jsonEncode({
                'fields': {
                  'stt.provider': {
                    'type': 'select',
                    'options': ['local', 'groq'],
                  },
                  'stt.local.model': {
                    'type': 'select',
                    'options': ['tiny', 'base'],
                  },
                  'stt.local.language': {'type': 'string'},
                  'tts.provider': {
                    'type': 'select',
                    'options': ['edge', 'elevenlabs'],
                  },
                  'tts.edge.voice': {'type': 'string'},
                  'tts.elevenlabs.voice_id': {'type': 'string'},
                  'tts.elevenlabs.model_id': {'type': 'string'},
                },
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/tools/toolsets/tts/config') {
            return http.Response(
              jsonEncode({
                'active_provider': activeTts == 'edge'
                    ? 'Microsoft Edge TTS'
                    : 'ElevenLabs',
                'providers': [
                  {
                    'name': 'Microsoft Edge TTS',
                    'status': 'ready',
                    'is_active': activeTts == 'edge',
                    'tts_provider': 'edge',
                    'env_vars': [],
                  },
                  {
                    'name': 'ElevenLabs',
                    'status': 'needs_keys',
                    'is_active': activeTts == 'elevenlabs',
                    'tts_provider': 'elevenlabs',
                    'env_vars': [
                      {
                        'key': 'ELEVENLABS_API_KEY',
                        'prompt': 'ElevenLabs API key',
                        'is_set': false,
                      },
                    ],
                  },
                ],
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/tools/toolsets/stt/config') {
            return http.Response(
              jsonEncode({
                'active_provider': 'Local Whisper',
                'providers': [
                  {
                    'name': 'Local Whisper',
                    'status': 'ready',
                    'is_active': true,
                    'env_vars': [],
                    'post_setup': 'whisper',
                  },
                ],
              }),
              200,
            );
          }
          if (request.method == 'PUT' &&
              request.url.path == '/api/tools/toolsets/tts/provider') {
            activeTts = 'elevenlabs';
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          if (request.method == 'PUT' &&
              request.url.path == '/api/tools/toolsets/tts/env') {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('{}', 404);
        }),
      );
      addTearDown(dashboard.close);

      await tester.pumpWidget(_host(dashboard, profile: 'work'));
      await tester.pumpAndSettle();

      expect(find.text('Microsoft Edge TTS'), findsOneWidget);
      expect(find.text('ElevenLabs'), findsNothing);
      expect(
        requests.where(
          (request) =>
              request.method == 'PUT' && request.url.path.endsWith('/provider'),
        ),
        isEmpty,
      );

      await _tapAfterRevealing(
        tester,
        find.byKey(const ValueKey('server-tts-provider-chooser')),
      );
      await tester.pumpAndSettle();
      expect(find.text('ElevenLabs'), findsOneWidget);
      await tester.tap(find.text('ElevenLabs'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('server-tts-use-ElevenLabs')),
        findsOneWidget,
      );
      expect(
        requests.where(
          (request) =>
              request.method == 'PUT' && request.url.path.endsWith('/provider'),
        ),
        isEmpty,
      );

      final useElevenLabs = find.byKey(
        const ValueKey('server-tts-use-ElevenLabs'),
      );
      await tester.ensureVisible(useElevenLabs);
      await tester.pump();
      await tester.tap(useElevenLabs);
      await tester.pumpAndSettle();
      expect(activeTts, 'elevenlabs');
      expect(
        requests
            .where((request) => request.url.path.contains('/tools/toolsets/'))
            .every(
              (request) => request.url.queryParameters['profile'] == 'work',
            ),
        isTrue,
      );

      final secretField = find.byKey(
        const ValueKey('server-credential-ELEVENLABS_API_KEY'),
      );
      expect(secretField, findsOneWidget);
      await tester.ensureVisible(secretField);
      await tester.pump();
      expect(tester.widget<TextField>(secretField).obscureText, isTrue);
      await tester.enterText(secretField, 'sk-only-in-controller');
      final save = find.descendant(
        of: secretField,
        matching: find.byType(IconButton),
      );
      await tester.tap(save);
      await tester.pumpAndSettle();

      final credentialRequest = requests.lastWhere(
        (request) => request.url.path.endsWith('/tts/env'),
      );
      expect(jsonDecode(credentialRequest.body), {
        'env': {'ELEVENLABS_API_KEY': 'sk-only-in-controller'},
      });
      expect(tester.widget<TextField>(secretField).controller!.text, isEmpty);
      expect(find.text('sk-only-in-controller'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'el Whisper predeterminado usa el schema real y permite elegir modelo',
    (tester) async {
      final requests = <http.Request>[];
      final dashboard = DashboardClient(
        host: 'hermes-node.local',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET' && request.url.path == '/api/config') {
            // Hermes omite los valores predeterminados: local + base.
            return http.Response(jsonEncode({'config': {}}), 200);
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/config/schema') {
            return http.Response(
              jsonEncode({
                'fields': {
                  // El Dashboard real no publica stt.provider, pero sí las
                  // rutas configurables del proveedor local predeterminado.
                  'stt.local.model': {
                    'type': 'select',
                    'options': ['tiny', 'base', 'small', 'medium', 'large-v3'],
                  },
                  'stt.local.language': {'type': 'string'},
                },
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/tools/toolsets/stt/config') {
            return http.Response(
              jsonEncode({
                // Versiones anteriores del Dashboard omiten el catálogo STT.
                'active_provider': null,
                'providers': [],
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/tools/toolsets/tts/config') {
            return http.Response(
              jsonEncode({'active_provider': null, 'providers': []}),
              200,
            );
          }
          if (request.method == 'PUT' && request.url.path == '/api/config') {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('{}', 404);
        }),
      );
      addTearDown(dashboard.close);

      await tester.pumpWidget(_host(dashboard));
      await tester.pumpAndSettle();

      final parameters = find.byKey(const ValueKey('server-stt-parameters'));
      expect(parameters, findsOneWidget);
      expect(tester.widget<OutlinedButton>(parameters).onPressed, isNotNull);
      expect(find.text('base'), findsOneWidget);

      await _openSttParameters(tester, expandAdvanced: false);
      final model = find.byKey(
        const ValueKey('server-voice-field-stt.local.model'),
      );
      expect(model, findsOneWidget);
      expect(
        tester.widget<DropdownButtonFormField<String>>(model).initialValue,
        'base',
      );

      await tester.tap(model);
      await tester.pumpAndSettle();
      await tester.tap(find.text('small').last);
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('server-voice-parameters-save'));
      await tester.tap(save);
      await tester.pumpAndSettle();

      final patchRequest = requests.lastWhere(
        (request) =>
            request.method == 'PUT' && request.url.path == '/api/config',
      );
      expect(jsonDecode(patchRequest.body), {
        'config': {
          'stt': {
            'local': {'model': 'small'},
          },
        },
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('se adapta a una pantalla estrecha sin overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dashboard = DashboardClient(
      host: 'demo.local',
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        if (request.url.path == '/api/config') {
          return http.Response(
            jsonEncode({
              'tts': {
                'provider': 'edge',
                'edge': {'voice': 'es-ES-AlvaroNeural'},
              },
              'stt': {
                'provider': 'local',
                'local': {'model': 'base'},
              },
            }),
            200,
          );
        }
        if (request.url.path == '/api/config/schema') {
          return http.Response(jsonEncode({'fields': {}}), 200);
        }
        if (request.url.path.endsWith('/config')) {
          return http.Response(
            jsonEncode({'active_provider': null, 'providers': []}),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    addTearDown(dashboard.close);

    await tester.pumpWidget(_host(dashboard));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('server-voice-manager')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'excluye secretos por nombre y metadatos y nunca los incluye en el patch',
    (tester) async {
      final requests = <http.Request>[];
      final dashboard = _schemaDashboard(
        requests: requests,
        config: {
          'tts': {
            'provider': 'edge',
            'edge': {
              'model': 'edge-current',
              'apiKey': 'name-secret',
              'account_value': 'flag-secret',
              'auth_header': 'write-only-secret',
              'pin': 'format-secret',
              'future_value': 'alias-secret',
              'opaque_value': 'widget-secret',
            },
          },
          'stt': {'provider': 'local'},
        },
        fields: {
          'tts.provider': {
            'type': 'select',
            'options': ['edge'],
          },
          'tts.edge.model': {'type': 'string'},
          'tts.edge.apiKey': {'type': 'string'},
          'tts.edge.account_value': {'type': 'string', 'secret': true},
          'tts.edge.auth_header': {'type': 'string', 'writeOnly': true},
          'tts.edge.pin': {'type': 'string', 'format': 'password'},
          'tts.edge.future_value': {'type': 'string', 'write_only': 1},
          'tts.edge.opaque_value': {
            'type': 'string',
            'ui': {'widget': 'password'},
          },
        },
      );
      addTearDown(dashboard.close);

      await tester.pumpWidget(_host(dashboard));
      await tester.pumpAndSettle();
      await _tapAfterRevealing(
        tester,
        find.byKey(const ValueKey('server-tts-provider-chooser')),
      );
      await tester.pumpAndSettle();
      final provider = find.byKey(
        const ValueKey('server-tts-provider-Microsoft Edge TTS'),
      );
      await tester.tap(provider);
      await tester.pump();

      expect(
        find.byKey(const ValueKey('server-voice-field-tts.edge.model')),
        findsNothing,
        reason: 'an unknown free-text model must not be exposed on mobile',
      );
      expect(
        find.byKey(const ValueKey('server-tts-parameters-edge')),
        findsNothing,
      );
      for (final key in const [
        'tts.edge.apiKey',
        'tts.edge.account_value',
        'tts.edge.auth_header',
        'tts.edge.pin',
        'tts.edge.future_value',
        'tts.edge.opaque_value',
      ]) {
        expect(
          find.byKey(ValueKey('server-voice-field-$key')),
          findsNothing,
          reason: '$key must never become an editable config field',
        );
      }
      for (final secret in const [
        'name-secret',
        'flag-secret',
        'write-only-secret',
        'format-secret',
        'alias-secret',
        'widget-secret',
      ]) {
        expect(find.text(secret), findsNothing);
      }

      expect(
        requests.where(
          (request) =>
              request.method == 'PUT' && request.url.path == '/api/config',
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('usa labels del schema y fallbacks localizados en inglés', (
    tester,
  ) async {
    final dashboard = _schemaDashboard(
      requests: <http.Request>[],
      config: {
        'tts': {
          'provider': 'edge',
          'edge': {
            'model': 'edge-model',
            'voice': 'en-US-AriaNeural',
            'language': 'en',
            'speed': 1.0,
          },
        },
        'stt': {'provider': 'local'},
      },
      fields: {
        'tts.provider': {
          'type': 'select',
          'options': ['edge'],
        },
        'tts.edge.model': {'type': 'string'},
        'tts.edge.voice': {'type': 'string'},
        'tts.edge.language': {'type': 'string'},
        'tts.edge.speed': {'type': 'number', 'label': 'Speaking rate'},
      },
    );
    addTearDown(dashboard.close);

    await tester.pumpWidget(_host(dashboard, locale: const Locale('en')));
    await tester.pumpAndSettle();
    await _openEdgeParameters(tester);
    await _expandAdvancedParameters(tester);

    expect(find.text('Model'), findsNothing);
    expect(find.text('Voice'), findsWidgets);
    expect(find.text('Language'), findsWidgets);
    expect(find.text('Speaking rate', skipOffstage: false), findsOneWidget);
    expect(find.text('Modelo'), findsNothing);
    expect(find.text('Voz'), findsNothing);
    expect(find.text('Idioma'), findsNothing);
    expect(find.text('Velocidad'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('prefiere idioma/modelo del proveedor y elimina duplicados comunes', () {
    final paths = deduplicateServerVoiceSchemaFieldPaths(
      section: 'stt',
      provider: 'local',
      fields: {
        'stt.provider': {'type': 'select'},
        'stt.language': {'type': 'string'},
        'stt.local.language': {'type': 'string'},
        'stt.model': {'type': 'string'},
        'stt.local.model': {'type': 'string'},
        'stt.local.vad_enabled': {'type': 'boolean'},
      },
    );

    expect(paths, contains('stt.local.language'));
    expect(paths, contains('stt.local.model'));
    expect(paths, contains('stt.local.vad_enabled'));
    expect(paths, isNot(contains('stt.language')));
    expect(paths, isNot(contains('stt.model')));
  });

  // Issue #65: «Automático» en el idioma de dictado se guardaba como el texto
  // literal `auto`, que Hermes reenvía al proveedor STT (OpenAI responde 400).
  // Para STT, automático es un valor vacío, como en los defaults de Hermes.
  for (final initial in const ['es', '']) {
    testWidgets(
      'idioma STT «Automático» guarda vacío, nunca `auto` (inicial: "$initial")',
      (tester) async {
        final requests = <http.Request>[];
        final dashboard = _schemaDashboard(
          requests: requests,
          config: {
            'stt': {
              'provider': 'local',
              'local': {'model': 'base', 'language': initial},
            },
            'tts': {'provider': 'edge'},
          },
          fields: {
            'stt.provider': {
              'type': 'select',
              'options': ['local', 'openai'],
            },
            'stt.local.model': {
              'type': 'select',
              'options': ['base', 'small'],
            },
            'stt.local.language': {'type': 'string'},
            'tts.provider': {
              'type': 'select',
              'options': ['edge'],
            },
          },
        );
        addTearDown(dashboard.close);

        await tester.pumpWidget(_host(dashboard));
        await tester.pumpAndSettle();
        await _openSttParameters(tester, expandAdvanced: false);

        final language = find.byKey(
          const ValueKey('server-voice-field-stt.local.language'),
        );
        await _reveal(tester, language);
        if (initial.isEmpty) {
          // Un idioma vacío en el servidor ya es automático: se muestra así.
          expect(
            find.descendant(of: language, matching: find.text('Automático')),
            findsOneWidget,
          );
          // Elegir otro idioma y volver a Automático debe seguir guardando vacío.
          await tester.tap(language);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Español').last);
          await tester.pumpAndSettle();
        }
        await tester.tap(language);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Automático').last);
        await tester.pumpAndSettle();

        final save = find.byKey(
          const ValueKey('server-voice-parameters-save'),
        );
        await _reveal(tester, save);
        await tester.tap(save);
        await tester.pumpAndSettle();

        final put = requests.lastWhere(
          (request) =>
              request.method == 'PUT' && request.url.path == '/api/config',
        );
        final body = jsonDecode(put.body) as Map<String, dynamic>;
        final stt = (body['config'] as Map)['stt'] as Map;
        expect((stt['local'] as Map)['language'], '');
        expect(put.body, isNot(contains('"auto"')));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('editor avanzado soporta 320 dp y texto al 200 %', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final dashboard = _schemaDashboard(
      requests: <http.Request>[],
      config: {
        'stt': {
          'provider': 'local',
          'local': {
            'model': 'small',
            'language': 'es',
            'vad_min_silence_duration_ms': 500,
          },
        },
        'tts': {'provider': 'edge'},
      },
      fields: {
        'stt.provider': {
          'type': 'select',
          'options': ['local', 'groq'],
        },
        'stt.local.model': {
          'type': 'select',
          'options': ['base', 'small'],
        },
        'stt.local.language': {'type': 'string'},
        'stt.local.vad_min_silence_duration_ms': {'type': 'number'},
        'tts.provider': {
          'type': 'select',
          'options': ['edge'],
        },
      },
    );
    addTearDown(dashboard.close);

    await tester.pumpWidget(_host(dashboard));
    await tester.pumpAndSettle();
    await _openSttParameters(tester, expandAdvanced: false);
    await _expandAdvancedParameters(tester);

    expect(find.byKey(const ValueKey('server-voice-advanced')), findsOneWidget);
    await _reveal(tester, find.text('Silencio para terminar'));
    expect(find.text('Silencio para terminar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'los sentinels son automáticos y no duplica el toggle del motor activo',
    (tester) async {
      final dashboard = _schemaDashboard(
        requests: <http.Request>[],
        config: {
          'stt': {
            'provider': 'local',
            'local': {
              'enabled': true,
              'vad_enabled': true,
              'echo_transcripts': true,
              'confidence_threshold': -1,
            },
          },
          'tts': {'provider': 'edge'},
        },
        fields: {
          'stt.provider': {
            'type': 'select',
            'options': ['local'],
          },
          'stt.local.enabled': {'type': 'boolean'},
          'stt.local.vad_enabled': {'type': 'boolean'},
          'stt.local.echo_transcripts': {'type': 'boolean'},
          'stt.local.confidence_threshold': {'type': 'number'},
          'tts.provider': {
            'type': 'select',
            'options': ['edge'],
          },
        },
      );
      addTearDown(dashboard.close);

      await tester.pumpWidget(_host(dashboard));
      await tester.pumpAndSettle();
      await _openSttParameters(tester, expandAdvanced: true);

      expect(
        find.byKey(const ValueKey('server-voice-field-stt.local.enabled')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('server-voice-field-stt.local.vad_enabled')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('server-voice-field-stt.local.echo_transcripts'),
        ),
        findsNothing,
      );
      expect(find.text('Automático'), findsOneWidget);
      expect(find.text('-100 %'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('un proveedor sin estado no se anuncia como listo', (
    tester,
  ) async {
    final dashboard = _schemaDashboard(
      requests: <http.Request>[],
      config: {
        'stt': {'provider': 'local'},
        'tts': {
          'provider': 'edge',
          'edge': {'voice': 'es-ES-AlvaroNeural'},
        },
      },
      fields: {
        'stt.provider': {
          'type': 'select',
          'options': ['local'],
        },
        'tts.provider': {
          'type': 'select',
          'options': ['edge', 'neutts'],
        },
        'tts.edge.voice': {'type': 'string'},
      },
    );
    addTearDown(dashboard.close);

    await tester.pumpWidget(_host(dashboard));
    await tester.pumpAndSettle();
    await _tapAfterRevealing(
      tester,
      find.byKey(const ValueKey('server-tts-provider-chooser')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('server-tts-provider-NeuTTS')),
      findsOneWidget,
    );
    expect(find.text('Estado desconocido'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ofrece selectores conocidos y oculta campos técnicos vacíos', (
    tester,
  ) async {
    final dashboard = _schemaDashboard(
      requests: <http.Request>[],
      config: {
        'stt': {'provider': 'local'},
        'tts': {
          'provider': 'edge',
          'edge': {'voice': '', 'language': ''},
        },
      },
      fields: {
        'tts.provider': {
          'type': 'select',
          'options': ['edge'],
        },
        'tts.edge.voice': {'type': 'string'},
        'tts.edge.language': {'type': 'string'},
        'tts.edge.future_empty_parameter': {'type': 'string'},
      },
    );
    addTearDown(dashboard.close);

    await tester.pumpWidget(_host(dashboard));
    await tester.pumpAndSettle();
    await _openEdgeParameters(tester);

    final voice = find.byKey(
      const ValueKey('server-voice-field-tts.edge.voice'),
    );
    final language = find.byKey(
      const ValueKey('server-voice-field-tts.edge.language'),
    );
    expect(voice, findsOneWidget);
    expect(language, findsOneWidget);
    expect(tester.widget(voice), isA<DropdownButtonFormField<String>>());
    expect(tester.widget(language), isA<DropdownButtonFormField<String>>());
    expect(
      find.byKey(
        const ValueKey('server-voice-field-tts.edge.future_empty_parameter'),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'NeuTTS usa catálogos oficiales y nunca pide rutas del servidor',
    (tester) async {
      final dashboard = _schemaDashboard(
        requests: <http.Request>[],
        config: {
          'stt': {'provider': 'local'},
          'tts': {
            'provider': 'neutts',
            'neutts': {
              'model': 'neuphonic/neutts-air-q4-gguf',
              'device': 'cpu',
              'ref_audio': '/srv/hermes/voice.wav',
              'ref_text': '/srv/hermes/voice.txt',
            },
          },
        },
        fields: {
          'tts.provider': {
            'type': 'select',
            'options': ['neutts'],
          },
          'tts.neutts.model': {'type': 'string'},
          'tts.neutts.device': {'type': 'string'},
          'tts.neutts.ref_audio': {'type': 'string'},
          'tts.neutts.ref_text': {'type': 'string'},
        },
      );
      addTearDown(dashboard.close);

      await tester.pumpWidget(_host(dashboard));
      await tester.pumpAndSettle();
      await _tapAfterRevealing(
        tester,
        find.byKey(const ValueKey('server-tts-active-parameters')),
      );
      await tester.pumpAndSettle();

      final model = find.byKey(
        const ValueKey('server-voice-field-tts.neutts.model'),
      );
      final device = find.byKey(
        const ValueKey('server-voice-field-tts.neutts.device'),
      );
      expect(tester.widget(model), isA<DropdownButtonFormField<String>>());
      expect(tester.widget(device), isA<DropdownButtonFormField<String>>());
      expect(
        find.byKey(const ValueKey('server-voice-field-tts.neutts.ref_audio')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('server-voice-field-tts.neutts.ref_text')),
        findsNothing,
      );
      expect(find.byType(TextFormField), findsNothing);
      expect(
        find.textContaining(
          'Hermes todavía no publica una subida remota segura',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _openEdgeParameters(WidgetTester tester) async {
  final chooser = find.byKey(const ValueKey('server-tts-provider-chooser'));
  await _tapAfterRevealing(tester, chooser);
  await tester.pumpAndSettle();
  final provider = find.byKey(
    const ValueKey('server-tts-provider-Microsoft Edge TTS'),
  );
  expect(provider, findsOneWidget);
  await tester.ensureVisible(provider);
  await tester.pump();
  await tester.tap(provider);
  await tester.pump();

  final parameters = find.byKey(const ValueKey('server-tts-parameters-edge'));
  expect(parameters, findsOneWidget);
  await tester.ensureVisible(parameters);
  await tester.pump();
  await tester.tap(parameters);
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey('server-tts-parameters-surface')),
    findsOneWidget,
  );
}

Future<void> _openSttParameters(
  WidgetTester tester, {
  required bool expandAdvanced,
}) async {
  final parameters = find.byKey(const ValueKey('server-stt-parameters'));
  await _tapAfterRevealing(tester, parameters);
  await tester.pumpAndSettle();
  if (find
      .byKey(const ValueKey('server-stt-parameters-surface'))
      .evaluate()
      .isEmpty) {
    final button = tester.widget<TextButton>(parameters);
    expect(button.onPressed, isNotNull);
    button.onPressed!.call();
    await tester.pumpAndSettle();
  }
  expect(
    find.byKey(const ValueKey('server-stt-parameters-surface')),
    findsOneWidget,
  );
  if (expandAdvanced) await _expandAdvancedParameters(tester);
}

Future<void> _expandAdvancedParameters(WidgetTester tester) async {
  final advanced = find.byKey(const ValueKey('server-voice-advanced'));
  await _tapAfterRevealing(tester, advanced);
  await tester.pumpAndSettle();
  tester.widget<ExpansionTile>(advanced).controller!.expand();
  await tester.pumpAndSettle();
}

Future<void> _tapAfterRevealing(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 10 && target.evaluate().isEmpty; attempt++) {
    final scrollable = find.byType(Scrollable);
    if (scrollable.evaluate().isEmpty) break;
    await tester.drag(scrollable.last, const Offset(0, -220));
    await tester.pump();
  }
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 10 && target.evaluate().isEmpty; attempt++) {
    final scrollable = find.byType(Scrollable);
    if (scrollable.evaluate().isEmpty) break;
    await tester.drag(scrollable.last, const Offset(0, -180));
    await tester.pump();
  }
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump();
}

DashboardClient _schemaDashboard({
  required List<http.Request> requests,
  required Map<String, dynamic> config,
  required Map<String, dynamic> fields,
}) => DashboardClient(
  host: 'demo.local',
  manualToken: 'test-token',
  httpClientOverride: MockClient((request) async {
    requests.add(request);
    if (request.method == 'GET' && request.url.path == '/api/config') {
      return http.Response(jsonEncode({'config': config}), 200);
    }
    if (request.method == 'GET' && request.url.path == '/api/config/schema') {
      return http.Response(jsonEncode({'fields': fields}), 200);
    }
    if (request.method == 'GET' &&
        request.url.path.startsWith('/api/tools/toolsets/') &&
        request.url.path.endsWith('/config')) {
      return http.Response(
        jsonEncode({'active_provider': null, 'providers': []}),
        200,
      );
    }
    if (request.method == 'PUT' && request.url.path == '/api/config') {
      return http.Response(jsonEncode({'ok': true}), 200);
    }
    return http.Response('{}', 404);
  }),
);

Widget _host(
  DashboardClient dashboard, {
  String? profile,
  Locale locale = const Locale('es'),
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: Scaffold(
    body: ServerVoiceControlSurface(
      dashboard: dashboard,
      readOnly: false,
      profile: profile,
      onServerChanged: () {},
    ),
  ),
);
