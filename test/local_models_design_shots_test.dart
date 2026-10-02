import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

import 'support/design_shots.dart';
import 'support/fake_local_models_server.dart';

/// lm1215 visual evidence at 412×915, Spanish, dark and light. Writes PNGs
/// only when `DESIGN_SHOTS_DIR` is set; otherwise it is a layout smoke test
/// (no overflow at phone width in either theme).
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

const _size = Size(412, 915);
const _key = ValueKey('lm1215-shot');

Future<void> _pump(WidgetTester tester, Widget home, ThemeData theme) async {
  await loadDesignFonts();
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: theme,
        home: home,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = Platform.environment['DESIGN_SHOTS_DIR'];
  if (dir == null || dir.isEmpty) return;
  await tester.pump(const Duration(milliseconds: 300));
  final boundary =
      tester.renderObject(find.byKey(_key)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

LocalModelsScreen _screen(FakeLocalModelsServer server) => LocalModelsScreen(
  connection: fakeConnection(),
  client: LocalModelsClient(fakeDashboard(server)),
  pollInterval: const Duration(hours: 1),
  pausedPollInterval: const Duration(hours: 1),
);

FakeLocalModelsServer _withDownload() {
  final server = FakeLocalModelsServer();
  server.jobs.add({
    'job_id': 'shot1',
    'kind': 'model-download',
    'target': 'Qwen3 14B (Q4_K_M)',
    'model_id': 'qwen3-14b',
    'status': 'running',
    'phase': 'downloading',
    'detail': 'Downloading Qwen3 14B',
    'total_bytes': 9 << 30,
    'done_bytes': (9 << 30) * 42 ~/ 100,
    'percent': 42,
    'can_pause': true,
    'can_resume': false,
  });
  return server;
}

DashboardClient _settingsDashboard(FakeLocalModelsServer local) {
  final localClient = local.client;
  return DashboardClient(
    host: 'hermes.local',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((request) async {
      switch (request.url.path) {
        case '/api/model/info':
          return http.Response(
            jsonEncode({
              'model': 'qwen3:8b',
              'provider': 'custom:ollama-box',
              'effective_context_length': 32768,
            }),
            200,
          );
        case '/api/model/options':
          return http.Response(
            jsonEncode({
              'providers': [
                {
                  'slug': 'ollama-box',
                  'name': 'Ollama box',
                  'authenticated': true,
                  'is_user_defined': true,
                  'models': ['qwen3:8b', 'gemma4:e4b'],
                  'aliases': ['custom:ollama-box', 'ollama-box'],
                },
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
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..body = request.body;
      return localClient.send(copy).then(http.Response.fromStream);
    }),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (mode, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('local models screen · $mode', (tester) async {
      await _pump(tester, _screen(_withDownload()), theme);
      expect(find.text('Qwen3-8B-Q4_K_M'), findsOneWidget);
      await _shot(tester, 'lm1215_local_models_$mode');
      await tester.drag(find.byType(ListView).first, const Offset(0, -700));
      await tester.pump(const Duration(milliseconds: 300));
      await _shot(tester, 'lm1215_local_models_catalog_$mode');
    });

    testWidgets('local models actions menu + delete confirm · $mode', (
      tester,
    ) async {
      await _pump(tester, _screen(FakeLocalModelsServer()), theme);
      await tester.tap(
        find.byKey(const ValueKey('lm1215-model-menu-Qwen3-8B-Q4_K_M')),
      );
      await tester.pumpAndSettle();
      await _shot(tester, 'lm1215_local_models_menu_$mode');
      await tester.tap(find.byKey(const ValueKey('lm1215-action-delete')));
      await tester.pumpAndSettle();
      await _shot(tester, 'lm1215_local_models_delete_$mode');
    });

    testWidgets('local models unavailable · $mode', (tester) async {
      await _pump(
        tester,
        _screen(FakeLocalModelsServer(routesPresent: false)),
        theme,
      );
      expect(find.byKey(const ValueKey('lm1215-unavailable')), findsOneWidget);
      await _shot(tester, 'lm1215_local_models_unavailable_$mode');
    });

    testWidgets('hugging face search · $mode', (tester) async {
      final server = FakeLocalModelsServer();
      await _pump(
        tester,
        LocalModelsSearchScreen(
          client: LocalModelsClient(fakeDashboard(server)),
        ),
        theme,
      );
      await tester.enterText(
        find.byKey(const ValueKey('lm1215-search-field')),
        'qwen3 4b',
      );
      await tester.tap(find.byKey(const ValueKey('lm1215-search-go')));
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await _shot(tester, 'lm1215_hf_search_$mode');
      await tester.tap(
        find.byKey(const ValueKey('lm1215-hit-unsloth/Qwen3-4B-GGUF')),
      );
      await tester.pumpAndSettle();
      await _shot(tester, 'lm1215_hf_files_$mode');
    });

    testWidgets('models settings active card + entry · $mode', (tester) async {
      await _pump(
        tester,
        ModelsScreen(
          connection: fakeConnection(),
          dashboardClientForTesting: _settingsDashboard(
            FakeLocalModelsServer(),
          ),
          bridgeManagerForTesting: _NoBridge(),
          gatewayCatalogForTesting: () => null,
        ),
        theme,
      );
      await tester.pumpAndSettle();
      expect(find.text('Predeterminado para chats nuevos'), findsOneWidget);
      await _shot(tester, 'lm1215_settings_models_$mode');
    });
  }
}
