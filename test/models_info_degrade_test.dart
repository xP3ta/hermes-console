// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// Desktop's model settings degrade per call (Promise.allSettled): a failed or
// hung `/api/model/info` (its context-length probe reaches the configured
// provider) does not take the inventory down, and the main model comes from
// the auxiliary config read instead. Console failed the whole screen.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart'
    show friendlyModelName;
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _connectionId = 'models-info-degrade';

class _Transport {
  /// Per-profile `/api/model/info` answers; a held completer delays it.
  final infoGates = <String, Completer<void>>{};
  bool infoFails = true;
  bool optionsFail = false;
  final requests = <http.Request>[];

  late final client = DashboardClient(
    host: 'degrade.example.test',
    manualToken: 'synthetic-degrade-identity',
    httpClientOverride: MockClient((request) async {
      requests.add(request);
      final profile = request.url.queryParameters['profile'] ?? 'default';
      switch (request.url.path) {
        case '/api/model/info':
          await infoGates[profile]?.future;
          if (infoFails) return http.Response('{"detail":"probe"}', 502);
          return http.Response(
            jsonEncode({'model': '$profile-live', 'provider': 'acme'}),
            200,
          );
        case '/api/model/options':
          if (optionsFail) return http.Response('{"detail":"busy"}', 503);
          return http.Response(
            jsonEncode({
              'providers': [
                {
                  'slug': 'acme',
                  'name': 'Acme',
                  'authenticated': true,
                  'is_current': true,
                  'auth_type': 'api_key',
                  'key_env': 'ACME_API_KEY',
                  'models': ['$profile-main', '$profile-live'],
                },
              ],
            }),
            200,
          );
        case '/api/model/auxiliary':
          return http.Response(
            jsonEncode({
              'tasks': <Object>[],
              'main': {'provider': 'acme', 'model': '$profile-main'},
            }),
            200,
          );
        case '/api/env':
          return http.Response('{}', 200);
        case '/api/providers/custom-endpoints':
          return http.Response('{"endpoints":[]}', 200);
        case '/api/config':
          return http.Response('{"fallback_providers":[]}', 200);
        case '/api/providers/oauth':
          return http.Response('{"providers":[]}', 200);
        default:
          return http.Response('{}', 404);
      }
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConnectionManager manager;
  late ActiveProfileScope scope;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.setActiveProfile(_connectionId, 'ana');
    scope = ActiveProfileScope.of(manager, _connectionId);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> mount(WidgetTester tester, _Transport transport) async {
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.hermesRedDark,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: ModelsScreen(
          connection: SavedConnection(
            id: _connectionId,
            label: 'Synthetic degrade',
            host: 'degrade.example.test',
            port: 8642,
            apiKey: 'synth...de',
            kind: InstanceKind.vps,
          ),
          profileScope: scope,
          dashboardClientForTesting: transport.client,
          gatewayCatalogForTesting: () => null,
        ),
      ),
    );
    await settle(tester);
  }

  String? activeModel(WidgetTester tester) {
    final finder = find.byKey(const ValueKey('lm1215-active-model'));
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<Text>(finder).data;
  }

  testWidgets('a failed model/info keeps the inventory and the main model', (
    tester,
  ) async {
    final transport = _Transport();
    await mount(tester, transport);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Acme'), findsWidgets);
    expect(activeModel(tester), friendlyModelName('ana-main'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a live model/info still wins over the auxiliary main', (
    tester,
  ) async {
    final transport = _Transport()..infoFails = false;
    await mount(tester, transport);
    expect(activeModel(tester), friendlyModelName('ana-live'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a late model/info for the previous profile never lands', (
    tester,
  ) async {
    final transport = _Transport()
      ..infoFails = false
      ..infoGates['ana'] = Completer<void>();
    await mount(tester, transport);
    await scope.switchTo('bob');
    await settle(tester);
    transport.infoGates['ana']!.complete();
    await settle(tester);
    expect(activeModel(tester), friendlyModelName('bob-live'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed catalog keeps the live main model on screen', (
    tester,
  ) async {
    final transport = _Transport()
      ..infoFails = false
      ..optionsFail = true;
    await mount(tester, transport);
    expect(find.text('Retry'), findsOneWidget);
    expect(activeModel(tester), friendlyModelName('ana-live'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed catalog keeps the auxiliary main as fallback', (
    tester,
  ) async {
    final transport = _Transport()..optionsFail = true;
    await mount(tester, transport);
    expect(find.text('Retry'), findsOneWidget);
    expect(activeModel(tester), friendlyModelName('ana-main'));
    await tester.pumpWidget(const SizedBox());
  });
}
