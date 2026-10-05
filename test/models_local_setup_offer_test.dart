import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/local_models_screen.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/local_models_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_local_models_server.dart';

/// Desktop's local-setup offer (NousResearch/hermes-agent #121969/#129506):
/// a "Run locally" row at the top of the model menu while the server's
/// hardware fits a catalog model and local models are not set up yet
/// (no runtime, or no staged model). Eligibility is read from
/// `GET /api/local-models/status` + `/catalog` on each open, never polled,
/// and nothing is installed or downloaded until the user taps the row.
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

DashboardClient _dashboard(FakeLocalModelsServer local) {
  final localClient = local.client;
  return DashboardClient(
    host: 'hermes.local',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((request) async {
      switch (request.url.path) {
        case '/api/model/info':
          return http.Response(
            jsonEncode({'model': 'gpt-5.5', 'provider': 'openrouter'}),
            200,
          );
        case '/api/model/options':
          return http.Response(
            jsonEncode({
              'providers': [
                {
                  'slug': 'openrouter',
                  'name': 'OpenRouter',
                  'authenticated': true,
                  'models': ['gpt-5.5'],
                },
              ],
            }),
            200,
          );
        case '/api/model/auxiliary':
          return http.Response(jsonEncode({'tasks': []}), 200);
      }
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..body = request.body;
      return localClient.send(copy).then(http.Response.fromStream);
    }),
  );
}

/// A server whose hardware fits the catalog but has nothing set up.
FakeLocalModelsServer _unsetServer() => FakeLocalModelsServer()
  ..runtimeInstalled = false
  ..serverRunning = false
  ..activeModelId = null
  ..models.clear()
  ..loaded.clear();

Map<String, Object?> _row(
  String id,
  String name, {
  Object? fits = true,
  bool recommended = false,
  String size = '9.0 GB',
}) => {
  'id': id,
  'display_name': name,
  'size_label': size,
  'recommended': recommended,
  'downloaded': false,
  'fits': ?fits,
  'needs_engine': false,
};

