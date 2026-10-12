// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/external_provider_screen.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  for (final inventory in [
    'valid',
    'empty',
    'http-error',
    'timeout',
    'pending',
  ]) {
    testWidgets('provider creation entry survives $inventory inventory', (
      tester,
    ) async {
      final pending = Completer<http.Response>();
      final requests = <http.Request>[];
      final client = DashboardClient(
        host: 'server.example.test',
        manualToken: 'synthetic-dashboard-identity',
        httpClientOverride: MockClient((request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/api/model/info':
              return http.Response(
                '{"model":"fixture-model","provider":"custom"}',
                200,
              );
            case '/api/model/options':
              if (inventory == 'pending') return pending.future;
              if (inventory == 'timeout') {
                throw TimeoutException('synthetic inventory timeout');
              }
              if (inventory == 'http-error') return http.Response('{}', 503);
              return http.Response(
                jsonEncode({
                  'providers': inventory == 'empty'
                      ? []
                      : [
                          {
                            'slug': 'custom',
                            'name': 'Synthetic provider',
                            'authenticated': true,
                            'models': ['fixture-model'],
                          },
                        ],
                }),
                200,
              );
            case '/api/providers/custom-endpoints':
              return http.Response('{"endpoints":[]}', 200);
            case '/api/config':
              return http.Response('{"fallback_providers":[]}', 200);
            case '/api/model/auxiliary':
              return http.Response('{"tasks":[]}', 200);
            case '/api/providers/oauth':
              return http.Response('{"providers":[]}', 200);
            default:
              return http.Response('{}', 404);
          }
        }),
      );
      tester.view.physicalSize = const Size(412, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.hermesRedDark,
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: ModelsScreen(
            connection: SavedConnection(
              id: 'entry-fixture',
              label: 'Fixture',
              host: 'server.example.test',
              port: 8642,
              apiKey: 'synthetic-gateway-identity',
              kind: InstanceKind.vps,
            ),
            dashboardClientForTesting: client,
            gatewayCatalogForTesting: () => null,
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (inventory == 'timeout' || inventory == 'http-error') {
        await tester.pump(const Duration(seconds: 16));
        await tester.pump();
      }
      expect(
        requests.where((r) => r.url.path == '/api/model/info'),
        isNotEmpty,
      );
      expect(
        requests.where((r) => r.url.path == '/api/model/options'),
        isNotEmpty,
      );
      final entry = find.byKey(const ValueKey('custom-endpoint-add'));
      expect(entry, findsOneWidget);
      await tester.ensureVisible(entry);
      await tester.pump();
      expect(entry.hitTestable(), findsOneWidget);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(ExternalProviderScreen), findsOneWidget);
      expect(
        requests.where((r) => r.method != 'GET'),
        isEmpty,
        reason:
            'Opening the real provider form must not create or activate anything',
      );
      await tester.pumpWidget(const SizedBox());
      if (!pending.isCompleted) {
        pending.complete(http.Response('{"providers":[]}', 200));
      }
      await tester.pumpAndSettle();
    });
  }
}
