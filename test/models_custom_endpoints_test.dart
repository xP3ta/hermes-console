import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/external_provider_screen.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Custom endpoints live inside Models, like Desktop's Settings → Providers
/// (apps/desktop/src/app/settings/providers-settings.tsx, the custom
/// endpoints tab). There is no separate "External provider" entry any more.
class _NoBridge implements BridgeManagerContract {
  @override
  Future<BridgeClient?> clientFor(String connectionId) async => null;
  @override
  Future<BridgeState> probe(String connectionId) async => BridgeState.unknown;
  @override
  Future<BridgeProvisionResult> provision(String connectionId) =>
      throw UnimplementedError();
  @override
  Future<bool> tryProvision(String connectionId) async => false;
}

Map<String, Object?> _endpoint(
  String id,
  String name, {
  bool current = false,
  String source = 'providers',
}) => {
  'id': id,
  'name': name,
  'base_url': 'https://${name.toLowerCase()}.example.test/v1',
  'model': '${name.toLowerCase()}-model',
  'models': ['${name.toLowerCase()}-model'],
  'has_api_key': false,
  'is_current': current,
  'source': source,
};

Map<String, Object?> _customRow({List<String> models = const ['qwen3:8b']}) => {
  'slug': 'custom:ollama-box',
  'name': 'Ollama box',
  'authenticated': true,
  'is_user_defined': true,
  'base_url': 'http://10.20.30.40:11434',
  'models': models,
};

class _Server {
  _Server({List<Map<String, Object?>>? endpoints, this.endpointsRoute = true})
    : endpoints =
          endpoints ??
          [
            _endpoint('edge/a', 'Edge'),
            _endpoint('cur', 'Current', current: true),
            _endpoint('direct', 'Direct', source: 'direct-config'),
          ];

  final List<Map<String, Object?>> endpoints;
  final bool endpointsRoute;
  final calls = <http.Request>[];

