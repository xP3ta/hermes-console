import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';
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

/// lm1215: the Models settings must recognise the configured default the way
/// Desktop does (slug → name → alias), keep the active card for local
/// endpoints on an on-device server, and name the model like the chat.
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

DashboardClient _dashboard({
  required Map<String, dynamic> info,
  required List<Map<String, dynamic>> providers,
}) => DashboardClient(
  host: 'hermes.local',
  port: 9119,
  manualToken: 'dashboard-token',
  httpClientOverride: MockClient((request) async {
    switch (request.url.path) {
      case '/api/model/info':
        return http.Response(jsonEncode(info), 200);
      case '/api/model/options':
        return http.Response(
          jsonEncode({
            'providers': providers,
            'model': info['model'],
            'provider': info['provider'],
          }),
          200,
        );
      case '/api/model/auxiliary':
        return http.Response(jsonEncode({'tasks': []}), 200);
    }
    return http.Response('not found', 404);
  }),
);

Future<void> _pump(
  WidgetTester tester, {
  required DashboardClient client,
  String host = 'hermes.example.net',
  InstanceKind? kind,
  DesktopModelCatalog? Function()? gatewayCatalog,
}) async {
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
        connection: SavedConnection(
          id: 'c1',
          label: 'Server',
          host: host,
          port: 8642,
          apiKey: 'k',
          kind: kind,
        ),
        dashboardClientForTesting: client,
        bridgeManagerForTesting: _NoBridge(),
        gatewayCatalogForTesting: gatewayCatalog,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> _ollamaRow({bool withAliases = true}) => {
  'slug': 'ollama-box',
  'name': 'Ollama box',
  'authenticated': true,
  'is_user_defined': true,
  'models': ['qwen3:8b', 'gemma4:e4b'],
  if (withAliases) 'aliases': ['ollama box', 'ollama-box', 'custom:ollama-box'],
};

HermesListRow _modelRow(WidgetTester tester, String id) => tester
    .widgetList<HermesListRow>(find.byType(HermesListRow))
    .firstWhere((row) => row.title == id);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('custom:<key> marks the alias row model as active', (
    tester,
  ) async {
    await _pump(
      tester,
      client: _dashboard(
        info: {
          'model': 'qwen3:8b',
          'provider': 'custom:ollama-box',
          'effective_context_length': 32768,
        },
        providers: [_ollamaRow()],
      ),
    );
    // The provider row itself is the current one.
    expect(find.text('Ollama box'), findsWidgets);
    await tester.tap(find.text('Ollama box').last);
    await tester.pumpAndSettle();
    expect(_modelRow(tester, 'qwen3:8b').selected, isTrue);
    expect(_modelRow(tester, 'gemma4:e4b').selected, isFalse);
    // The card names the provider row, not the raw config id.
    expect(
      find.byKey(const ValueKey('lm1215-active-provider')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('lm1215-active-provider')))
          .data,
      'Ollama box',
    );
  });

  testWidgets('without REST aliases the cached gateway catalog resolves it', (
    tester,
  ) async {
    final catalog = DesktopModelCatalog.fromJson({
      'providers': [
        {
          'slug': 'ollama-box',
          'name': 'Ollama box',
          'models': ['qwen3:8b'],
          'aliases': ['custom:ollama-box'],
        },
      ],
    });
    await _pump(
      tester,
      client: _dashboard(
        info: {'model': 'qwen3:8b', 'provider': 'custom:ollama-box'},
        providers: [_ollamaRow(withAliases: false)],
      ),
      gatewayCatalog: () => catalog,
    );
    await tester.tap(find.text('Ollama box').last);
    await tester.pumpAndSettle();
    expect(_modelRow(tester, 'qwen3:8b').selected, isTrue);
  });

  testWidgets('a different provider with the same model id is not active', (
    tester,
  ) async {
    await _pump(
      tester,
      client: _dashboard(
        info: {'model': 'qwen3:8b', 'provider': 'custom:other'},
        providers: [
          _ollamaRow(),
          {
            'slug': 'other',
            'name': 'Other',
            'authenticated': true,
            'models': ['qwen3:8b'],
            'aliases': ['custom:other', 'other'],
          },
        ],
      ),
    );
    await tester.tap(find.text('Ollama box').last);
    await tester.pumpAndSettle();
    expect(_modelRow(tester, 'qwen3:8b').selected, isFalse);
  });

  for (final provider in ['custom:ollama-box', 'lmstudio', 'llamacpp']) {
    testWidgets('on-device server keeps the active card for $provider', (
      tester,
    ) async {
      await _pump(
        tester,
        host: '127.0.0.1',
        kind: InstanceKind.localhost,
        client: _dashboard(
          info: {'model': 'qwen3:8b', 'provider': provider},
          providers: [
            _ollamaRow(),
            {
              'slug': 'lmstudio',
              'name': 'LM Studio',
              'authenticated': true,
              'models': ['qwen3:8b'],
            },
            {
              'slug': 'llamacpp',
              'name': 'Local (llama.cpp)',
              'authenticated': true,
              'models': ['qwen3:8b'],
            },
          ],
        ),
      );
      expect(find.text('MODELO ACTIVO'), findsOneWidget);
    });
  }

  testWidgets('on-device server still hides an unconfigured cloud default', (
    tester,
  ) async {
    await _pump(
      tester,
      host: '127.0.0.1',
      kind: InstanceKind.localhost,
      client: _dashboard(
        info: {'model': 'claude-opus-4.6', 'provider': 'anthropic'},
        providers: [
          _ollamaRow(),
          {
            'slug': 'anthropic',
            'name': 'Anthropic',
            'authenticated': true,
            'models': ['claude-opus-4.6'],
          },
        ],
      ),
    );
    expect(find.text('MODELO ACTIVO'), findsNothing);
  });

  testWidgets('the card uses the chat name and says it is the default', (
    tester,
  ) async {
    await _pump(
      tester,
      client: _dashboard(
        info: {
          'model': 'anthropic/claude-sonnet-4.6',
          'provider': 'openrouter',
        },
        providers: [
          {
            'slug': 'openrouter',
            'name': 'OpenRouter',
            'authenticated': true,
            'models': ['anthropic/claude-sonnet-4.6'],
          },
        ],
      ),
    );
    expect(find.text('Sonnet 4.6'), findsOneWidget);
    // The raw id stays available as secondary text.
    expect(find.text('anthropic/claude-sonnet-4.6'), findsWidgets);
    expect(find.text('Predeterminado para chats nuevos'), findsOneWidget);
  });
}
