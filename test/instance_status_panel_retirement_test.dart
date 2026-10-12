import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Bridge HTTP detector catches the real client health request', () async {
    final forbidden = <String>[];
    final client = MockClient((request) async {
      forbidden.add(request.url.path);
      return http.Response('{}', 403);
    });
    await http.runWithClient(() async {
      await http.Client().get(
        Uri.parse('https://fixture.invalid/bridge/health'),
      );
    }, () => client);
    expect(forbidden, ['/bridge/health']);
  });

  testWidgets('cold panel and refresh retire Bridge probes and actions', (
    tester,
  ) async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      return http.Response('{}', 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(_app(_panel(_remote())));
      await tester.pumpAndSettle();
      expect(find.text('Gateway'), findsOneWidget);
      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('Mobile Bridge'), findsNothing);
      expect(find.text('Repair bridge'), findsNothing);
      expect(find.text('Installing and restarting…'), findsNothing);
      expect(find.text('Open safe setup'), findsNothing);
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(requests.where((path) => path.contains('bridge')), isEmpty);
      expect(requests.where((path) => path.contains('repair')), isEmpty);
      expect(tester.takeException(), isNull);
    }, () => client);
  });

  for (final code in [200, 401, 403, 404, 500, null]) {
    testWidgets(
      'saved Dashboard token is verified on cold load and refresh: $code',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        final conn = _remote().copyWith(
          dashboardAuthMode: AuthMode.sessionToken,
        );
        await manager.setDashboardSecrets(
          conn.id,
          sessionToken: 'synthetic-session',
        );
        final requests = <String>[];
        final client = MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.path == '/api/sessions' &&
              request.url.host == 'dashboard.invalid') {
            if (code == null) throw TimeoutException('synthetic timeout');
            return http.Response('{"sessions":[]}', code);
          }
          return http.Response('{}', 200);
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(
            _app(
              InstanceStatusPanel(
                connection: conn,

                connManager: manager,
                reachable: (_) async => true,
                gatewayKey: (_) async => GatewayKeyCheck.ok,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final row = find.byKey(
            const ValueKey('instance-status-row-dashboard'),
          );
          for (var pass = 0; pass < 2; pass++) {
            final expected = code == 200
                ? 'connected'
                : code == 401 || code == 403
                ? 'login required'
                : 'Status unavailable';
            expect(
              find.descendant(of: row, matching: find.text(expected)),
              findsOneWidget,
            );
            if (pass == 0) {
              await tester.tap(find.byIcon(Icons.refresh));
              await tester.pumpAndSettle();
            }
          }
          expect(
            requests.where((path) => path == '/api/sessions').length,
            greaterThanOrEqualTo(2),
          );
          expect(
            requests.where(
              (path) => path.contains('bridge') || path == '/v1/runs',
            ),
            isEmpty,
          );
        }, () => client);
      },
    );
  }

  for (final code in [401, 403, 404, 500, null]) {
    testWidgets('official Gateway rejection $code never claims connected', (
      tester,
    ) async {
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path == '/api/sessions') {
          expect(request.headers['Authorization'], isNotEmpty);
          if (code == null) throw TimeoutException('synthetic timeout');
          return http.Response('{}', code);
        }
        return http.Response('{}', 200);
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(_app(_panel(_remote())));
        await tester.pumpAndSettle();
        final row = find.byKey(const ValueKey('instance-status-row-gateway'));
        expect(
          find.descendant(of: row, matching: find.text('connected')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: row,
            matching: find.text(
              code == 401 || code == 403
                  ? 'API key rejected'
                  : 'Status unavailable',
            ),
          ),
          findsOneWidget,
        );
        expect(requests, contains('/api/sessions'));
        expect(requests.where((path) => path.contains('bridge')), isEmpty);
      }, () => client);
    });
  }

  for (final auth in DashboardAuthCheck.values) {
    testWidgets('Dashboard $auth remains distinct from Gateway health', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          InstanceStatusPanel(
            connection: _remote(),

            reachable: (_) async => true,
            gatewayKey: (_) async => GatewayKeyCheck.ok,
            dashboardAuth: (_) async => auth,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('instance-status-row-dashboard'));
      final detail = switch (auth) {
        DashboardAuthCheck.ok => 'connected',
        DashboardAuthCheck.loginRequired => 'login required',
        DashboardAuthCheck.invalidCredentials => 'wrong password',
        DashboardAuthCheck.unknown => 'Status unavailable',
      };
      expect(
        find.descendant(of: row, matching: find.text(detail)),
        findsOneWidget,
      );
    });
  }

  for (final change in ['credentials', 'profile']) {
    testWidgets('same owner $change retires a pending status probe', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final conn = _remote();
      await manager.upsertConnection(conn);
      final gate = Completer<GatewayKeyCheck>();
      var reads = 0;
      await tester.pumpWidget(
        _app(
          InstanceStatusPanel(
            connection: conn,

            connManager: manager,
            reachable: (_) async => true,
            dashboardAuth: (_) async => DashboardAuthCheck.ok,
            gatewayKey: (_) => ++reads == 1
                ? gate.future
                : Future.value(GatewayKeyCheck.rejected),
          ),
        ),
      );
      await tester.pump();
      if (change == 'credentials') {
        await manager.setDashboardSecrets(
          conn.id,
          sessionToken: 'rotated-synthetic-session',
        );
      } else {
        await manager.setActiveProfile(conn.id, 'fixture-profile');
      }
      await tester.pump();
      gate.complete(GatewayKeyCheck.ok);
      await tester.pumpAndSettle();
      expect(reads, greaterThanOrEqualTo(2));
      final row = find.byKey(const ValueKey('instance-status-row-gateway'));
      expect(
        find.descendant(of: row, matching: find.text('API key rejected')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('connected')),
        findsNothing,
      );
    });
  }

  testWidgets('same-state A B A change fences late authenticated success', (
    tester,
  ) async {
    final gate = Completer<GatewayKeyCheck>();
    var reads = 0;
    Widget panel(SavedConnection connection) => InstanceStatusPanel(
      connection: connection,

      reachable: (_) async => true,
      dashboardAuth: (_) async => DashboardAuthCheck.ok,
      gatewayKey: (_) {
        reads++;
        return reads == 1
            ? gate.future
            : Future.value(GatewayKeyCheck.rejected);
      },
    );
    final a = _remote();
    await tester.pumpWidget(_app(panel(a)));
    await tester.pump();
    await tester.pumpWidget(_app(panel(a.copyWith(id: 'other'))));
    await tester.pump();
    await tester.pumpWidget(_app(panel(a)));
    await tester.pump();
    gate.complete(GatewayKeyCheck.ok);
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('instance-status-row-gateway'));
    expect(
      find.descendant(of: row, matching: find.text('API key rejected')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('connected')),
      findsNothing,
    );
    expect(reads, 3);
  });
}

InstanceStatusPanel _panel(SavedConnection connection) => InstanceStatusPanel(
  connection: connection,

  dashboardAuth: (_) async => DashboardAuthCheck.ok,
);

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: child),
);

SavedConnection _remote() => SavedConnection(
  id: 'fixture',
  label: 'Fixture',
  host: 'fixture.invalid',
  port: 443,
  useHttps: true,
  apiKey: '',
  dashboardUrl: 'https://dashboard.invalid',
);
