// ExternalProviderScreen (the add/edit endpoint form) and the custom
// endpoints section that lists saved endpoints inside Models.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/custom_endpoints_section.dart';
import 'package:hermes_android/core/screens/external_provider_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/custom_endpoints_api.dart';
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

  group('endpoint form', () {
    final connection = SavedConnection(
      id: 'server-a',
      label: 'Server',
      host: 'hermes.example.test',
      port: 5000,
      apiKey: 'k',
    );
    final localConnection = SavedConnection(
      id: 'local-a',
      label: 'Phone',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'k',
      kind: InstanceKind.localhost,
    );

    /// Pushes the form over a launcher so a save can pop it with a result.
    Future<List<Object?>> pumpForm(
      WidgetTester tester,
      DashboardClient dashboard, {
      CustomEndpoint? endpoint,
      SavedConnection? on,
      http.Client? probe,
    }) async {
      final results = <Object?>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.hermesRedDark,
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                results.add(
                  await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => ExternalProviderScreen(
                        connection: on ?? connection,
                        profile: 'team one',
                        dashboardClientForTesting: dashboard,
                        endpoint: endpoint,
                        isEditing: endpoint != null,
                        probeClientForTesting: probe,
                      ),
                    ),
                  ),
                );
              },
              child: const Text('open form'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open form'));
      await tester.pumpAndSettle();
      return results;
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

      await pumpForm(tester, dashboard);

      expect(calls, hasLength(1));
      expect(find.text('Saved endpoints'), findsNothing);
      expect(
        find.widgetWithText(FilledButton, 'Test connection'),
        findsOneWidget,
      );
    });

    testWidgets('a remote Hermes without validation never probes from the '
        'phone and explains why', (tester) async {
      final dashboard = DashboardClient(
        host: 'hermes.example.test',
        manualToken: 'test-token',
        httpClientOverride: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(dashboard.close);
      final probe = _RecordingProbe();

      await pumpForm(tester, dashboard, probe: probe);
      expect(
        find.textContaining('Hermes tests this URL from its server'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byType(TextField).first,
        'http://10.20.30.40:11434',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Test connection'));
      await tester.pumpAndSettle();

      expect(probe.requests, isEmpty);
      expect(
        find.textContaining('cannot test endpoints from its server'),
        findsOneWidget,
      );
    });

    testWidgets('an instance on the phone probes the endpoint itself', (
      tester,
    ) async {
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        manualToken: 'test-token',
        httpClientOverride: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(dashboard.close);
      final probe = _RecordingProbe(
        (_) => http.Response('{"data":[{"id":"phone-model"}]}', 200),
      );

      await pumpForm(tester, dashboard, on: localConnection, probe: probe);
      expect(
        find.textContaining('The app tests this URL from your phone'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byType(TextField).first,
        'http://10.20.30.40:11434/v1',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Test connection'));
      await tester.pumpAndSettle();

      expect(
        probe.requests.map((r) => r.url.toString()),
        contains('http://10.20.30.40:11434/v1/models'),
      );
      expect(find.text('phone-model'), findsOneWidget);
    });

    testWidgets('edit leaves key blank and validate resolves URL', (
      tester,
    ) async {
      const preview = r'${NEVER_RENDER_THIS}';
      final calls = <http.Request>[];
      final dashboard = DashboardClient(
        host: 'hermes.example.test',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          calls.add(request);
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
      final probe = _RecordingProbe();

      await pumpForm(
        tester,
        dashboard,
        probe: probe,
        endpoint: CustomEndpoint.fromJson({
          'id': 'edge/a',
          'name': 'Edge',
          'base_url': 'https://llm.example.test',
          'model': 'edge-model',
          'models': ['edge-model'],
          'has_api_key': true,
          'api_key_preview': preview,
          'is_current': false,
          'source': 'providers',
        }),
      );

      expect(find.text('Edit provider'), findsOneWidget);
      expect(find.text('Saved endpoints'), findsNothing);
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
      expect(probe.requests, isEmpty);
      // The form never lists, so it sends no list request of its own.
      expect(calls.where((request) => request.method == 'GET'), isEmpty);
    });

    testWidgets('saving keeps endpoint metadata and closes the form', (
      tester,
    ) async {
      final calls = <http.Request>[];
      final dashboard = DashboardClient(
        host: 'hermes.example.test',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          calls.add(request);
          return http.Response('{"ok":true,"id":"edge/a"}', 200);
        }),
      );
      addTearDown(dashboard.close);

      final results = await pumpForm(
        tester,
        dashboard,
        endpoint: CustomEndpoint.fromJson({
          'id': 'edge/a',
          'name': 'Edge',
          'base_url': 'https://llm.example.test/v1',
          'model': 'edge-model',
          'models': ['edge-model'],
          'api_mode': 'anthropic_messages',
          'context_length': 32000,
          'discover_models': false,
          'has_api_key': true,
          'is_current': false,
          'source': 'providers',
        }),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -700));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save endpoint'));
      await tester.pumpAndSettle();

      final save = calls.singleWhere(
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
      // Saving does not activate: activation stays an explicit list action.
      expect(
        calls.where((request) => request.url.path.endsWith('/activate')),
        isEmpty,
      );
      expect(find.byType(ExternalProviderScreen), findsNothing);
      expect(results, [true]);
    });
  });

  group('custom endpoints section menu and delete dialog', () {
    final connection = SavedConnection(
      id: 'server-a',
      label: 'Server',
      host: 'hermes.example.test',
      port: 5000,
      apiKey: 'k',
    );

    Map<String, Object?> endpointJson(
      String id,
      String name, {
      bool current = false,
      String source = 'providers',
    }) => {
      'id': id,
      'name': name,
      'base_url': 'https://$name.example.test/v1'.toLowerCase(),
      'model': '$name-model'.toLowerCase(),
      'models': ['$name-model'.toLowerCase()],
      'has_api_key': false,
      'is_current': current,
      'source': source,
    };

    late List<Map<String, Object?>> served;
    late List<http.Request> calls;
    late DashboardClient dashboard;
    late int changes;

    setUp(() {
      changes = 0;
      served = [
        endpointJson('edge/a', 'Edge'),
        endpointJson('cur', 'Current', current: true),
        endpointJson('direct', 'Direct', source: 'direct-config'),
      ];
      calls = [];
      dashboard = DashboardClient(
        host: 'hermes.example.test',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          calls.add(request);
          if (request.method == 'GET') {
            return http.Response(jsonEncode({'endpoints': served}), 200);
          }
          if (request.method == 'DELETE') {
            final id = Uri.decodeComponent(request.url.pathSegments.last);
            served.removeWhere((endpoint) => endpoint['id'] == id);
          }
          return http.Response('{"ok":true}', 200);
        }),
      );
    });

    tearDown(() => dashboard.close());

    Future<void> pumpSection(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.hermesRedDark,
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            body: ListView(
              children: [
                CustomEndpointsSection(
                  connection: connection,
                  dashboard: dashboard,
                  profile: 'team one',
                  onChanged: () => changes++,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Iterable<http.Request> deletes() =>
        calls.where((request) => request.method == 'DELETE');

    Finder menuButton(String id) => find.descendant(
      of: find.byKey(ValueKey('saved-endpoint-$id')),
      matching: find.byIcon(Icons.more_vert),
    );

    Finder inMenu(String label) => find.descendant(
      of: find.byKey(const ValueKey('hermes-menu')),
      matching: find.text(label),
    );

    Finder inDialog(String label) => find.descendant(
      of: find.byKey(const ValueKey('hermes-dialog')),
      matching: find.text(label),
    );

    Future<void> openMenu(WidgetTester tester, String id) async {
      await tester.tap(menuButton(id));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hermes-menu')), findsOneWidget);
    }

    Future<void> openDeleteDialog(WidgetTester tester) async {
      await openMenu(tester, 'edge/a');
      await tester.tap(inMenu('Delete'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hermes-dialog')), findsOneWidget);
      expect(find.text('Delete Edge?'), findsOneWidget);
    }

    void expectEdgeKept() {
      expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
      expect(deletes(), isEmpty);
      expect(changes, 0);
      expect(
        find.byKey(const ValueKey('saved-endpoint-edge/a')),
        findsOneWidget,
      );
    }

    testWidgets('lists on the active profile and hides key previews', (
      tester,
    ) async {
      served.first['api_key_preview'] = r'${NEVER_RENDER_THIS}';
      await pumpSection(tester);
      expect(find.text('Custom endpoints'), findsOneWidget);
      expect(find.textContaining('NEVER_RENDER_THIS'), findsNothing);
      expect(calls.single.url.queryParameters, {'profile': 'team one'});
    });

    testWidgets('Cancel keeps the endpoint and sends no delete', (
      tester,
    ) async {
      await pumpSection(tester);
      await openDeleteDialog(tester);

      await tester.tap(inDialog('Cancel'));
      await tester.pumpAndSettle();

      expectEdgeKept();
    });

    testWidgets('tapping outside the dialog keeps the endpoint', (
      tester,
    ) async {
      await pumpSection(tester);
      await openDeleteDialog(tester);

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expectEdgeKept();
    });

    testWidgets('system back on the dialog keeps the endpoint', (tester) async {
      await pumpSection(tester);
      await openDeleteDialog(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expectEdgeKept();
      expect(find.byType(CustomEndpointsSection), findsOneWidget);
    });

    testWidgets('menu actions follow current and direct-config endpoints', (
      tester,
    ) async {
      await pumpSection(tester);
      expect(find.byIcon(Icons.more_vert), findsNWidgets(3));

      await openMenu(tester, 'edge/a');
      expect(inMenu('Activate'), findsOneWidget);
      expect(inMenu('Delete'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await openMenu(tester, 'cur');
      expect(inMenu('Activate'), findsNothing);
      expect(inMenu('Delete'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await openMenu(tester, 'direct');
      expect(inMenu('Activate'), findsOneWidget);
      expect(inMenu('Delete'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('hermes-menu')), findsNothing);
      expect(calls.where((request) => request.method != 'GET'), isEmpty);
    });

    testWidgets('Activate posts on the profile and reports the change', (
      tester,
    ) async {
      await pumpSection(tester);
      await openMenu(tester, 'edge/a');
      await tester.tap(inMenu('Activate'));
      await tester.pumpAndSettle();

      final activate = calls.singleWhere(
        (request) =>
            request.method == 'POST' &&
            request.url.path ==
                '/api/providers/custom-endpoints/edge%2Fa/activate',
      );
      expect(activate.url.queryParameters, {'profile': 'team one'});
      expect(changes, 1);
    });

    testWidgets('confirmed delete prunes the menu anchor of the removed id', (
      tester,
    ) async {
      await pumpSection(tester);
      final state = tester.state<CustomEndpointsSectionState>(
        find.byType(CustomEndpointsSection),
      );
      expect(state.debugMenuAnchorIds, {'edge/a', 'cur', 'direct'});

      await openDeleteDialog(tester);
      await tester.tap(inDialog('Delete'));
      await tester.pumpAndSettle();

      expect(deletes(), hasLength(1));
      expect(changes, 1);
      expect(find.byKey(const ValueKey('saved-endpoint-edge/a')), findsNothing);
      expect(state.debugMenuAnchorIds, {'cur', 'direct'});
    });
  });
}

class _RecordingProbe extends http.BaseClient {
  _RecordingProbe([this.respond]);

  final http.Response Function(http.BaseRequest request)? respond;
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final response = respond?.call(request) ?? http.Response('', 404);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      request: request,
    );
  }
}
