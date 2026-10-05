import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/external_provider_screen.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/provider_logo.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/provider_logo_probe.dart';

/// Models identifies every provider and model by its maker's monochrome
/// mark: provider rows, model rows inside them, the active model card and
/// saved custom endpoints, all through the one `resolveProviderLogo` lookup.
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

DashboardClient _client() => DashboardClient(
  host: 'hermes.example.test',
  port: 9119,
  manualToken: 'dashboard-token',
  httpClientOverride: MockClient((request) async {
    switch (request.url.path) {
      case '/api/model/info':
        return http.Response(
          jsonEncode({'model': 'claude-opus-4', 'provider': 'anthropic'}),
          200,
        );
      case '/api/model/options':
        return http.Response(
          jsonEncode({
            'providers': [
              {
                'slug': 'anthropic',
                'name': 'Anthropic',
                'authenticated': true,
                'is_current': true,
                'models': ['claude-opus-4'],
              },
              {
                'slug': 'openrouter',
                'name': 'OpenRouter',
                'authenticated': true,
                'models': ['openai/gpt-5', 'mystery-model'],
              },
            ],
          }),
          200,
        );
      case '/api/model/auxiliary':
        return http.Response(jsonEncode({'tasks': []}), 200);
      case '/api/providers/custom-endpoints':
        return http.Response(
          jsonEncode({
            'endpoints': [
              {
                'id': 'box',
                'name': 'Ollama box',
                'base_url': 'https://box.example.test/v1',
                'model': 'qwen3:8b',
                'models': ['qwen3:8b'],
                'has_api_key': false,
                'is_current': false,
                'source': 'providers',
              },
            ],
          }),
          200,
        );
    }
    return http.Response('not found', 404);
  }),
);

Future<void> _pump(WidgetTester tester, ThemeData theme) async {
  tester.view.physicalSize = const Size(412, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final client = _client();
  addTearDown(client.close);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: theme,
      home: ModelsScreen(
        connection: SavedConnection(
          id: 'c1',
          label: 'Server',
          host: 'hermes.example.test',
          port: 8642,
          apiKey: '',
          kind: InstanceKind.vps,
        ),
        dashboardClientForTesting: client,
        bridgeManagerForTesting: _NoBridge(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Iterable<ProviderLogo> _logosIn(WidgetTester tester, Finder scope) =>
    tester.widgetList<ProviderLogo>(
      find.descendant(of: scope, matching: find.byType(ProviderLogo)),
    );

Color _tintOf(WidgetTester tester, Finder logo) =>
    providerLogoTint(tester, logo);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (name, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('Models shows tinted provider logos everywhere ($name)', (
      tester,
    ) async {
      await _pump(tester, theme);
      final colors = theme.hermes;

      // Active card: the active model's maker, in the accent.
      final active = find.byKey(const ValueKey('provider-logo-active-model'));
      expect(active, findsOneWidget);
      expect(tester.widget<ProviderLogo>(active).spec.id, 'anthropic');
      expect(_tintOf(tester, active), colors.accent);

      // Provider rows.
      for (final (slug, id) in [
        ('anthropic', 'anthropic'),
        ('openrouter', 'openrouter'),
      ]) {
        final row = find.byKey(ValueKey('provider-logo-provider-$slug'));
        expect(row, findsOneWidget, reason: slug);
        expect(tester.widget<ProviderLogo>(row).spec.id, id);
        expect(_tintOf(tester, row), colors.textSecondary);
      }

      // Model rows inside a provider show the model's own maker.
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      final gpt = find.byKey(
        const ValueKey('provider-logo-model-openrouter-openai/gpt-5'),
      );
      expect(gpt, findsOneWidget);
      expect(tester.widget<ProviderLogo>(gpt).spec.id, 'openai');
      expect(_tintOf(tester, gpt), colors.textSecondary);
      final mystery = find.byKey(
        const ValueKey('provider-logo-model-openrouter-mystery-model'),
      );
      expect(tester.widget<ProviderLogo>(mystery).spec.id, 'openrouter');

      // Saved custom endpoints.
      final endpoint = _logosIn(
        tester,
        find.byKey(const ValueKey('saved-endpoint-box')),
      );
      expect(endpoint.map((l) => l.spec.id), ['ollama']);
    });
  }
}