  DashboardClient client() => DashboardClient(
    host: 'hermes.example.test',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((request) async {
      calls.add(request);
      final path = request.url.path;
      if (path == '/api/model/info') {
        return http.Response(
          jsonEncode({'model': 'gpt-x', 'provider': 'openrouter'}),
          200,
        );
      }
      if (path == '/api/model/options') {
        final refreshed = request.url.queryParameters['refresh'] == '1';
        return http.Response(
          jsonEncode({
            'providers': [
              _customRow(
                models: refreshed
                    ? const ['qwen3:8b', 'server-refreshed:70b']
                    : const ['qwen3:8b'],
              ),
            ],
          }),
          200,
        );
      }
      if (path == '/api/model/auxiliary') {
        return http.Response(jsonEncode({'tasks': []}), 200);
      }
      if (endpointsRoute &&
          path.startsWith('/api/providers/custom-endpoints')) {
        if (request.method == 'GET') {
          return http.Response(jsonEncode({'endpoints': endpoints}), 200);
        }
        if (request.method == 'DELETE') {
          final id = Uri.decodeComponent(request.url.pathSegments.last);
          endpoints.removeWhere((endpoint) => endpoint['id'] == id);
        }
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('not found', 404);
    }),
  );

  Iterable<http.Request> where(String method, String path) => calls.where(
    (request) => request.method == method && request.url.path == path,
  );
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

Future<void> _pump(
  WidgetTester tester, {
  required DashboardClient client,
  InstanceKind kind = InstanceKind.vps,
  http.Client? probe,
  ActiveProfileScope? scope,
  SavedConnection? connection,
}) async {
  tester.view.physicalSize = const Size(412, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: ModelsScreen(
        connection:
            connection ??
            SavedConnection(
              id: 'c1',
              label: 'Server',
              host: 'hermes.example.test',
              port: 8642,
              apiKey: 'k',
              kind: kind,
            ),
        dashboardClientForTesting: client,
        bridgeManagerForTesting: _NoBridge(),
        probeClientForTesting: probe,
        profileScope: scope,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _menuButton(String id) => find.descendant(
  of: find.byKey(ValueKey('saved-endpoint-$id')),
  matching: find.byIcon(Icons.more_vert),
);

Finder _inMenu(String label) => find.descendant(
  of: find.byKey(const ValueKey('hermes-menu')),
  matching: find.text(label),
);

Finder _inDialog(String label) => find.descendant(
  of: find.byKey(const ValueKey('hermes-dialog')),
  matching: find.text(label),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Models lists saved custom endpoints and has no External '
      'provider entry', (tester) async {
    final server = _Server();
    final client = server.client();
    addTearDown(client.close);
    await _pump(tester, client: client);

    expect(
      find.byKey(const ValueKey('models-custom-endpoints')),
      findsOneWidget,
    );
    expect(find.text('Custom endpoints'), findsOneWidget);
    for (final id in ['edge/a', 'cur', 'direct']) {
      expect(find.byKey(ValueKey('saved-endpoint-$id')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('custom-endpoint-add')), findsOneWidget);
    expect(find.text('External provider'), findsNothing);
    expect(
      find.text('Remote Ollama · LM Studio · OpenAI-compatible'),
      findsNothing,
    );
    // Remote connection: say that Hermes reaches these from its server.
    expect(
      find.byKey(const ValueKey('custom-endpoints-server-hint')),
      findsOneWidget,
    );
  });

  testWidgets('activate from Models posts activate and reloads the screen', (
    tester,
  ) async {
    final server = _Server();
    final client = server.client();
    addTearDown(client.close);
    await _pump(tester, client: client);
    final infoBefore = server.where('GET', '/api/model/info').length;

    await tester.tap(_menuButton('edge/a'));
    await tester.pumpAndSettle();
    expect(_inMenu('Activate'), findsOneWidget);
    await tester.tap(_inMenu('Activate'));
    await tester.pumpAndSettle();

    expect(
      server.where('POST', '/api/providers/custom-endpoints/edge%2Fa/activate'),
      hasLength(1),
    );
    // The active model may have changed: Models reloads its own state too.
    expect(
      server.where('GET', '/api/model/info').length,
      greaterThan(infoBefore),
    );
  });

  testWidgets('delete from Models is guarded by the dialog', (tester) async {
    final server = _Server();
    final client = server.client();
    addTearDown(client.close);
    await _pump(tester, client: client);

    await tester.tap(_menuButton('edge/a'));
    await tester.pumpAndSettle();
    await tester.tap(_inMenu('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Edge?'), findsOneWidget);
    await tester.tap(_inDialog('Cancel'));
    await tester.pumpAndSettle();
    expect(server.calls.where((r) => r.method == 'DELETE'), isEmpty);

    await tester.tap(_menuButton('edge/a'));
    await tester.pumpAndSettle();
    await tester.tap(_inMenu('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(_inDialog('Delete'));
    await tester.pumpAndSettle();

    expect(server.calls.where((r) => r.method == 'DELETE'), hasLength(1));
    expect(find.byKey(const ValueKey('saved-endpoint-edge/a')), findsNothing);
  });

  testWidgets('Add endpoint opens the form and tapping a row edits it', (
    tester,
  ) async {
    final server = _Server();
    final client = server.client();
    addTearDown(client.close);
    await _pump(tester, client: client);

    await tester.tap(find.byKey(const ValueKey('custom-endpoint-add')));
    await tester.pumpAndSettle();
    final add = tester.widget<ExternalProviderScreen>(
      find.byType(ExternalProviderScreen),
    );
    expect(add.endpoint, isNull);
    expect(add.isEditing, isFalse);
    // The form no longer duplicates the saved list.
    expect(find.text('Saved endpoints'), findsNothing);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edge'));
    await tester.pumpAndSettle();
    final edit = tester.widget<ExternalProviderScreen>(
      find.byType(ExternalProviderScreen),
    );
    expect(edit.endpoint?.id, 'edge/a');
    expect(edit.isEditing, isTrue);
    expect(find.text('https://edge.example.test/v1'), findsOneWidget);
  });

  testWidgets('a server without the custom endpoints route still offers Add', (
    tester,
  ) async {
    final server = _Server(endpointsRoute: false);
    final client = server.client();
    addTearDown(client.close);
    await _pump(tester, client: client);

    expect(find.byKey(const ValueKey('custom-endpoint-add')), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });

  testWidgets('remote connection refreshes custom models through Hermes, '
      'never from the phone', (tester) async {
    final server = _Server();
    final client = server.client();
    addTearDown(client.close);
    final probe = _RecordingProbe(
      (_) => http.Response('{"data":[{"id":"phone-only"}]}', 200),
    );
    await _pump(tester, client: client, probe: probe);

    await tester.tap(find.text('Ollama box').first);
    await tester.pumpAndSettle();

    expect(probe.requests, isEmpty);
    expect(
      server.calls.where(
        (r) =>
            r.url.path == '/api/model/options' &&
            r.url.queryParameters['refresh'] == '1',
      ),
      hasLength(1),
    );
    expect(find.text('server-refreshed:70b'), findsOneWidget);
    expect(find.text('phone-only'), findsNothing);
  });

  testWidgets('a local instance on the phone still probes the endpoint', (
    tester,
  ) async {
    final server = _Server();
    final client = server.client();
    addTearDown(client.close);
    final probe = _RecordingProbe(
      (_) => http.Response('{"data":[{"id":"phone-model"}]}', 200),
    );
    await _pump(
      tester,
      client: client,
      probe: probe,
      kind: InstanceKind.localhost,
    );

    await tester.tap(find.text('Ollama box').first);
    await tester.pumpAndSettle();

    expect(
      probe.requests.map((r) => r.url.toString()),
      contains('http://10.20.30.40:11434/v1/models'),
    );
    expect(find.text('phone-model'), findsOneWidget);
  });

  group('profile', () {
    late ConnectionManager manager;
    late ActiveProfileScope scope;
    final connection = SavedConnection(
      id: 'c-profile',
      label: 'Server',
      host: 'hermes.example.test',
      port: 8642,
      apiKey: 'k',
      kind: InstanceKind.vps,
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final secure = <String, String>{};
      TestWidgetsFlutterBinding.ensureInitialized();
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              final args = (call.arguments as Map?) ?? {};
              switch (call.method) {
                case 'read':
                  return secure[args['key']];
                case 'write':
                  secure[args['key'] as String] = args['value'] as String;
                  return null;
                case 'delete':
                  secure.remove(args['key']);
                  return null;
                case 'readAll':
                  return Map<String, String>.from(secure);
                case 'containsKey':
                  return secure.containsKey(args['key']);
              }
              return null;
            },
          );
      manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await manager.setActiveProfile(connection.id, 'ana');
      scope = ActiveProfileScope.of(manager, connection.id);
    });

    testWidgets('Edit provider opens the form on the active profile', (
      tester,
    ) async {
      final server = _Server();
      final client = server.client();
      addTearDown(client.close);
      await _pump(tester, client: client, scope: scope, connection: connection);
      expect(
        server.calls
            .where((r) => r.url.path == '/api/providers/custom-endpoints')
            .first
            .url
            .queryParameters['profile'],
        'ana',
      );

      await tester.tap(find.text('Ollama box').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit provider'));
      await tester.pumpAndSettle();

      final form = tester.widget<ExternalProviderScreen>(
        find.byType(ExternalProviderScreen),
      );
      expect(form.profile, 'ana');
      expect(form.prefillUrl, 'http://10.20.30.40:11434');
    });
  });
}
