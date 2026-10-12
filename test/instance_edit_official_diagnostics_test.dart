// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  for (final failure in [null, 401, 404, 500, 'timeout']) {
    testWidgets(
      'actual editor diagnostics removes Bridge scope and retains official credentials: $failure',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        const channel = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage',
        );
        final secure = <String, String>{};
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              final args = (call.arguments as Map?) ?? {};
              if (call.method == 'readAll') return secure;
              if (call.method == 'read') return secure[args['key']];
              if (call.method == 'write') secure[args['key']] = args['value'];
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final prefs = await SharedPreferences.getInstance();
        final manager = await ConnectionManager.create(prefs);
        addTearDown(manager.dispose);
        final connection = SavedConnection(
          id: 'diag-owner',
          label: 'Existing',
          host: '127.0.0.1',
          port: 9131,
          apiKey: 'synthetic-gateway',
          dashboardUrl: 'http://127.0.0.1:19119',
          dashboardAuthMode: AuthMode.sessionToken,
        );
        await manager.upsertConnection(connection);
        secure['dash_token_diag-owner'] = 'synthetic-dashboard-token';
        final requests = <http.Request>[];
        final client = MockClient((r) async {
          requests.add(r);
          if (r.url.path.startsWith('/bridge/')) {
            return http.Response('{}', 200);
          }
          if (r.url.path == '/health') {
            return http.Response('{"version":"synthetic"}', 200);
          }
          if (r.url.path == '/api/status') {
            return http.Response('{"auth_required":false}', 200);
          }
          if (r.url.port == 9131) {
            expect(r.headers['Authorization'], 'Bearer synthetic-gateway');
          } else {
            expect(r.url.port, 19119);
            expect(
              r.headers['X-Hermes-Session-Token'],
              'synthetic-dashboard-token',
            );
          }
          if (failure == 'timeout') throw TimeoutException('synthetic');
          return http.Response(
            r.url.path == '/v1/capabilities'
                ? '{"object":"hermes.api_server.capabilities","features":{},"endpoints":{}}'
                : '{}',
            failure is int ? failure : 200,
          );
        });
        tester.view.physicalSize = const Size(1000, 2600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await http.runWithClient(() async {
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: Strings.localizationsDelegates,
              supportedLocales: Strings.supportedLocales,
              home: InstanceEditScreen(
                connManager: manager,
                initial: connection,
                diagnostics: ConnectionDiagnostics(httpClient: client),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final entry = find.byKey(const ValueKey('instance-details'));
          await tester.ensureVisible(entry);
          await tester.tap(entry);
          await tester.pumpAndSettle();
          final technical = find.byKey(const ValueKey('diagnostics-technical'));
          await tester.ensureVisible(technical);
          await tester.tap(technical);
          await tester.pumpAndSettle();
          final legacyBridge = find.byKey(
            const ValueKey('diagnostics-run-bridge'),
          );
          if (legacyBridge.evaluate().isNotEmpty) {
            await tester.ensureVisible(legacyBridge);
            await tester.tap(legacyBridge);
            await tester.pumpAndSettle();
          }
          expect(
            requests.where((r) => r.url.path.startsWith('/bridge/')),
            isEmpty,
          );
          expect(legacyBridge, findsNothing);
          expect(find.text('Mobile Bridge'), findsNothing);
          for (final scope in ['gateway', 'dashboard']) {
            final action = find.byKey(ValueKey('diagnostics-run-$scope'));
            if (action.evaluate().isEmpty) {
              await tester.ensureVisible(technical);
              await tester.tap(technical);
              await tester.pumpAndSettle();
            }
            await tester.ensureVisible(action);
            await tester.tap(action);
            await tester.pumpAndSettle();
          }
          expect(
            requests.where((r) => r.url.path.startsWith('/bridge/')),
            isEmpty,
          );
          expect(
            requests.where((r) => r.url.path == '/api/config'),
            isNotEmpty,
          );
          expect(
            requests.where(
              (r) => r.url.path == '/api/sessions' && r.url.port == 9131,
            ),
            isNotEmpty,
          );
          expect(requests.every((r) => r.method == 'GET'), isTrue);
          expect(manager.getConnections().single.apiKey, 'synthetic-gateway');
          expect(
            await manager
                .getDashboardSecrets(connection.id)
                .then((s) => s.sessionToken),
            'synthetic-dashboard-token',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }, () => client);
      },
    );
  }
}
