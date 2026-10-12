// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/external_provider_screen.dart';
import 'package:hermes_android/core/screens/custom_endpoints_section.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _listPath = '/api/providers/custom-endpoints';

Map<String, Object> _endpoint(String owner) => {
  'id': '$owner-endpoint',
  'name': '$owner endpoint',
  'base_url': 'https://$owner.example.test/v1',
  'model': '$owner-model',
  'models': ['$owner-model'],
  'has_api_key': false,
  'is_current': false,
  'source': 'providers',
};

class _Transport {
  bool inventoryFailed = true;
  Future<http.Response> Function()? inventory;
  final requests = <http.Request>[];
  Future<http.Response> Function(http.Request)? list;
  Future<http.Response> Function(http.Request)? write;

  late final client = DashboardClient(
    host: 'entry.example.test',
    manualToken: 'synthetic-entry-identity',
    httpClientOverride: MockClient((request) async {
      requests.add(request);
      if (request.method != 'GET') {
        return write?.call(request) ?? http.Response('{"ok":true}', 200);
      }
      switch (request.url.path) {
        case '/api/model/info':
          return http.Response('{"model":"fixture","provider":"custom"}', 200);
        case '/api/model/options':
          if (inventory != null) return inventory!();
          return inventoryFailed
              ? http.Response('{}', 503)
              : http.Response('{"providers":[]}', 200);
        case _listPath:
          return list?.call(request) ?? http.Response('{"endpoints":[]}', 200);
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

  Iterable<http.Request> get writes => requests.where((r) => r.method != 'GET');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConnectionManager manager;
  late ActiveProfileScope scope;

  SavedConnection connection({bool readOnly = false}) => SavedConnection(
    id: 'entry-security',
    label: 'Synthetic entry',
    host: 'entry.example.test',
    port: 8642,
    apiKey: 'synthetic-entry-identity',
    kind: InstanceKind.vps,
    readOnly: readOnly,
  );

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
    await manager.setActiveProfile('entry-security', 'ana');
    scope = ActiveProfileScope.of(manager, 'entry-security');
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> mount(
    WidgetTester tester,
    _Transport transport, {
    bool readOnly = false,
  }) async {
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
          connection: connection(readOnly: readOnly),
          profileScope: scope,
          dashboardClientForTesting: transport.client,
          gatewayCatalogForTesting: () => null,
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pump();
    expect(target.hitTestable(), findsOneWidget);
    await tester.tap(target);
    await settle(tester);
  }

  final add = find.byKey(const ValueKey('custom-endpoint-add'));

  Finder menu() => find.descendant(
    of: find.byKey(const ValueKey('saved-endpoint-ana-endpoint')),
    matching: find.byIcon(Icons.more_vert),
  );
  Finder overlay(String label, String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.text(label),
  );
  _Transport savedTransport() => _Transport()
    ..list = (_) async => http.Response(
      jsonEncode({
        'endpoints': [_endpoint('ana')],
      }),
      200,
    );

  testWidgets(
    'inventory failed real form creates edits cancels deletes and reads back scoped endpoint',
    (tester) async {
      final rows = <Map<String, Object?>>[];
      final transport = _Transport();
      transport.list = (_) async =>
          http.Response(jsonEncode({'endpoints': rows}), 200);
      transport.write = (request) async {
        expect(request.url.queryParameters['profile'], 'ana');
        if (request.method == 'POST' && request.url.path == _listPath) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body.containsKey('api_key'), isFalse);
          expect(body['make_default'], isFalse);
          rows
            ..clear()
            ..add({..._endpoint('ana'), ...body, 'id': 'ana-endpoint'});
          return http.Response('{"ok":true,"id":"ana-endpoint"}', 200);
        }
        if (request.method == 'DELETE') {
          rows.clear();
          return http.Response('{"ok":true}', 200);
        }
        throw StateError(
          'unexpected mutation ${request.method} ${request.url.path}',
        );
      };
      await mount(tester, transport);
      await tap(tester, add);
      expect(find.byType(ExternalProviderScreen), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).at(0),
        'https://created.example.test/v1',
      );
      await tester.enterText(find.byType(TextField).at(1), 'Created endpoint');
      await tap(tester, find.text('Save endpoint'));
      expect(find.byType(ExternalProviderScreen), findsNothing);
      expect(find.text('Created endpoint'), findsOneWidget);
      final post = transport.writes.single;
      expect(post.method, 'POST');
      expect(post.url.path, _listPath);
      expect(jsonDecode(post.body)['id'], '');
      expect(
        jsonDecode(post.body)['base_url'],
        'https://created.example.test/v1',
      );
      expect(
        transport.requests.lastWhere((r) => r.url.path == _listPath).method,
        'GET',
      );
      await tap(
        tester,
        find.byKey(const ValueKey('saved-endpoint-ana-endpoint')),
      );
      await tester.enterText(
        find.byType(TextField).at(0),
        'https://edited.example.test/v1',
      );
      await tap(tester, find.text('Save endpoint'));
      expect(find.byType(ExternalProviderScreen), findsNothing);
      expect(rows.single['base_url'], 'https://edited.example.test/v1');
      expect(jsonDecode(transport.writes.last.body)['id'], 'ana-endpoint');
      expect(
        transport.requests.lastWhere((r) => r.url.path == _listPath).method,
        'GET',
      );
      await tap(tester, menu());
      await tap(tester, overlay('Delete', 'hermes-menu'));
      await tap(tester, overlay('Cancel', 'hermes-dialog'));
      expect(transport.writes.where((r) => r.method == 'DELETE'), isEmpty);
      expect(find.text('Created endpoint'), findsOneWidget);
      await tap(tester, menu());
      await tap(tester, overlay('Delete', 'hermes-menu'));
      await tap(tester, overlay('Delete', 'hermes-dialog'));
      final deletion = transport.writes.last;
      expect(deletion.method, 'DELETE');
      expect(deletion.url.path, '$_listPath/ana-endpoint');
      expect(deletion.url.queryParameters['profile'], 'ana');
      expect(deletion.body, isEmpty);
      expect(
        transport.requests.lastWhere((r) => r.url.path == _listPath).method,
        'GET',
      );
      expect(
        find.byKey(const ValueKey('saved-endpoint-ana-endpoint')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final action in ['Activate', 'Delete']) {
    testWidgets('read-only saved endpoint $action emits zero writes', (
      tester,
    ) async {
      final transport = savedTransport();
      await mount(tester, transport, readOnly: true);
      await tap(tester, menu());
      await tap(tester, overlay(action, 'hermes-menu'));
      if (find.byKey(const ValueKey('hermes-dialog')).evaluate().isNotEmpty) {
        await tap(tester, overlay('Delete', 'hermes-dialog'));
      }
      expect(transport.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'delete dialog profile ABA revokes old intent but admits fresh intent',
    (tester) async {
      final transport = savedTransport();
      await mount(tester, transport);
      await tap(tester, menu());
      await tap(tester, overlay('Delete', 'hermes-menu'));
      expect(find.byKey(const ValueKey('hermes-dialog')), findsOneWidget);
      await scope.switchTo('bob');
      await settle(tester);
      await scope.switchTo('ana');
      await settle(tester);
      await tap(tester, overlay('Delete', 'hermes-dialog'));
      expect(
        transport.writes,
        isEmpty,
        reason: 'ABA must not revive the old confirmation',
      );
      await tap(tester, menu());
      await tap(tester, overlay('Delete', 'hermes-menu'));
      await tap(tester, overlay('Delete', 'hermes-dialog'));
      expect(transport.writes, hasLength(1));
      expect(transport.writes.single.url.queryParameters['profile'], 'ana');
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final status in [401, 403, 422, 503]) {
    testWidgets(
      'save rejected $status retains real form draft and no readback success',
      (tester) async {
        final transport = savedTransport();
        transport.write = (_) async =>
            http.Response('{"error":"synthetic rejection"}', status);
        await mount(tester, transport);
        await tap(
          tester,
          find.byKey(const ValueKey('saved-endpoint-ana-endpoint')),
        );
        await tester.enterText(
          find.byType(TextField).first,
          'https://retained.example.test/v1',
        );
        final before = transport.requests
            .where((r) => r.method == 'GET' && r.url.path == _listPath)
            .length;
        await tap(tester, find.text('Save endpoint'));
        // Existing DashboardClient retries one 401 after identity refresh.
        expect(transport.writes, hasLength(status == 401 ? 2 : 1));
        expect(find.byType(ExternalProviderScreen), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          'https://retained.example.test/v1',
        );
        expect(
          transport.requests.where(
            (r) => r.method == 'GET' && r.url.path == _listPath,
          ),
          hasLength(before),
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final action in ['Activate', 'Delete']) {
    testWidgets('retained $action menu profile ABA cannot mutate', (
      tester,
    ) async {
      final transport = savedTransport();
      await mount(tester, transport);
      await tap(tester, menu());
      await scope.switchTo('bob');
      await settle(tester);
      await scope.switchTo('ana');
      await settle(tester);
      await tap(tester, overlay(action, 'hermes-menu'));
      expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
      expect(transport.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final action in ['Activate', 'Delete']) {
    for (final status in [200, 403]) {
      testWidgets(
        'pending $action $status ABA rejects publication preserves own busy cleanup',
        (tester) async {
          final pending = Completer<http.Response>();
          final transport = savedTransport();
          transport.write = (_) => pending.future;
          await mount(tester, transport);
          await tap(tester, menu());
          await tap(tester, overlay(action, 'hermes-menu'));
          if (action == 'Delete') {
            await tap(tester, overlay('Delete', 'hermes-dialog'));
          }
          expect(transport.writes, hasLength(1));
          expect(transport.writes.single.url.queryParameters['profile'], 'ana');
          await scope.switchTo('bob');
          await settle(tester);
          await scope.switchTo('ana');
          await settle(tester);
          final disabledMenu = tester.widget<IconButton>(
            find.ancestor(of: menu(), matching: find.byType(IconButton)),
          );
          expect(disabledMenu.onPressed, isNull);
          final reads = transport.requests
              .where((r) => r.method == 'GET')
              .length;
          pending.complete(
            http.Response(status == 200 ? '{"ok":true}' : '{}', status),
          );
          await settle(tester);
          expect(
            transport.requests.where((r) => r.method == 'GET'),
            hasLength(reads),
            reason: 'retired completion must not reload successor',
          );
          expect(transport.writes, hasLength(1));
          expect(
            tester
                .widget<IconButton>(
                  find.ancestor(of: menu(), matching: find.byType(IconButton)),
                )
                .onPressed,
            isNotNull,
            reason: 'only settled write releases its busy state',
          );
          transport.write = (_) async => http.Response('{"ok":true}', 200);
          await tap(tester, menu());
          await tap(tester, overlay(action, 'hermes-menu'));
          if (action == 'Delete') {
            await tap(tester, overlay('Delete', 'hermes-dialog'));
          }
          expect(transport.writes, hasLength(2));
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  Future<void> section(
    WidgetTester tester,
    _Transport transport,
    SavedConnection conn,
  ) async {
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
        home: Scaffold(
          body: CustomEndpointsSection(
            key: const ValueKey('authority-section'),
            connection: conn,
            dashboard: transport.client,
            profile: scope.name,
            profileScope: scope,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  for (final action in ['Activate', 'Delete']) {
    testWidgets(
      'retained $action menu readonly writable readonly ABA never revives intent',
      (tester) async {
        final transport = savedTransport();
        final ro = connection(readOnly: true);
        final rw = connection();
        await section(tester, transport, ro);
        await tap(tester, menu());
        await section(tester, transport, rw);
        await section(tester, transport, ro);
        await section(tester, transport, rw);
        await tap(tester, overlay(action, 'hermes-menu'));
        if (find.byKey(const ValueKey('hermes-dialog')).evaluate().isNotEmpty) {
          await tap(tester, overlay('Delete', 'hermes-dialog'));
        }
        expect(transport.writes, isEmpty);
        await tap(tester, menu());
        await tap(tester, overlay(action, 'hermes-menu'));
        if (action == 'Delete') {
          await tap(tester, overlay('Delete', 'hermes-dialog'));
        }
        expect(
          transport.writes,
          hasLength(1),
          reason: 'recovery admits only fresh action',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'retained Add and edit callbacks revoked by connection configuration ABA',
    (tester) async {
      final transport = savedTransport();
      final first = connection();
      final second = SavedConnection(
        id: 'entry-security',
        label: 'Changed',
        host: 'changed.example.test',
        port: 8642,
        apiKey: '',
        kind: InstanceKind.vps,
      );
      await section(tester, transport, first);
      final oldAdd = tester.widget<HermesListRow>(add).onTap!;
      final oldEdit = tester
          .widget<HermesListRow>(
            find.byKey(const ValueKey('saved-endpoint-ana-endpoint')),
          )
          .onTap!;
      await section(tester, transport, second);
      await section(tester, transport, first);
      oldAdd();
      await settle(tester);
      expect(find.byType(ExternalProviderScreen), findsNothing);
      oldEdit();
      await settle(tester);
      expect(find.byType(ExternalProviderScreen), findsNothing);
      await tap(tester, add);
      expect(find.byType(ExternalProviderScreen), findsOneWidget);
      expect(transport.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'delete held confirmation rejects profile ana to bob without retargeting old id',
    (tester) async {
      final transport = savedTransport();
      await mount(tester, transport);
      await tap(tester, menu());
      await tap(tester, overlay('Delete', 'hermes-menu'));
      await scope.switchTo('bob');
      await settle(tester);
      await tap(tester, overlay('Delete', 'hermes-dialog'));
      expect(transport.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'pending real editor profile ABA never revives draft intent or resets owning busy',
    (tester) async {
      final pending = Completer<http.Response>();
      final transport = savedTransport();
      transport.write = (_) => pending.future;
      await mount(tester, transport);
      await tap(
        tester,
        find.byKey(const ValueKey('saved-endpoint-ana-endpoint')),
      );
      await tester.enterText(
        find.byType(TextField).first,
        'https://held.example.test/v1',
      );
      await tap(tester, find.text('Save endpoint'));
      await scope.switchTo('bob');
      await settle(tester);
      await scope.switchTo('ana');
      await settle(tester);
      final saveButton = find.ancestor(
        of: find.text('Save endpoint'),
        matching: find.byType(FilledButton),
      );
      expect(
        tester.widget<FilledButton>(saveButton).onPressed,
        isNull,
        reason: 'own pending save must retain busy lease',
      );
      pending.complete(http.Response('{"ok":true}', 200));
      await settle(tester);
      expect(find.byType(ExternalProviderScreen), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'https://held.example.test/v1',
      );
      await tap(tester, find.text('Save endpoint'));
      expect(transport.writes, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('direct readonly real form validation emits zero POST', (
    tester,
  ) async {
    final transport = savedTransport();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.hermesRedDark,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: ExternalProviderScreen(
          connection: connection(readOnly: true),
          profile: 'ana',
          profileScope: scope,
          dashboard: transport.client,
        ),
      ),
    );
    await settle(tester);
    await tester.enterText(
      find.byType(TextField).first,
      'https://readonly.example.test/v1',
    );
    await tap(tester, find.text('Test connection'));
    expect(transport.writes, isEmpty);
    await tap(tester, find.text('Save endpoint'));
    expect(transport.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('held Activate menu ana to bob rejects old endpoint actor', (
    tester,
  ) async {
    final transport = savedTransport();
    await mount(tester, transport);
    await tap(tester, menu());
    await scope.switchTo('bob');
    await settle(tester);
    await tap(tester, overlay('Activate', 'hermes-menu'));
    expect(transport.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('held legacy validation profile ABA cannot send fallback POST', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final transport = _Transport();
    transport.list = (_) async => http.Response('{}', 404);
    transport.write = (_) => pending.future;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.hermesRedDark,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: ExternalProviderScreen(
          connection: connection(),
          profile: 'ana',
          profileScope: scope,
          dashboard: transport.client,
        ),
      ),
    );
    await settle(tester);
    await tester.enterText(
      find.byType(TextField).first,
      'https://legacy.example.test',
    );
    await tap(tester, find.text('Test connection'));
    expect(transport.writes, hasLength(1));
    expect(transport.writes.single.url.path, '/api/providers/validate');
    await scope.switchTo('bob');
    await settle(tester);
    await scope.switchTo('ana');
    await settle(tester);
    pending.complete(http.Response('{"reachable":true,"models":[]}', 200));
    await settle(tester);
    expect(
      transport.writes,
      hasLength(1),
      reason: 'revoked validation must not continue to a second URL',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'https://legacy.example.test',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'positive config permits real Add Save readback before 16 second inventory resolves',
    (tester) async {
      final pending = Completer<http.Response>();
      final transport = _Transport()..inventory = () => pending.future;
      final rows = <Map<String, Object>>[];
      transport.list = (_) async =>
          http.Response(jsonEncode({'endpoints': rows}), 200);
      transport.write = (request) async {
        expect(request.method, 'POST');
        expect(request.url.path, _listPath);
        expect(request.url.queryParameters['profile'], 'ana');
        expect(
          jsonDecode(request.body)['base_url'],
          'https://early.example.test/v1',
        );
        rows.add(_endpoint('ana'));
        return http.Response('{"ok":true,"id":"ana-endpoint"}', 200);
      };
      await mount(tester, transport);
      expect(pending.isCompleted, isFalse);
      await tap(tester, add);
      expect(find.byType(ExternalProviderScreen), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).first,
        'https://early.example.test/v1',
      );
      await tap(tester, find.text('Save endpoint'));
      expect(transport.writes, hasLength(1));
      expect(pending.isCompleted, isFalse);
      expect(
        transport.requests.lastWhere((r) => r.url.path == _listPath).method,
        'GET',
      );
      expect(
        find.byKey(const ValueKey('saved-endpoint-ana-endpoint')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 16));
      await settle(tester);
      expect(pending.isCompleted, isFalse);
      expect(tester.widget<HermesListRow>(add).enabled, isTrue);
      pending.complete(http.Response('{"providers":[]}', 200));
      await settle(tester);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
