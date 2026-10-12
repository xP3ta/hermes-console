// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The Dashboard client resends a write once after a 401 re-authentication.
// That resend must re-check the write authority the screen captured: a
// profile switch between the 401 and the resend retires the write instead of
// replaying it (provider keys, OAuth links and saved endpoints alike).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _connectionId = 'provider-write-guard';
const _endpointsPath = '/api/providers/custom-endpoints';

class _Transport {
  final requests = <http.Request>[];

  /// Runs when the first write is answered with 401, before the client
  /// decides whether to resend it.
  Future<void> Function()? onUnauthorized;
  var _answered401 = false;

  /// Providers whose credential was deleted: gone from the catalog, like on
  /// a real server.
  final _removed = <String>{};

  late final client = DashboardClient(
    host: 'guard.example.test',
    manualToken: 'synthetic-guard-identity',
    httpClientOverride: MockClient((request) async {
      requests.add(request);
      // The key check before a save changes nothing on the server.
      if (request.url.path == '/api/providers/validate') {
        return http.Response('{"ok":true,"reachable":false}', 200);
      }
      if (request.method != 'GET') {
        if (!_answered401) {
          _answered401 = true;
          await onUnauthorized?.call();
          return http.Response('{"detail":"expired"}', 401);
        }
        if (request.method == 'DELETE') {
          _removed.add(
            request.url.path == '/api/env'
                ? 'acme'
                : request.url.pathSegments.last,
          );
        }
        return http.Response('{"ok":true}', 200);
      }
      switch (request.url.path) {
        case '/api/env':
          return http.Response(
            jsonEncode({
              for (final (key, isSet) in [
                ('ACME_API_KEY', !_removed.contains('acme')),
                ('BETA_API_KEY', false),
              ])
                key: {
                  'is_set': isSet,
                  'category': 'provider',
                  'is_password': true,
                  'provider': key.split('_').first.toLowerCase(),
                  'provider_label': key == 'ACME_API_KEY' ? 'Acme' : 'Beta',
                  'provider_primary': true,
                },
            }),
            200,
          );
        case '/api/model/info':
          return http.Response('{"model":"zeta-1","provider":"zeta"}', 200);
        case '/api/model/options':
          return http.Response(
            jsonEncode({
              'providers': [
                if (!_removed.contains('acme'))
                  {
                    'slug': 'acme',
                    'name': 'Acme',
                    'authenticated': true,
                    'is_current': false,
                    'models': ['acme-1'],
                  },
                if (!_removed.contains('nous'))
                  {
                    'slug': 'nous',
                    'name': 'Nous',
                    'authenticated': true,
                    'is_current': false,
                    'models': ['nous-1'],
                  },
                {
                  'slug': 'beta',
                  'name': 'Beta',
                  'authenticated': false,
                  'is_current': false,
                  'auth_type': 'api_key',
                  'key_env': 'BETA_API_KEY',
                  'models': <String>[],
                },
              ],
            }),
            200,
          );
        case _endpointsPath:
          return http.Response(
            jsonEncode({
              'endpoints': [
                {
                  'id': 'ana-endpoint',
                  'name': 'ana endpoint',
                  'base_url': 'https://ana.example.test/v1',
                  'model': 'ana-model',
                  'models': ['ana-model'],
                  'has_api_key': false,
                  'is_current': false,
                  'source': 'providers',
                },
              ],
            }),
            200,
          );
        case '/api/config':
          return http.Response('{"fallback_providers":[]}', 200);
        case '/api/model/auxiliary':
          return http.Response('{"tasks":[]}', 200);
        case '/api/providers/oauth':
          return http.Response(
            jsonEncode({
              'providers': [
                {
                  'id': 'nous',
                  'name': 'Nous',
                  'flow': 'device_code',
                  'disconnectable': true,
                  'status': {'logged_in': !_removed.contains('nous')},
                },
              ],
            }),
            200,
          );
        default:
          return http.Response('{}', 404);
      }
    }),
  );

  Iterable<http.Request> get writes => requests.where(
    (r) => r.method != 'GET' && r.url.path != '/api/providers/validate',
  );
}

/// The profile a write targets: `?profile=` or, for `/api/env`, the body.
String? _profileOf(http.Request request) {
  final query = request.url.queryParameters['profile'];
  if (query != null) return query;
  if (request.body.isEmpty) return null;
  final body = jsonDecode(request.body);
  return body is Map ? body['profile'] as String? : null;
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
            label: 'Synthetic guard',
            host: 'guard.example.test',
            port: 8642,
            apiKey: 'synth...rd',
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

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target.first);
    await tester.pump();
    await tester.tap(target.first);
    await settle(tester);
  }

  Finder within(String key, String label) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.text(label),
  );

  // Each action reaches its first send with a valid profile; the 401 arrives
  // after the user switched profile, so the resend must not happen.
  final actions = <String, Future<void> Function(WidgetTester)>{
    'saving a provider key': (tester) async {
      await tap(tester, find.byKey(const ValueKey('models-unconfigured')));
      await tap(
        tester,
        find.byKey(const ValueKey('models-key-option-BETA_API_KEY')),
      );
      await tester.enterText(find.byType(TextField), 'synthetic-beta-key');
      await tester.pump();
      await tap(tester, find.text('Save'));
    },
    'removing an API key': (tester) async {
      await tap(
        tester,
        find.byKey(const ValueKey('configured-key-ACME_API_KEY')),
      );
      await tap(
        tester,
        find.byKey(const ValueKey('models-key-remove-ACME_API_KEY')),
      );
      await tap(tester, within('hermes-dialog', 'Remove'));
    },
    'disconnecting OAuth': (tester) async {
      await tap(tester, find.byKey(const ValueKey('models-account-nous')));
      await tap(
        tester,
        find.byKey(const ValueKey('models-account-disconnect-nous')),
      );
      await tap(tester, within('hermes-dialog', 'Remove'));
    },
    'activating an endpoint': (tester) async {
      await tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('saved-endpoint-ana-endpoint')),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tap(tester, within('hermes-menu', 'Activate'));
    },
    'deleting an endpoint': (tester) async {
      await tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('saved-endpoint-ana-endpoint')),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tap(tester, within('hermes-menu', 'Delete'));
      await tap(tester, within('hermes-dialog', 'Delete'));
    },
  };

  for (final MapEntry(key: name, value: act) in actions.entries) {
    testWidgets('$name is not resent after a 401 once the profile changed', (
      tester,
    ) async {
      final transport = _Transport()
        ..onUnauthorized = () => scope.switchTo('bob');
      await mount(tester, transport);
      await act(tester);
      expect(transport.writes, hasLength(1));
      expect(_profileOf(transport.writes.single), 'ana');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$name is still resent after a 401 with authority intact', (
      tester,
    ) async {
      final transport = _Transport();
      await mount(tester, transport);
      await act(tester);
      expect(transport.writes, hasLength(2));
      expect(_profileOf(transport.writes.last), 'ana');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
