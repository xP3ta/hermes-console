// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'support/connection_editor_actions.dart';

Widget app(Widget home) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: home,
);
SavedConnection conn({AuthMode mode = AuthMode.unknown}) => SavedConnection(
  id: 'review-owner',
  label: 'Existing',
  host: '127.0.0.1',
  port: 9131,
  apiKey: 'synthetic-gateway',
  dashboardUrl: 'http://127.0.0.1:19119',
  dashboardAuthMode: mode,
);
void main() {
  setUp(DashboardClient.resetSharedPasswordSessionsForTesting);
  for (final heldPath in ['/api/status', '/api/auth/providers']) {
    testWidgets(
      'entire $heldPath response body has bounded discovery and Retry',
      (tester) async {
        final held = StreamController<List<int>>();
        final requests = <String>[];
        final client = MockClient.streaming((r, _) async {
          requests.add(r.url.path);
          if (r.url.path == heldPath) {
            return http.StreamedResponse(held.stream, 200);
          }
          return http.StreamedResponse(
            Stream.value('{"auth_required":true}'.codeUnits),
            200,
          );
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(
            app(
              DashboardSetupScreen(
                connection: conn(),
                authorityCurrent: () => true,
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(seconds: 9));
          await tester.pump();
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(
            find.byKey(const ValueKey('dashboard-probe-retry')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('dashboard-login-error')),
            findsOneWidget,
          );
          expect(requests, contains(heldPath));
          await tester.pumpWidget(const SizedBox.shrink());
          await held.close();
        }, () => client);
      },
    );
  }
  testWidgets(
    'revoked login error clears busy and exposes expired authority without credential publication',
    (tester) async {
      final held = Completer<http.Response>();
      var epoch = 0;
      var secretCalls = 0;
      final client = MockClient((r) async {
        if (r.url.path == '/api/status') {
          return http.Response('{"auth_required":false}', 200);
        }
        secretCalls++;
        expect(
          r.headers['X-Hermes-Session-Token'],
          'synthetic-dashboard-token',
        );
        return held.future;
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(
          app(
            DashboardSetupScreen(
              connection: conn(),
              authorityCurrent: () => epoch == 0,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          'synthetic-dashboard-token',
        );
        await tester.tap(find.byKey(const ValueKey('dashboard-login-submit')));
        await tester.pump();
        epoch++;
        epoch++;
        held.completeError(StateError('synthetic-held-failure'));
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('dashboard-probe-retry')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('dashboard-login-submit')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('dashboard-login-error')),
          findsOneWidget,
        );
        expect(secretCalls, 1);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
  );
  for (final mode in [AuthMode.unknown, AuthMode.sessionToken]) {
    testWidgets(
      'manual Dashboard credentials have explicit coherent mode from ${mode.name}',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = <String, String>{};
        const channel = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              final args = (call.arguments as Map?) ?? {};
              if (call.method == 'readAll') return storage;
              if (call.method == 'read') return storage[args['key']];
              if (call.method == 'write') storage[args['key']] = args['value'];
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
        final initial = conn(mode: mode);
        await manager.upsertConnection(initial);
        tester.view.physicalSize = const Size(1000, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          app(InstanceEditScreen(connManager: manager, initial: initial)),
        );
        await tester.pumpAndSettle();
        final selector = find.byKey(
          const ValueKey('dashboard-manual-auth-mode'),
        );
        await openEditorAdvanced(tester);
        expect(selector, findsOneWidget);
        await tester.ensureVisible(selector);
        await tester.tap(selector);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Username and password'));
        await tester.pumpAndSettle();
        await revealEditorControl(
          tester,
          find.byKey(const ValueKey('dashboard-manual-user')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('dashboard-manual-user')),
          'synthetic-user',
        );
        await tester.enterText(
          find.byKey(const ValueKey('dashboard-manual-password')),
          'synthetic-password',
        );
        final save = find.byKey(const ValueKey('instance-save')).last;
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        final saved = manager.getConnections().single;
        expect(saved.dashboardAuthMode, AuthMode.basicAuth);
        final secrets = await manager.getDashboardSecrets(saved.id);
        expect(secrets.username, 'synthetic-user');
        expect(secrets.password, 'synthetic-password');
        final requests = <http.Request>[];
        final httpClient = MockClient((r) async {
          requests.add(r);
          expect(r.url.origin, 'http://127.0.0.1:19119');
          if (r.url.path == '/auth/password-login') {
            return http.Response(
              '{"ok":true}',
              200,
              headers: {
                'set-cookie':
                    'hermes_session_at=synthetic-cookie; HttpOnly; Path=/',
              },
            );
          }
          expect(r.headers['cookie'], contains('synthetic-cookie'));
          return http.Response('{"user_id":"synthetic-user"}', 200);
        });
        final dashboard = DashboardClient.forConnection(
          saved,
          secrets: secrets,
          httpClientOverride: httpClient,
        );
        await dashboard.apiGet('auth/me');
        dashboard.close();
        expect(requests.first.body, contains('synthetic-password'));
        expect(
          prefs.getKeys().any(
            (k) => '${prefs.get(k)}'.contains('synthetic-password'),
          ),
          isFalse,
        );
        expect(saved.apiKey, 'synthetic-gateway');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
