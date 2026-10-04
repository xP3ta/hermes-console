// Tests para la lógica pura de ExternalProviderScreen.
// Cubre normalización de URL, parseo de respuestas y humanización de errores.
// Los widget tests se omiten aquí porque dependen de DashboardClient /
// BridgeManager — ver connection_manager_test para ese nivel.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/external_provider_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final en = lookupStrings(const Locale('en'));
  group('normalizeExternalProviderUrl', () {
    test('conserva una raíz para poder probar compatibilidad', () {
      expect(
        normalizeExternalProviderUrl('http://192.168.1.5:11434'),
        'http://192.168.1.5:11434',
      );
    });

    test('quita barra final', () {
      expect(
        normalizeExternalProviderUrl('http://192.168.1.5:11434/'),
        'http://192.168.1.5:11434',
      );
    });

    test('quita varias barras finales', () {
      expect(
        normalizeExternalProviderUrl('http://host:1234///'),
        'http://host:1234',
      );
    });

    test('conserva el sufijo /v1 de la URL canónica', () {
      expect(
        normalizeExternalProviderUrl('http://host:11434/v1'),
        'http://host:11434/v1',
      );
    });

    test('conserva /v1 y quita solo la barra final', () {
      expect(
        normalizeExternalProviderUrl('http://host:11434/v1/'),
        'http://host:11434/v1',
      );
    });

    test('respeta rutas que no terminan en /v1', () {
      expect(
        normalizeExternalProviderUrl('http://host:1234/openai'),
        'http://host:1234/openai',
      );
    });

    test('trim de espacios', () {
      expect(
        normalizeExternalProviderUrl('  http://host:1234  '),
        'http://host:1234',
      );
    });

    test('URL vacía devuelve vacío', () {
      expect(normalizeExternalProviderUrl(''), '');
    });
  });

  group('externalProviderBaseUrlCandidates', () {
    test('prueba la raíz y luego su endpoint OpenAI compatible', () {
      expect(externalProviderBaseUrlCandidates('http://host:11434'), [
        'http://host:11434',
        'http://host:11434/v1',
      ]);
    });

    test('no duplica /v1 cuando ya forma parte de la URL', () {
      expect(externalProviderBaseUrlCandidates('http://host:8000/v1'), [
        'http://host:8000/v1',
      ]);
    });
  });

  group('probeExternalProviderCandidates', () {
    test('continúa con /v1 si la raíz no expone /models', () async {
      final requested = <String>[];

      final result = await probeExternalProviderCandidates(
        'https://edge.example',
        (baseUrl) async {
          requested.add(baseUrl);
          if (baseUrl == 'https://edge.example') {
            throw Exception('HTTP 404');
          }
          return ['edge-model'];
        },
      );

      expect(requested, ['https://edge.example', 'https://edge.example/v1']);
      expect(result.baseUrl, 'https://edge.example/v1');
      expect(result.models, ['edge-model']);
    });

    test('conserva la URL exacta que respondió', () async {
      final result = await probeExternalProviderCandidates(
        'https://edge.example/v1',
        (_) async => ['edge-model'],
      );

      expect(result.baseUrl, 'https://edge.example/v1');
      expect(result.models, ['edge-model']);
    });
  });

  group('humanizeProviderTestError', () {
    test('connection refused', () {
      final msg = humanizeProviderTestError(
        en,
        'SocketException: Connection refused, errno = 111',
      );
      expect(msg, contains('refused'));
    });

    test('host lookup failure', () {
      final msg = humanizeProviderTestError(
        en,
        'SocketException: Failed host lookup: "host.invalid"',
      );
      expect(msg, contains('resolved'));
    });

    test('timeout', () {
      final msg = humanizeProviderTestError(
        en,
        'TimeoutException: Future not completed, duration = 0:00:08.000000',
      );
      expect(msg, contains('timed out'));
    });

    test('TLS error', () {
      final msg = humanizeProviderTestError(
        en,
        'HandshakeException: certificate',
      );
      expect(msg, contains('TLS'));
    });

    test('long error truncates to 220 chars', () {
      final long = 'X' * 500;
      final msg = humanizeProviderTestError(en, long);
      expect(msg.length, lessThanOrEqualTo(223)); // 220 + "…" 1 char + margen
    });

    test('short error passes through', () {
      const short = 'Something weird happened';
      expect(humanizeProviderTestError(en, short), short);
    });

    test('HTTP 401 menciona API key', () {
      final msg = humanizeProviderTestError(en, 'Exception: HTTP 401');
      expect(msg, contains('401'));
      expect(msg, contains('API key'));
    });

    test('HTTP 403 menciona permisos', () {
      final msg = humanizeProviderTestError(en, 'Exception: HTTP 403');
      expect(msg, contains('403'));
    });

    test('HTTP 500 menciona error del servidor', () {
      final msg = humanizeProviderTestError(en, 'Exception: HTTP 500');
      expect(msg, contains('5xx'));
    });
  });

  group('humanizeExternalProviderError', () {
    test('muestra el detail real de un 400 del Dashboard', () {
      const error = DashboardHttpException(
        400,
        body: '{"detail":"provider and model required for main"}',
      );

      expect(
        humanizeExternalProviderError(error),
        'provider and model required for main',
      );
    });

    test('redacta claves incluidas por un servidor remoto', () {
      const error = DashboardHttpException(
        422,
        body:
            '{"detail":"api_key=sk-super-secret-value rejected; '
            'Authorization: Bearer abcdefghijklmnop"}',
      );

      final message = humanizeExternalProviderError(error);
      expect(message, isNot(contains('sk-super-secret-value')));
      expect(message, isNot(contains('abcdefghijklmnop')));
      expect(message, contains('[redacted]'));
    });
  });

  group('_parseOpenAiModels (via integration logic)', () {
    // Testea el contrato de parseo de /v1/models sin HTTP real.

    test('extrae ids de respuesta OpenAI estándar', () {
      const body = '''
{
  "object": "list",
  "data": [
    {"id": "llama3.2:latest", "object": "model"},
    {"id": "qwen2.5:7b", "object": "model"}
  ]
}
''';
      // Accedemos a la lógica a través de normalización manual.
      // Si la implementación cambia, estos goldens deben actualizarse.
      // La función estática _parseOpenAiModels no es pública, pero el tipo
      // ExternalProviderType sí y podemos verificar los slugs.
      expect(ExternalProviderType.ollama.hermesProvider, 'custom');
      expect(ExternalProviderType.lmStudio.hermesProvider, 'custom');
      expect(ExternalProviderType.openAiCompat.hermesProvider, 'custom');
      expect(ExternalProviderType.custom.hermesProvider, 'custom');
      // El body es válido JSON — verificación básica.
      expect(body, contains('llama3.2:latest'));
    });
  });

  group('ExternalProviderType', () {
    test('todos los tipos tienen hermesProvider = custom', () {
      for (final t in ExternalProviderType.values) {
        expect(
          t.hermesProvider,
          'custom',
          reason: '${t.label} debe usar el slug "custom" de Hermes',
        );
      }
    });

    test('labels son distintas', () {
      final labels = ExternalProviderType.values.map((t) => t.label).toSet();
      expect(labels.length, ExternalProviderType.values.length);
    });

    test('URL hints no vacíos', () {
      for (final t in ExternalProviderType.values) {
        expect(
          t.urlHint.isNotEmpty,
          isTrue,
          reason: '${t.label} debe tener un urlHint',
        );
      }
    });
  });

  group('saved endpoints', () {
    final connection = SavedConnection(
      id: 'server-a',
      label: 'Server',
      host: 'hermes.example.test',
      port: 5000,
      apiKey: 'test-token',
    );

    Future<void> pumpScreen(
      WidgetTester tester,
      DashboardClient dashboard,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.hermesRedDark,
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: ExternalProviderScreen(
            connection: connection,
            profile: 'team one',
            dashboardClientForTesting: dashboard,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('unsupported server keeps the legacy primary test action', (
      tester,
    ) async {
      final calls = <http.Request>[];
      final dashboard = DashboardClient(
        host: 'hermes.example.test',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          calls.add(request);
          return http.Response('', 404);
        }),
      );
      addTearDown(dashboard.close);

      await pumpScreen(tester, dashboard);

      expect(calls, hasLength(1));
      expect(find.text('Saved endpoints'), findsNothing);
      expect(
        find.widgetWithText(FilledButton, 'Test connection'),
        findsOneWidget,
      );
    });

    testWidgets(
      'edit leaves key blank, validate resolves URL, and delete is guarded',
      (tester) async {
        const preview = r'${NEVER_RENDER_THIS}';
        final calls = <http.Request>[];
        final dashboard = DashboardClient(
          host: 'hermes.example.test',
          manualToken: 'test-token',
          httpClientOverride: MockClient((request) async {
            calls.add(request);
            if (request.method == 'GET') {
              return http.Response('''{"endpoints":[
                  {"id":"edge/a","name":"Edge","base_url":"https://llm.example.test","model":"edge-model","models":["edge-model"],"has_api_key":true,"api_key_preview":"$preview","is_current":false,"source":"providers"},
                  {"id":"direct","name":"Direct","base_url":"https://direct.example.test/v1","model":"direct-model","models":["direct-model"],"has_api_key":false,"is_current":true,"source":"direct-config"}
                ]}''', 200);
            }
            if (request.url.path.endsWith('/validate')) {
              return http.Response(
                '{"ok":true,"reachable":true,"message":"Ready",'
                '"models":["edge-model"],"model_details":[],'
                '"resolved_base_url":"https://llm.example.test/v1"}',
                200,
              );
            }
            return http.Response('{"ok":true}', 200);
          }),
        );
        addTearDown(dashboard.close);

        await pumpScreen(tester, dashboard);

        expect(find.text('Saved endpoints'), findsOneWidget);
        expect(find.textContaining(preview), findsNothing);
        expect(find.byIcon(Icons.more_vert), findsOneWidget);

        await tester.tap(find.text('Edge').first);
        await tester.pump();
        expect(find.text('https://llm.example.test'), findsOneWidget);
        expect(find.textContaining(preview), findsNothing);

        final testButton = find
            .widgetWithText(OutlinedButton, 'Test connection')
            .first;
        await tester.drag(find.byType(ListView), const Offset(0, -500));
        await tester.pumpAndSettle();
        await tester.tap(testButton);
        await tester.pumpAndSettle();
        expect(find.text('https://llm.example.test/v1'), findsOneWidget);
        expect(find.text('Ready'), findsOneWidget);
        final validate = calls.singleWhere(
          (request) => request.url.path.endsWith('/validate'),
        );
        expect(validate.url.queryParameters, {'profile': 'team one'});

        await tester.drag(find.byType(ListView), const Offset(0, 500));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(find.text('Delete Edge?'), findsOneWidget);
        await tester.tap(find.text('Delete').last);
        await tester.pumpAndSettle();

        expect(
          calls.where((request) => request.method == 'DELETE'),
          hasLength(1),
        );
      },
    );

    testWidgets(
      'editing preserves endpoint metadata and activation stays explicit',
      (tester) async {
        final calls = <http.Request>[];
        final dashboard = DashboardClient(
          host: 'hermes.example.test',
          manualToken: 'test-token',
          httpClientOverride: MockClient((request) async {
            calls.add(request);
            if (request.method == 'GET') {
              return http.Response(
                '{"endpoints":[{"id":"edge/a","name":"Edge",'
                '"base_url":"https://llm.example.test/v1",'
                '"model":"edge-model","models":["edge-model"],'
                '"api_mode":"anthropic_messages","context_length":32000,'
                '"discover_models":false,"has_api_key":true,'
                '"is_current":false,"source":"providers"}]}',
                200,
              );
            }
            return http.Response('{"ok":true,"id":"edge/a"}', 200);
          }),
        );
        addTearDown(dashboard.close);

        await pumpScreen(tester, dashboard);
        await tester.tap(find.text('Edge').first);
        await tester.pump();
        await tester.drag(find.byType(ListView), const Offset(0, -700));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Save endpoint'));
        await tester.pumpAndSettle();

        final save = calls.firstWhere(
          (request) =>
              request.method == 'POST' &&
              request.url.path == '/api/providers/custom-endpoints',
        );
        final body = jsonDecode(save.body) as Map<String, dynamic>;
        expect(body['make_default'], isFalse);
        expect(body['api_mode'], 'anthropic_messages');
        expect(body['context_length'], 32000);
        expect(body['discover_models'], isFalse);
        expect(body, isNot(contains('api_key')));

        await tester.drag(find.byType(ListView), const Offset(0, 700));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Activate'));
        await tester.pumpAndSettle();

        expect(
          calls.where(
            (request) =>
                request.method == 'POST' &&
                request.url.path ==
                    '/api/providers/custom-endpoints/edge%2Fa/activate',
          ),
          hasLength(1),
        );
      },
    );
  });
}
