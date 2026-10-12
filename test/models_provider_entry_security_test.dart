// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/external_provider_screen.dart';
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
  for (final inventoryFailed in [false, true]) {
    for (final result in ['401', '403', '503', 'pending']) {
      testWidgets(
        'Add rejects $result list with inventory failed=$inventoryFailed',
        (tester) async {
          final pending = Completer<http.Response>();
          final transport = _Transport()
            ..inventoryFailed = inventoryFailed
            ..list = (_) async => result == 'pending'
                ? pending.future
                : http.Response('{}', int.parse(result));
          await mount(tester, transport);
          expect(
            transport.requests.where((r) => r.url.path == _listPath),
            isNotEmpty,
          );
          expect(add, findsOneWidget);
          final row = tester.widget<HermesListRow>(add);
          expect(row.enabled, isFalse);
          expect(row.onTap, isNull);
          await tap(tester, add);
          expect(find.byType(ExternalProviderScreen), findsNothing);
          expect(transport.writes, isEmpty);
          await tester.pumpWidget(const SizedBox());
          pending.complete(http.Response('{"endpoints":[]}', 200));
          await settle(tester);
        },
      );
    }
  }

  testWidgets('read-only Add opens no editor and emits zero writes', (
    tester,
  ) async {
    final transport = _Transport();
    await mount(tester, transport, readOnly: true);
    expect(tester.widget<HermesListRow>(add).enabled, isTrue);
    await tap(tester, add);
    expect(find.byType(ExternalProviderScreen), findsNothing);
    expect(transport.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('valid Add preserves entered form without implicit writes', (
    tester,
  ) async {
    final transport = _Transport();
    await mount(tester, transport);
    await tap(tester, add);
    expect(find.byType(ExternalProviderScreen), findsOneWidget);
    final url = find.byType(TextField).first;
    await tester.enterText(url, 'https://draft.example.test/v1');
    await settle(tester);
    expect(
      tester.widget<TextField>(url).controller!.text,
      'https://draft.example.test/v1',
    );
    expect(find.text('Save endpoint'), findsOneWidget);
    expect(transport.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late old-profile list cannot publish rows or enable Add', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final transport = _Transport()
      ..list = (request) async =>
          request.url.queryParameters['profile'] == 'ana'
          ? pending.future
          : http.Response('{}', 403);
    await mount(tester, transport);
    await scope.switchTo('bob');
    await settle(tester);
    expect(
      transport.requests.where(
        (r) =>
            r.url.path == _listPath &&
            r.url.queryParameters['profile'] == 'bob',
      ),
      isNotEmpty,
    );
    pending.complete(
      http.Response(
        jsonEncode({
          'endpoints': [_endpoint('ana')],
        }),
        200,
      ),
    );
    await settle(tester);
    expect(
      find.byKey(const ValueKey('saved-endpoint-ana-endpoint')),
      findsNothing,
    );
    expect(tester.widget<HermesListRow>(add).enabled, isFalse);
    expect(transport.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'profile changes during Add detection reject late response and retain draft',
    (tester) async {
      final pending = Completer<http.Response>();
      var holdFormRead = false;
      var heldReads = 0;
      final transport = _Transport()
        ..list = (request) async {
          if (request.url.queryParameters['profile'] == 'ana' && holdFormRead) {
            heldReads++;
            return pending.future;
          }
          return http.Response('{"endpoints":[]}', 200);
        };
      await mount(tester, transport);
      holdFormRead = true;
      await tap(tester, add);
      expect(heldReads, 1);
      expect(find.byType(ExternalProviderScreen), findsOneWidget);
      final url = find.byType(TextField).first;
      await tester.enterText(url, 'https://retained.example.test/v1');
      await scope.switchTo('bob');
      await settle(tester);
      pending.complete(http.Response('{"endpoints":[]}', 200));
      await settle(tester);
      expect(find.byType(ExternalProviderScreen), findsOneWidget);
      expect(find.text('Save endpoint'), findsNothing);
      expect(
        tester.widget<TextField>(url).controller!.text,
        'https://retained.example.test/v1',
      );
      expect(transport.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final status in [200, 403]) {
    testWidgets('profile changes during editor reject late save $status', (
      tester,
    ) async {
      final pending = Completer<http.Response>();
      final transport = _Transport();
      transport.list = (_) async => http.Response(
        jsonEncode({
          'endpoints': [_endpoint('ana')],
        }),
        200,
      );
      transport.write = (_) => pending.future;
      await mount(tester, transport);
      await tap(
        tester,
        find.byKey(const ValueKey('saved-endpoint-ana-endpoint')),
      );
      expect(find.byType(ExternalProviderScreen), findsOneWidget);
      final url = find.byType(TextField).first;
      await tester.enterText(url, 'https://edited.example.test/v1');
      await tap(tester, find.text('Save endpoint'));
      expect(transport.writes, hasLength(1));
      expect(transport.writes.single.url.queryParameters['profile'], 'ana');
      expect(
        jsonDecode(transport.writes.single.body)['base_url'],
        'https://edited.example.test/v1',
      );
      await scope.switchTo('bob');
      await settle(tester);
      pending.complete(
        http.Response(status == 200 ? '{"ok":true}' : '{}', status),
      );
      await settle(tester);
      expect(find.byType(ExternalProviderScreen), findsOneWidget);
      expect(
        tester.widget<TextField>(url).controller!.text,
        'https://edited.example.test/v1',
      );
      expect(transport.writes, hasLength(1));
      await tap(tester, find.text('Save endpoint'));
      expect(
        transport.writes,
        hasLength(1),
        reason: 'Retired editor must not write under the successor profile',
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
