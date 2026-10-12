import 'support/official_http_audit.dart';

// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
import 'dart:async';
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
import 'package:shared_preferences/shared_preferences.dart';

final connection = SavedConnection(
  id: 'official-owner',
  label: 'Fixture',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'synthetic-fixture-token',
);
Future<void> pump(
  WidgetTester t,
  DashboardClient d,
  OfficialHttpAudit b, {
  ActiveProfileScope? scope,
}) async {
  t.view.physicalSize = const Size(600, 2400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      theme: AppTheme.hermesRedDark,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: ModelsScreen(
        connection: connection,
        dashboardClientForTesting: d,

        profileScope: scope,
        gatewayCatalogForTesting: () => null,
      ),
    ),
  );
  await settle(t);
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

http.Response base(http.Request r, {int aux = 200, int config = 200}) {
  switch (r.url.path) {
    case '/api/model/info':
      return http.Response('{"model":"main","provider":"fixture"}', 200);
    case '/api/model/options':
      return http.Response(
        '{"providers":[{"slug":"fixture","name":"Fixture","authenticated":true,"models":["main","next"]}]}',
        200,
      );
    case '/api/model/auxiliary':
      return http.Response(
        '{"tasks":[{"task":"vision","provider":"fixture","model":"main"}]}',
        aux,
      );
    case '/api/config':
      return http.Response('{"fallback_providers":[]}', config);
    case '/api/providers/oauth':
      return http.Response('{"providers":[]}', 200);
    default:
      return http.Response('{}', 404);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });
  testWidgets('official catalog failure retains the profile\'s cached '
      'accounts', (t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'models_catalog_cache_${jsonEncode([connection.id, 'default'])}',
      jsonEncode({
        'accounts': [
          {
            'id': 'cached',
            'name': 'Cached login',
            'flow': 'device_code',
            'disconnectable': true,
            'status': {'logged_in': true},
          },
        ],
      }),
    );
    final b = OfficialHttpAudit();
    final d = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'synthetic-fixture-token',
      httpClientOverride: b.client(
        (r) async =>
            const {
              '/api/model/options',
              '/api/providers/oauth',
            }.contains(r.url.path)
            ? http.Response('{}', 500)
            : base(r),
      ),
    );
    await pump(t, d, b);
    expect(find.text('Cached login'), findsOneWidget);
    expect(b.calls, isEmpty);
    await t.pumpWidget(const SizedBox());
  });
  for (final status in <Object>[401, 404, 500, 'null', '[]']) {
    testWidgets(
      'official auxiliary and fallback read failures explicit without provisioning $status',
      (t) async {
        final b = OfficialHttpAudit();
        final d = DashboardClient(
          host: '127.0.0.1',
          manualToken: 'synthetic-fixture-token',
          httpClientOverride: b.client(
            (r) async => status is int
                ? base(r, aux: status, config: status)
                : ['/api/model/auxiliary', '/api/config'].contains(r.url.path)
                ? http.Response(status.toString(), 200)
                : base(r),
          ),
        );
        await pump(t, d, b);
        expect(find.byKey(const ValueKey('models-aux-error')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('models-fallback-error')),
          findsOneWidget,
        );
        expect(find.text('Fixture'), findsWidgets);
        expect(b.calls, isEmpty);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  for (final operation in ['main', 'reset']) {
    for (final outcome in ['false', '500']) {
      testWidgets(
        'official $operation rejects $outcome without false success',
        (t) async {
          final b = OfficialHttpAudit();
          final writes = <http.Request>[];
          var infos = 0;
          final d = DashboardClient(
            host: '127.0.0.1',
            manualToken: 'synthetic-fixture-token',
            httpClientOverride: b.client((r) async {
              if (r.url.path == '/api/model/info') infos++;
              if (r.url.path == '/api/model/set') {
                writes.add(r);
                return http.Response(
                  '{"ok":false}',
                  outcome == '500' ? 500 : 200,
                );
              }
              return base(r);
            }),
          );
          await pump(t, d, b);
          if (operation == 'main') {
            await t.tap(find.text('Fixture').last);
            await settle(t);
            await t.tap(find.text('next'));
          } else {
            await t.tap(find.text('Models by function'));
            await settle(t);
            await t.tap(find.byKey(const ValueKey('models-aux-reset')));
            await settle(t);
            await t.tap(
              find.descendant(
                of: find.byKey(const ValueKey('hermes-dialog')),
                matching: find.text('Reset all to main'),
              ),
            );
          }
          await settle(t);
          expect(writes, hasLength(1));
          expect(
            infos,
            1,
            reason: 'Rejected write must not reload or announce success',
          );
          expect(b.calls, isEmpty);
          expect(
            find.text('Auxiliary models reset to automatic'),
            findsNothing,
          );
          expect(find.text('Active model: next'), findsNothing);
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'fallback refresh owns data but pending write releases only its own busy flag',
    (t) async {
      final b = OfficialHttpAudit();
      final gate = Completer<http.Response>();
      var writes = 0;
      final d = DashboardClient(
        host: '127.0.0.1',
        manualToken: 'synthetic-fixture-token',
        httpClientOverride: b.client((r) async {
          if (r.url.path == '/api/config') {
            if (r.method == 'PUT') {
              writes++;
              return gate.future;
            }
            // Another client changes the chain while the write is pending.
            return http.Response(
              jsonEncode({
                'fallback_providers': [
                  {
                    'provider': 'fixture',
                    'model': writes == 0 ? 'backup' : 'current',
                  },
                ],
              }),
              200,
            );
          }
          return base(r);
        }),
      );
      await pump(t, d, b);
      await t.tap(find.byKey(const ValueKey('models-fallback-remove-0')));
      await settle(t);
      await t.tap(
        find.descendant(
          of: find.byKey(const ValueKey('hermes-dialog')),
          matching: find.text('Remove'),
        ),
      );
      await settle(t);
      expect(writes, 1);
      await t
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await settle(t);
      expect(find.text('current'), findsOneWidget);
      gate.complete(http.Response('{"ok":false}', 200));
      await settle(t);
      expect(find.text('current'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(b.calls, isEmpty);
      await t.pumpWidget(const SizedBox());
    },
  );
  for (final lateStatus in [200, 500]) {
    testWidgets('main ABA ignores late $lateStatus error and cleanup', (
      t,
    ) async {
      final b = OfficialHttpAudit();
      final gate = Completer<http.Response>();
      var writes = 0;
      var infos = 0;
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final scope = ActiveProfileScope.of(manager, connection.id);
      final d = DashboardClient(
        host: '127.0.0.1',
        manualToken: 'synthetic-fixture-token',
        httpClientOverride: b.client((r) async {
          if (r.url.path == '/api/model/info') infos++;
          if (r.url.path == '/api/model/set') {
            writes++;
            return gate.future;
          }
          return base(r);
        }),
      );
      await pump(t, d, b, scope: scope);
      await t.tap(find.text('Fixture').last);
      await settle(t);
      await t.tap(find.text('next'));
      await settle(t);
      expect(writes, 1);
      await scope.switchTo('bert');
      await settle(t);
      await scope.switchTo('');
      await settle(t);
      final before = infos;
      gate.complete(http.Response('{"ok":false}', lateStatus));
      await settle(t);
      expect(infos, before);
      expect(find.textContaining('Could not apply'), findsNothing);
      expect(find.byIcon(Icons.refresh).first, findsOneWidget);
      expect(b.calls, isEmpty);
      await t.pumpWidget(const SizedBox());
    });
  }
  for (final lateError in [true, false]) {
    testWidgets(
      'fallback ABA drops late ${lateError ? 'error' : 'success'} after newer owner result',
      (t) async {
        final b = OfficialHttpAudit();
        final gate = Completer<http.Response>();
        var reads = 0;
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        await manager.setActiveProfile(connection.id, 'ana');
        final scope = ActiveProfileScope.of(manager, connection.id);
        final d = DashboardClient(
          host: '127.0.0.1',
          manualToken: 'synthetic-fixture-token',
          httpClientOverride: b.client((r) async {
            if (r.url.path == '/api/config') {
              reads++;
              if (reads == 1) return gate.future;
              return http.Response(
                lateError
                    ? '{"fallback_providers":[{"provider":"fixture","model":"current"}]}'
                    : '{}',
                lateError ? 200 : 500,
              );
            }
            return base(r);
          }),
        );
        await pump(t, d, b, scope: scope);
        expect(reads, 1);
        await scope.switchTo('bert');
        await settle(t);
        await scope.switchTo('ana');
        await settle(t);
        expect(reads, 3);
        gate.complete(
          http.Response(
            '{"fallback_providers":[{"provider":"fixture","model":"obsolete"}]}',
            lateError ? 500 : 200,
          ),
        );
        await settle(t);
        expect(find.text('obsolete'), findsNothing);
        if (lateError) {
          expect(find.text('current'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('models-fallback-error')),
            findsNothing,
          );
        } else {
          expect(
            find.byKey(const ValueKey('models-fallback-error')),
            findsOneWidget,
          );
        }
        expect(b.calls, isEmpty);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
}
