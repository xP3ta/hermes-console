import 'support/official_http_audit.dart';

// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// No real Bridge, network, provisioning or SSH: every manager operation records
// its invocation locally. A needsToken result exercises the baseline trigger.

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('official model loads and refreshes without Bridge access', (
    tester,
  ) async {
    final bridge = OfficialHttpAudit();
    final requests = <String>[];
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'synthetic-fixture-token',
      httpClientOverride: bridge.client((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/model/info') {
          return http.Response(
            jsonEncode({'model': 'official-model', 'provider': 'fixture'}),
            200,
          );
        }
        if (request.url.path == '/api/model/options') {
          return http.Response(
            jsonEncode({
              'providers': [
                {
                  'slug': 'fixture',
                  'name': 'Fixture',
                  'authenticated': true,
                  'models': ['official-model'],
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/model/auxiliary') {
          return http.Response(jsonEncode({'tasks': []}), 200);
        }
        if (request.url.path == '/api/providers/oauth') {
          return http.Response(jsonEncode({'providers': []}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    tester.view.physicalSize = const Size(412, 1400);
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
            id: 'row55-fixture',
            label: 'Fixture',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'synthetic-fixture-token',
          ),
          dashboardClientForTesting: dashboard,

          gatewayCatalogForTesting: () => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fixture'), findsWidgets);
    expect(requests, contains('GET /api/model/info'));
    await tester.tap(find.byIcon(Icons.refresh).first);
    await tester.pumpAndSettle();
    expect(find.text('Fixture'), findsWidgets);
    expect(requests.where((s) => s == 'GET /api/model/info').length, 2);
    expect(
      bridge.calls,
      isEmpty,
      reason: 'Opening/refreshing Models must not probe or provision a Bridge',
    );
  });
}
