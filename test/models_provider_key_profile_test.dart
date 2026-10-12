// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// Provider API keys and OAuth links belong to the profile whose Models screen
// the user acted on. Without an explicit profile the Dashboard writes to its
// default profile, so every write must carry the owner captured before the
// key screen or the confirmation opened, and a profile switch (including
// A→B→A) while either is open must void the write (Desktop `setEnvVar`,
// `deleteEnvVar(key, profile)`, `disconnectOAuthProvider(id, profile)`).
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

const _connectionId = 'provider-key-profile';

class _Transport {
  final requests = <http.Request>[];

  /// Providers whose credential was deleted: gone from the catalog, like on
  /// a real server.
  final _removed = <String>{};

  late final client = DashboardClient(
    host: 'keys.example.test',
    manualToken: 'synthetic-key-identity',
    httpClientOverride: MockClient((request) async {
      requests.add(request);
      if (request.method != 'GET') {
        if (request.method == 'DELETE') {
          _removed.add(
            request.url.path == '/api/env'
                ? 'acme'
                : request.url.pathSegments.last,
          );
        }
        return http.Response('{"ok":true,"found":true}', 200);
      }
      switch (request.url.path) {
        case '/api/env':
          return http.Response(
            jsonEncode(_keys(acme: !_removed.contains('acme'))),
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
        case '/api/providers/custom-endpoints':
          return http.Response('{"endpoints":[]}', 200);
        case '/api/config':
          return http.Response('{"fallback_providers":[]}', 200);
        case '/api/model/auxiliary':
          return http.Response('{"tasks":[]}', 200);
        case '/api/providers/oauth':
          return http.Response(
            jsonEncode(_accounts(nous: !_removed.contains('nous'))),
            200,
          );
        default:
          return http.Response('{}', 404);
      }
    }),
  );

  /// What changes the server: the key check before a save changes nothing.
  Iterable<http.Request> get writes => requests.where(
    (r) => r.method != 'GET' && r.url.path != '/api/providers/validate',
  );
}

/// `GET /api/env`: Acme's key is set until it is removed, Beta's is not.
Map<String, dynamic> _keys({required bool acme}) => {
  for (final (key, isSet) in [('ACME_API_KEY', acme), ('BETA_API_KEY', false)])
    key: {
      'is_set': isSet,
      'category': 'provider',
      'is_password': true,
      'provider': key.split('_').first.toLowerCase(),
      'provider_label': key == 'ACME_API_KEY' ? 'Acme' : 'Beta',
      'provider_primary': true,
    },
};

/// `GET /api/providers/oauth`: Nous is signed in until it is signed out.
Map<String, dynamic> _accounts({required bool nous}) => {
  'providers': [
    {
      'id': 'nous',
      'name': 'Nous',
      'flow': 'device_code',
      'disconnectable': true,
      'status': {'logged_in': nous},
    },
  ],
};

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

  SavedConnection connection({bool readOnly = false}) => SavedConnection(
    id: _connectionId,
    label: 'Synthetic keys',
    host: 'keys.example.test',
    port: 8642,
    apiKey: 'synth...ys',
    kind: InstanceKind.vps,
    readOnly: readOnly,
  );

  late ValueNotifier<SavedConnection> shown;

