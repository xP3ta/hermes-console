// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The Mixture of Agents recipe belongs to a profile. Opened from the Models
// screen of profile "ana", every read and the save must go to "ana": the
// screen used to call the server unscoped, so it showed and overwrote the
// default profile's recipe whatever profile was on screen.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/moa_recipe_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the recipe is read and saved for the profile it was opened '
      'for', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <({String method, String path, String? profile})>[];
    final recipe = {
      'default_preset': 'default',
      'active_preset': '',
      'presets': {
        'default': {
          'reference_models': [
            {'provider': 'acme', 'model': 'acme-large'},
          ],
          'aggregator': {'provider': 'acme', 'model': 'acme-large'},
          'enabled': true,
        },
      },
    };
    final client = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'synthetic-fixture-token',
      httpClientOverride: MockClient((request) async {
        requests.add((
          method: request.method,
          path: request.url.path,
          profile: request.url.queryParameters['profile'],
        ));
        switch (request.url.path) {
          case '/api/model/moa':
            return http.Response(jsonEncode({...recipe, 'ok': true}), 200);
          case '/api/model/options':
            return http.Response(
              jsonEncode({
                'providers': [
                  {
                    'slug': 'acme',
                    'name': 'Acme',
                    'authenticated': true,
                    'models': ['acme-large'],
                  },
                ],
              }),
              200,
            );
          case '/api/model/info':
            return http.Response('{"model":"default","provider":"moa"}', 200);
        }
        return http.Response('{}', 404);
      }),
    );
    tester.view.physicalSize = const Size(412, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.hermesRedDark,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: MoaRecipeScreen(
          connection: SavedConnection(
            id: 'moa-fixture',
            label: 'Fixture',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'synthetic-connection-token',
          ),
          profile: 'ana',
          dashboardClientForTesting: client,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('acme-large'), findsWidgets);

    final save = find.byType(FilledButton);
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(requests.where((r) => r.method == 'PUT'), hasLength(1));
    expect(
      requests,
      everyElement(
        predicate<({String method, String path, String? profile})>(
          (r) => r.profile == 'ana',
          'is scoped to profile ana',
        ),
      ),
    );
  });
}
