import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/external_provider_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_local_models_server.dart';

/// Desktop #122920: an endpoint that answers but advertises no models at
/// /v1/models (auth-gated gateways, Cohere's compatibility API) reveals a
/// manual model-name input instead of dead-ending; the endpoint is saved
/// with that name, and saving stays disabled until it is filled.
class _Server {
  _Server({this.models = const []});

  final List<String> models;
  final saves = <Map<String, dynamic>>[];

  DashboardClient client() => DashboardClient(
    host: 'hermes.example.test',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/providers/custom-endpoints/validate') {
        return http.Response(
          jsonEncode({
            'ok': true,
            'reachable': true,
            'message': '',
            'models': models,
            'model_details': [],
            'resolved_base_url': 'https://gw.example.test/v1',
          }),
          200,
        );
      }
      if (path == '/api/providers/custom-endpoints') {
        if (request.method == 'GET') {
          return http.Response(jsonEncode({'endpoints': []}), 200);
        }
        saves.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('not found', 404);
    }),
  );
}

Future<void> _pump(WidgetTester tester, _Server server) async {
  tester.view.physicalSize = const Size(412, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: ExternalProviderScreen(
        connection: fakeConnection(),
        dashboardClientForTesting: server.client(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byType(TextField).first,
    'https://gw.example.test/v1',
  );
  await tester.tap(find.text('Probar conexión'));
  await tester.pumpAndSettle();
}

const _manual = ValueKey('ext-manual-model');

ButtonStyleButton _save(WidgetTester tester) => tester.widget<ButtonStyleButton>(
  find.ancestor(
    of: find.text('Guardar endpoint'),
    matching: find.bySubtype<ButtonStyleButton>(),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('empty discovery reveals the model name and saves it', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server);

    expect(find.byKey(_manual), findsOneWidget);
    expect(_save(tester).enabled, isFalse);

    await tester.enterText(
      find.descendant(of: find.byKey(_manual), matching: find.byType(TextField)),
      '  command-r-plus ',
    );
    await tester.pumpAndSettle();
    expect(_save(tester).enabled, isTrue);
    await tester.tap(find.text('Guardar endpoint'));
    await tester.pumpAndSettle();

    expect(server.saves, hasLength(1));
    expect(server.saves.single['model'], 'command-r-plus');
    expect(server.saves.single['base_url'], 'https://gw.example.test/v1');
  });

  testWidgets('discovered models keep the list and no manual input', (
    tester,
  ) async {
    final server = _Server(models: const ['gpt-oss-20b']);
    await _pump(tester, server);
    expect(find.byKey(_manual), findsNothing);
    expect(find.text('gpt-oss-20b'), findsOneWidget);
    expect(_save(tester).enabled, isTrue);
  });
}
