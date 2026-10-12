import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/external_provider_screen.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Custom endpoints live inside Models, like Desktop's Settings → Providers
/// (apps/desktop/src/app/settings/providers-settings.tsx, the custom
/// endpoints tab). There is no separate "External provider" entry any more.

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
    // The "Hermes reaches these from its server" footer is gone (quiet UI):
    // the add-endpoint form keeps that explanation behind its (?) help.
    expect(
      find.byKey(const ValueKey('custom-endpoints-server-hint')),
      findsNothing,
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
}