Future<void> _pump(WidgetTester tester, DashboardClient client) async {
  tester.view.physicalSize = const Size(412, 1600);
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

const _offer = ValueKey('lm-setup-offer');

int _reads(FakeLocalModelsServer local, String path) =>
    local.calls.where((c) => c.method == 'GET' && c.path == path).length;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('eligible server shows the offer at the top of Models', (
    tester,
  ) async {
    final local = _unsetServer();
    await _pump(tester, _dashboard(local));

    expect(find.byKey(_offer), findsOneWidget);
    expect(find.text('Ejecutar en local · gratis, privado'), findsOneWidget);
    expect(
      find.text('Qwen3 14B cabe en tu servidor · descarga de 9.0 GB'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(_offer),
        matching: find.text('Configurar'),
      ),
      findsOneWidget,
    );
    // Top of the screen: above the providers and the local models entry.
    final offerTop = tester.getTopLeft(find.byKey(_offer)).dy;
    for (final provider in find.text('OpenRouter').evaluate()) {
      final top = tester.getTopLeft(find.byWidget(provider.widget)).dy;
      expect(offerTop, lessThan(top));
    }
    expect(
      offerTop,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('lm1215-entry'))).dy,
      ),
    );
    // Offer only: nothing is installed, downloaded or activated by itself.
    expect(local.writes(), isEmpty);
  });

  testWidgets('runtime without staged models still qualifies', (tester) async {
    final local = _unsetServer()..runtimeInstalled = true;
    await _pump(tester, _dashboard(local));
    expect(find.byKey(_offer), findsOneWidget);
  });

  testWidgets('a set-up server shows no offer', (tester) async {
    final local = FakeLocalModelsServer();
    await _pump(tester, _dashboard(local));
    expect(find.byKey(_offer), findsNothing);
    // A set-up server never qualifies, so the catalog is not even read.
    expect(_reads(local, '/api/local-models/catalog'), 0);
  });

  testWidgets('staged models without a runtime still qualify', (tester) async {
    final local = FakeLocalModelsServer()..runtimeInstalled = false;
    await _pump(tester, _dashboard(local));
    expect(find.byKey(_offer), findsOneWidget);
  });

  testWidgets('a server without local-models routes hides the offer', (
    tester,
  ) async {
    final local = _unsetServer()..routesPresent = false;
    await _pump(tester, _dashboard(local));
    expect(find.byKey(_offer), findsNothing);
    expect(_reads(local, '/api/local-models/catalog'), 0);
  });

  testWidgets('nothing that fits means no offer', (tester) async {
    final local = _unsetServer()
      ..catalog = [
        _row('huge', 'Huge 405B', fits: false, recommended: true),
        // A catalog without the fit check proves nothing about the hardware.
        _row('legacy', 'Legacy 7B', fits: null),
      ];
    await _pump(tester, _dashboard(local));
    expect(find.byKey(_offer), findsNothing);
  });

  testWidgets('the recommended fitting model wins', (tester) async {
    final local = _unsetServer()
      ..catalog = [
        _row('big', 'Big 70B', fits: false, recommended: true),
        _row('small', 'Small 4B', size: '3.0 GB'),
        _row('mid', 'Mid 14B', recommended: true, size: '9.0 GB'),
      ];
    await _pump(tester, _dashboard(local));
    expect(
      find.text('Mid 14B cabe en tu servidor · descarga de 9.0 GB'),
      findsOneWidget,
    );
  });

  testWidgets('without a recommended fit, the first fitting model', (
    tester,
  ) async {
    final local = _unsetServer()
      ..catalog = [
        _row('big', 'Big 70B', fits: false, recommended: true),
        _row('small', 'Small 4B', size: '3.0 GB'),
        _row('mid', 'Mid 14B', size: '9.0 GB'),
      ];
    await _pump(tester, _dashboard(local));
    expect(
      find.text('Small 4B cabe en tu servidor · descarga de 3.0 GB'),
      findsOneWidget,
    );
  });

  testWidgets('tapping opens Local models; finishing setup retires the row', (
    tester,
  ) async {
    final local = _unsetServer();
    await _pump(tester, _dashboard(local));
    await tester.tap(find.byKey(_offer));
    await tester.pumpAndSettle();
    expect(find.byType(LocalModelsScreen), findsOneWidget);
    expect(local.writes(), isEmpty);

    // Set up on the server while the screen was open, then come back.
    local
      ..runtimeInstalled = true
      ..models.add({
        'id': 'Qwen3-14B-Q4_K_M',
        'size_bytes': 9 << 30,
        'size_label': '9.0 GB',
      });
    Navigator.of(tester.element(find.byType(LocalModelsScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(_offer), findsNothing);
  });

  testWidgets('eligibility is read on open, never polled', (tester) async {
    final local = _unsetServer();
    await _pump(tester, _dashboard(local));
    final status = _reads(local, '/api/local-models/status');
    final catalog = _reads(local, '/api/local-models/catalog');
    expect(catalog, 1);
    await tester.pump(const Duration(minutes: 2));
    await tester.pumpAndSettle();
    expect(_reads(local, '/api/local-models/status'), status);
    expect(_reads(local, '/api/local-models/catalog'), catalog);
  });

  test('pickLocalSetupFit mirrors Desktop', () {
    LocalModelsStatus status({required bool runtime, required int staged}) =>
        LocalModelsStatus.fromJson({
          'runtime_installed': runtime,
          'models': [
            for (var i = 0; i < staged; i++) {'id': 'm$i'},
          ],
        });
    final catalog = [
      LocalCatalogModel.fromJson(_row('a', 'A')),
      LocalCatalogModel.fromJson(_row('b', 'B', recommended: true)),
    ];
    expect(
      pickLocalSetupFit(status(runtime: false, staged: 0), catalog)?.id,
      'b',
    );
    expect(
      pickLocalSetupFit(status(runtime: true, staged: 1), catalog),
      isNull,
    );
    expect(
      pickLocalSetupFit(status(runtime: true, staged: 0), catalog)?.id,
      'b',
    );
    expect(
      pickLocalSetupFit(status(runtime: false, staged: 2), catalog)?.id,
      'b',
    );
    expect(
      pickLocalSetupFit(status(runtime: false, staged: 0), [
        LocalCatalogModel.fromJson(_row('x', 'X', fits: null)),
      ]),
      isNull,
    );
  });
}
