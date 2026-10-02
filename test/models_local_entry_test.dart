import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/local_models_screen.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_local_models_server.dart';

/// lm1215: the Models settings entry to the server local models is gated by
/// `GET /api/local-models/status` (Desktop shows the surface only in local
/// mode; Console can only probe the route).
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

DashboardClient _dashboard(FakeLocalModelsServer local, {int statusCode = 0}) {
  final localClient = local.client;
  return DashboardClient(
    host: 'hermes.local',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((request) async {
      switch (request.url.path) {
        case '/api/model/info':
          return http.Response(
            jsonEncode({'model': 'Qwen3-8B-Q4_K_M', 'provider': 'llamacpp'}),
            200,
          );
        case '/api/model/options':
          return http.Response(
            jsonEncode({
              'providers': [
                {
                  'slug': 'llamacpp',
                  'name': 'Local (llama.cpp)',
                  'authenticated': true,
                  'models': ['Qwen3-8B-Q4_K_M'],
                },
              ],
            }),
            200,
          );
        case '/api/model/auxiliary':
          return http.Response(jsonEncode({'tasks': []}), 200);
      }
      if (statusCode != 0 && request.url.path == '/api/local-models/status') {
        return http.Response(jsonEncode({'detail': 'boom'}), statusCode);
      }
      // A MockClient request is already finalized: forward a copy.
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..body = request.body;
      return localClient.send(copy).then(http.Response.fromStream);
    }),
  );
}

Future<void> _pump(WidgetTester tester, DashboardClient client) async {
  tester.view.physicalSize = const Size(412, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: ModelsScreen(
        connection: fakeConnection(),
        dashboardClientForTesting: client,
        bridgeManagerForTesting: _NoBridge(),
        gatewayCatalogForTesting: () => null,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

HermesListRow _entry(WidgetTester tester) =>
    tester.widget<HermesListRow>(find.byKey(const ValueKey('lm1215-entry')));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('entry is enabled with a count and opens the screen', (
    tester,
  ) async {
    final local = FakeLocalModelsServer();
    await _pump(tester, _dashboard(local));
    final entry = _entry(tester);
    expect(entry.enabled, isTrue);
    expect(entry.subtitle, '2 modelos descargados');
    await tester.tap(find.byKey(const ValueKey('lm1215-entry')));
    await tester.pumpAndSettle();
    expect(find.byType(LocalModelsScreen), findsOneWidget);
    expect(find.text('Qwen3-8B-Q4_K_M'), findsWidgets);
  });

  testWidgets('404 disables the entry with the honest copy', (tester) async {
    final local = FakeLocalModelsServer(routesPresent: false);
    await _pump(tester, _dashboard(local));
    final entry = _entry(tester);
    expect(entry.enabled, isFalse);
    expect(entry.onTap, isNull);
    expect(
      entry.subtitle,
      'Tu Hermes no tiene modelos locales activados (modo local de Desktop)',
    );
    await tester.tap(find.byKey(const ValueKey('lm1215-entry')));
    await tester.pumpAndSettle();
    expect(find.byType(LocalModelsScreen), findsNothing);
    expect(local.writes(), isEmpty);
  });

  testWidgets('a transient error keeps the entry openable to retry', (
    tester,
  ) async {
    final local = FakeLocalModelsServer();
    await _pump(tester, _dashboard(local, statusCode: 500));
    final entry = _entry(tester);
    expect(entry.enabled, isTrue);
    expect(
      entry.subtitle,
      'No se pudo comprobar. Toca para abrir y reintentar',
    );
  });
}