  Future<void> mount(WidgetTester tester, _Transport transport) async {
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    shown = ValueNotifier(connection());
    addTearDown(shown.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.hermesRedDark,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: ValueListenableBuilder<SavedConnection>(
          valueListenable: shown,
          builder: (context, value, child) => ModelsScreen(
            connection: value,
            profileScope: scope,
            dashboardClientForTesting: transport.client,
            gatewayCatalogForTesting: () => null,
          ),
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

  /// The destructive action of the open confirmation.
  Finder dialogButton(String _) => find.descendant(
    of: find.byKey(const ValueKey('hermes-dialog')),
    matching: find.text('Remove'),
  );

  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> openKeyScreen(WidgetTester tester) async {
    if (key('models-key-option-BETA_API_KEY').evaluate().isEmpty) {
      await tap(tester, key('models-unconfigured'));
    }
    await tap(tester, key('models-key-option-BETA_API_KEY'));
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'synthetic-beta-key');
    await tester.pump();
  }

  Future<void> openDisconnect(WidgetTester tester, String provider) async {
    if (provider == 'Nous') {
      await tap(tester, key('models-account-nous'));
      await tap(tester, key('models-account-disconnect-nous'));
    } else {
      await tap(tester, key('configured-key-ACME_API_KEY'));
      await tap(tester, key('models-key-remove-ACME_API_KEY'));
    }
    expect(find.byKey(const ValueKey('hermes-dialog')), findsOneWidget);
  }

  Future<void> switchAway(WidgetTester tester) async {
    await scope.switchTo('bob');
    await settle(tester);
    await scope.switchTo('ana');
    await settle(tester);
  }

  testWidgets('saving a provider key writes it to the acting profile', (
    tester,
  ) async {
    final transport = _Transport();
    await mount(tester, transport);
    await openKeyScreen(tester);
    await tap(tester, find.text('Save'));
    final put = transport.writes.single;
    expect(put.method, 'PUT');
    expect(put.url.path, '/api/env');
    final body = jsonDecode(put.body) as Map<String, dynamic>;
    expect(body['key'], 'BETA_API_KEY');
    expect(body['profile'], 'ana');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('removing an API key deletes it from the acting profile', (
    tester,
  ) async {
    final transport = _Transport();
    await mount(tester, transport);
    await openDisconnect(tester, 'Acme');
    await tap(tester, dialogButton('Disconnect'));
    final deletion = transport.writes.single;
    expect(deletion.method, 'DELETE');
    expect(deletion.url.path, '/api/env');
    expect(deletion.url.queryParameters['profile'], 'ana');
    final body = jsonDecode(deletion.body) as Map<String, dynamic>;
    expect(body['key'], 'ACME_API_KEY');
    expect(body['profile'], 'ana');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disconnecting OAuth targets the acting profile', (tester) async {
    final transport = _Transport();
    await mount(tester, transport);
    await openDisconnect(tester, 'Nous');
    await tap(tester, dialogButton('Disconnect'));
    final deletion = transport.writes.single;
    expect(deletion.method, 'DELETE');
    expect(deletion.url.path, '/api/providers/oauth/nous');
    expect(deletion.url.queryParameters['profile'], 'ana');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a profile switch while the key screen is open voids the save', (
    tester,
  ) async {
    final transport = _Transport();
    await mount(tester, transport);
    await openKeyScreen(tester);
    await switchAway(tester);
    await tap(tester, find.text('Save'));
    expect(transport.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final provider in ['Acme', 'Nous']) {
    testWidgets(
      'a profile switch while the $provider confirmation is open voids it',
      (tester) async {
        final transport = _Transport();
        await mount(tester, transport);
        await openDisconnect(tester, provider);
        await switchAway(tester);
        await tap(tester, dialogButton('Disconnect'));
        expect(transport.writes, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  // Write authority is re-checked when the queued write is about to be sent:
  // the connection turning read-only (same id and profile) while the key
  // screen or a confirmation is open revokes it.
  Future<void> revoke(WidgetTester tester) async {
    shown.value = connection(readOnly: true);
    await settle(tester);
  }

  testWidgets('revoking write access while the key screen is open voids it', (
    tester,
  ) async {
    final transport = _Transport();
    await mount(tester, transport);
    await openKeyScreen(tester);
    await revoke(tester);
    await tap(tester, find.text('Save'));
    expect(transport.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final provider in ['Acme', 'Nous']) {
    testWidgets(
      'revoking write access while the $provider confirmation is open voids it',
      (tester) async {
        final transport = _Transport();
        await mount(tester, transport);
        await openDisconnect(tester, provider);
        await revoke(tester);
        await tap(tester, dialogButton('Disconnect'));
        expect(transport.writes, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('a rebuilt copy of the same writable connection keeps the save', (
    tester,
  ) async {
    final transport = _Transport();
    await mount(tester, transport);
    await openKeyScreen(tester);
    shown.value = connection();
    await settle(tester);
    await tap(tester, find.text('Save'));
    final put = transport.writes.single;
    expect(put.method, 'PUT');
    expect((jsonDecode(put.body) as Map<String, dynamic>)['profile'], 'ana');
    await tester.pumpWidget(const SizedBox());
  });

  // Write access revoked and then restored (same id and profile) while the
  // action is open must not revive the retired intent; a new action may.
  Future<void> revokeAndRestore(WidgetTester tester) async {
    await revoke(tester);
    shown.value = connection();
    await settle(tester);
  }

  testWidgets('restored write access does not revive a retired key save', (
    tester,
  ) async {
    final transport = _Transport();
    await mount(tester, transport);
    await openKeyScreen(tester);
    await revokeAndRestore(tester);
    await tap(tester, find.text('Save'));
    expect(transport.writes, isEmpty);
    await openKeyScreen(tester);
    await tap(tester, find.text('Save'));
    expect(transport.writes.single.method, 'PUT');
    await tester.pumpWidget(const SizedBox());
  });

  for (final provider in ['Acme', 'Nous']) {
    testWidgets(
      'restored write access does not revive a retired $provider disconnect',
      (tester) async {
        final transport = _Transport();
        await mount(tester, transport);
        await openDisconnect(tester, provider);
        await revokeAndRestore(tester);
        await tap(tester, dialogButton('Disconnect'));
        expect(transport.writes, isEmpty);
        await openDisconnect(tester, provider);
        await tap(tester, dialogButton('Disconnect'));
        expect(transport.writes.single.method, 'DELETE');
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
