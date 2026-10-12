// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/external_provider_screen.dart';
import 'package:hermes_android/core/screens/gateway_manager_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class _Real extends HttpOverrides {}

Widget app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  for (final route in [
    'manager-health',
    'manager-sessions',
    'panel-key',
    'panel-discovery',
    'provider',
  ]) {
    for (final status in [200, 301, 302, 303, 307, 308]) {
      testWidgets('$route $status preserves origin without recipient contact', (
        tester,
      ) async {
        await HttpOverrides.runZoned(() async {
          late HttpServer a, b;
          final hits = <String>[];
          var receiverHits = 0;
          var bearerHits = 0;
          await tester.runAsync(() async {
            a = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            b = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            b.listen((r) async {
              receiverHits++;
              // Record only a canary match, never output any captured credential.
              if (r.headers.value('authorization') ==
                  'Bearer synthetic-widget-key') {
                bearerHits++;
              }
              await utf8.decoder.bind(r).join();
              r.response.write(
                '{"data":[{"id":"synthetic-model"}],"sessions":[]}',
              );
              await r.response.close();
            });
            a.listen((r) async {
              hits.add(r.uri.path);
              final shouldRedirect =
                  status != 200 &&
                  switch (route) {
                    'manager-sessions' ||
                    'panel-key' => r.uri.path == '/api/sessions',
                    'manager-health' ||
                    'panel-discovery' => r.uri.path == '/health',
                    _ => true,
                  };
              if (r.headers.value('authorization') != null) {
                expect(
                  r.headers.value('authorization'),
                  'Bearer synthetic-widget-key',
                );
              }
              if (shouldRedirect) {
                r.response.statusCode = status;
                r.response.headers.set(
                  'location',
                  'http://127.0.0.1:${b.port}/target',
                );
              } else {
                r.response.write(
                  '{"data":[{"id":"synthetic-model"}],"sessions":[]}',
                );
              }
              await r.response.close();
            });
          });
          final connection = SavedConnection(
            id: 'synthetic-widget',
            label: 'Synthetic',
            host: '127.0.0.1',
            port: a.port,
            apiKey: 'synthetic-widget-key',
            kind: InstanceKind.localhost,
          );
          SharedPreferences.setMockInitialValues({});
          FlutterSecureStorage.setMockInitialValues({});
          final manager = await ConnectionManager.create(
            await SharedPreferences.getInstance(),
          );
          await manager.upsertConnection(connection);
          final dashboard = DashboardClient(
            host: '127.0.0.1',
            manualToken: 'synthetic-token',
            httpClientOverride: MockClient(
              (_) async => http.Response('{}', 404),
            ),
          );
          try {
            if (route.startsWith('manager')) {
              await tester.pumpWidget(
                app(GatewayManagerScreen(connManager: manager)),
              );
            } else if (route.startsWith('panel')) {
              await tester.pumpWidget(
                app(
                  InstanceStatusPanel(
                    connection: connection,
                    reachable: route == 'panel-key' ? (_) async => true : null,
                    dashboardAuth: (_) async => DashboardAuthCheck.ok,
                  ),
                ),
              );
            } else {
              await tester.pumpWidget(
                app(
                  ExternalProviderScreen(
                    connection: connection,
                    dashboardClientForTesting: dashboard,
                    prefillUrl: 'http://127.0.0.1:${a.port}/v1',
                  ),
                ),
              );
              await tester.pumpAndSettle();
              final fields = find.byType(TextField);
              // Key is the only obscured field in the real form.
              final key =
                  fields
                          .evaluate()
                          .where((e) => (e.widget as TextField).obscureText)
                          .first
                          .widget
                      as TextField;
              key.controller!.text = 'synthetic-widget-key';
              await tester.ensureVisible(find.text('Test connection'));
              await tester.tap(find.text('Test connection'));
            }
            for (var i = 0; i < 20; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump(const Duration(milliseconds: 50));
            }
            expect(
              hits,
              isNotEmpty,
              reason: 'Actual widget must call the origin',
            );
            debugPrint(
              'redirect-receipt route=$route status=$status destination=$receiverHits bearerCanary=$bearerHits',
            );
            expect(
              receiverHits,
              0,
              reason: 'Redirect recipient must never be contacted',
            );
            expect(
              bearerHits,
              0,
              reason: 'Canary bearer must never reach recipient',
            );
            if (route == 'provider' && status == 200) {
              expect(find.text('synthetic-model'), findsWidgets);
            }
            if (route == 'panel-key' && status != 200) {
              expect(find.text('Status unavailable'), findsWidgets);
            }
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            dashboard.close();
            await tester.runAsync(() async {
              await a.close(force: true);
              await b.close(force: true);
            });
          }
        }, createHttpClient: _Real().createHttpClient);
      });
    }
  }
}
