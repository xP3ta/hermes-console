import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_password_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/official_dashboard_command.dart';
import 'package:hermes_android/core/widgets/command_block.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/connection_editor_actions.dart';
import 'support/onboarding_fakes.dart';

SavedConnection _connection({bool privateHttp = false}) =>
    fakeFullPairing.toDraftConnection().copyWith(
      id: 'synthetic-password-owner',
      host: privateHttp ? 'hermes.local' : 'fixture.invalid',
      dashboardUrl: privateHttp
          ? 'http://hermes.local:9119'
          : 'https://fixture.invalid:9119',
      dashboardAuthMode: AuthMode.basicAuth,
    );

Future<void> _enterPassword(WidgetTester tester) async {
  final field = find.byKey(const ValueKey('dashboard-password-new'));
  await revealEditorControl(tester, field);
  await tester.enterText(field, 'synthetic-new-password');
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

void main() {
  setUp(DashboardClient.resetSharedPasswordSessionsForTesting);
  for (final language in ['es', 'en']) {
    Widget host(Widget child) => onboardingHost(child, language: language);

    testWidgets(
      '$language: a cached session cannot make a rejected new password look valid',
      (tester) async {
        final manager = await onboardingManager();
        final connection = _connection();
        await manager.upsertConnection(connection);
        await manager.saveCapabilities(
          connection.id,
          const CapabilityMatrix(
            gatewayAuthValid: CapState.yes,
            chatSupported: CapState.yes,
            dashboardAuthValid: CapState.no,
            memoryRead: CapState.no,
            configRead: CapState.no,
            skillsToggle: CapState.no,
            serverSourced: ['skillsToggle'],
          ),
        );
        await manager.setDashboardSecrets(
          connection.id,
          username: 'synthetic-owner',
          password: 'synthetic-old-password',
        );
        final seed = DashboardClient.forConnection(
          connection,
          secrets: const DashboardSecrets(
            username: 'synthetic-owner',
            password: 'synthetic-new-password',
          ),
          httpClientOverride: MockClient(
            (r) async => http.Response(
              '{}',
              200,
              headers: {
                'set-cookie':
                    'hermes_session_at=synthetic-cached-session; Path=/',
              },
            ),
          ),
        );
        await seed.authenticateExistingPassword();
        seed.close();
        var logins = 0;
        final client = MockClient((r) async {
          if (r.url.path == '/auth/password-login') {
            logins++;
            return http.Response('{}', 401);
          }
          // The old cookie would still be accepted, independently of the password.
          return http.Response('{"user_id":"synthetic-owner"}', 200);
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(
            host(
              DashboardPasswordScreen(
                connection: connection,
                connManager: manager,
                authorityCurrent: () => true,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _enterPassword(tester);
          await tapOnboarding(tester, 'dashboard-password-verify');
          expect(logins, 1);
          expect(
            find.byKey(const ValueKey('dashboard-password-error')),
            findsOneWidget,
          );
          expect(
            (await manager.getDashboardSecrets(connection.id)).password,
            'synthetic-old-password',
          );
          expect(
            manager.loadCapabilities(connection.id).dashboardAuthValid,
            CapState.no,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }, () => client);
      },
    );
  }
  for (final language in ['es', 'en']) {
    testWidgets('$language: local command and verify/save at 320 dp / 2x', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final manager = await onboardingManager();
      final connection = _connection();
      await manager.upsertConnection(connection);
      await manager.setDashboardSecrets(
        connection.id,
        username: 'synthetic-owner',
        password: 'synthetic-old-password',
      );
      await manager.saveCapabilities(
        connection.id,
        const CapabilityMatrix(
          gatewayAuthValid: CapState.yes,
          chatSupported: CapState.yes,
          dashboardAuthValid: CapState.no,
          memoryRead: CapState.no,
          configRead: CapState.no,
          skillsToggle: CapState.no,
          serverSourced: ['skillsToggle'],
        ),
      );
      final requests = <http.Request>[];
      final client = MockClient((r) async {
        requests.add(r);
        if (r.url.path == '/auth/password-login') {
          expect(jsonDecode(r.body)['password'], 'synthetic-new-password');
          return http.Response(
            '{}',
            200,
            headers: {
              'set-cookie': 'hermes_session_at=synthetic-cookie; Path=/',
            },
          );
        }
        expect(r.url.path, '/api/auth/me');
        return http.Response('{"user_id":"synthetic-owner"}', 200);
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(
          onboardingHost(
            DashboardPasswordScreen(
              connection: connection,
              connManager: manager,
              authorityCurrent: () => true,
            ),
            language: language,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        final s = Strings.of(
          tester.element(find.byType(DashboardPasswordScreen)),
        );
        // The only way to change the password is on the computer: the
        // screen says so and shows the setup helper's line, never a field
        // that would pretend to change it remotely.
        expect(find.text(s.sPasswordComputer), findsOneWidget);
        await tapOnboarding(tester, 'dashboard-password-how');
        // The sheet's list builds lazily at 2x: scroll the line into view.
        await tester.scrollUntilVisible(
          find.byType(CommandBlock),
          100,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('dashboard-password-help')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final command = tester
            .widget<CommandBlock>(find.byType(CommandBlock))
            .command;
        expect(command, kOfficialDashboardResetCommand);
        Navigator.of(
          tester.element(find.byType(DashboardPasswordScreen)),
        ).pop();
        await tester.pumpAndSettle();
        expect(command, isNot(contains('synthetic-old-password')));
        expect(requests, isEmpty);
        await _enterPassword(tester);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('dashboard-password-new')),
              )
              .obscureText,
          isTrue,
        );
        expect(
          (await manager.getDashboardSecrets(connection.id)).password,
          'synthetic-old-password',
        );
        await tapOnboarding(tester, 'dashboard-password-verify');
        expect(requests.map((r) => r.url.path), [
          '/auth/password-login',
          '/api/auth/me',
        ]);
        expect(
          requests.where(
            (r) => r.method == 'PUT' || r.url.path.startsWith('/bridge/'),
          ),
          isEmpty,
        );
        expect(
          (await manager.getDashboardSecrets(connection.id)).password,
          'synthetic-new-password',
        );
        final capabilities = manager.loadCapabilities(connection.id);
        expect(capabilities.dashboardAuthValid, CapState.yes);
        expect(capabilities.chatSupported, CapState.yes);
        expect(capabilities.memoryRead, CapState.unknown);
        expect(capabilities.configRead, CapState.unknown);
        expect(capabilities.skillsToggle, CapState.no);
        expect(
          manager.prefs.getKeys().any(
            (k) => manager.prefs
                .get(k)
                .toString()
                .contains('synthetic-new-password'),
          ),
          isFalse,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    });
  }

  for (final language in ['es', 'en']) {
    Widget host(Widget child) => onboardingHost(child, language: language);

    testWidgets(
      '$language: refused password preserves old access, without remote error text',
      (tester) async {
        final manager = await onboardingManager();
        final connection = _connection();
        await manager.upsertConnection(connection);
        await manager.setDashboardSecrets(
          connection.id,
          username: 'synthetic-owner',
          password: 'synthetic-old-password',
        );
        final client = MockClient(
          (r) async => http.Response('synthetic-secret-from-server', 401),
        );
        await http.runWithClient(() async {
          await tester.pumpWidget(
            host(
              DashboardPasswordScreen(
                connection: connection,
                connManager: manager,
                authorityCurrent: () => true,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _enterPassword(tester);
          await tapOnboarding(tester, 'dashboard-password-verify');
          expect(
            find.byKey(const ValueKey('dashboard-password-error')),
            findsOneWidget,
          );
          expect(
            find.textContaining('synthetic-secret-from-server'),
            findsNothing,
          );
          expect(
            (await manager.getDashboardSecrets(connection.id)).password,
            'synthetic-old-password',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }, () => client);
      },
    );

    testWidgets(
      '$language: private HTTP password is not sent without explicit consent',
      (tester) async {
        final manager = await onboardingManager();
        final connection = _connection(privateHttp: true);
        await manager.upsertConnection(connection);
        await manager.setDashboardSecrets(
          connection.id,
          username: 'synthetic-owner',
          password: 'synthetic-old-password',
        );
        var calls = 0;
        final client = MockClient((r) async {
          calls++;
          return http.Response('{}', 401);
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(
            host(
              DashboardPasswordScreen(
                connection: connection,
                connManager: manager,
                authorityCurrent: () => true,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _enterPassword(tester);
          await revealEditorControl(
            tester,
            find.byKey(const ValueKey('dashboard-password-verify')),
          );
          expect(
            tester
                .widget<HermesPrimaryButton>(
                  find.byKey(const ValueKey('dashboard-password-verify')),
                )
                .onTap,
            isNull,
          );
          expect(calls, 0);
          await tapOnboarding(tester, 'dashboard-password-http-consent');
          await tapOnboarding(tester, 'dashboard-password-verify');
          expect(calls, 1);
          await tester.pumpWidget(const SizedBox.shrink());
        }, () => client);
      },
    );

    testWidgets(
      '$language: an expired editor lease cannot save a late accepted password',
      (tester) async {
        final manager = await onboardingManager();
        final connection = _connection();
        await manager.upsertConnection(connection);
        await manager.setDashboardSecrets(
          connection.id,
          username: 'synthetic-owner',
          password: 'synthetic-old-password',
        );
        var current = true;
        final held = Completer<http.Response>();
        final client = MockClient((r) async {
          if (r.url.path == '/auth/password-login') return held.future;
          return http.Response('{}', 200);
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(
            host(
              DashboardPasswordScreen(
                connection: connection,
                connManager: manager,
                authorityCurrent: () => current,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _enterPassword(tester);
          await tester.tap(
            find.byKey(const ValueKey('dashboard-password-verify')),
          );
          await tester.pump();
          current = false;
          held.complete(
            http.Response(
              '{}',
              200,
              headers: {
                'set-cookie': 'hermes_session_at=synthetic-cookie; Path=/',
              },
            ),
          );
          await tester.pumpAndSettle();
          expect(
            (await manager.getDashboardSecrets(connection.id)).password,
            'synthetic-old-password',
          );
          expect(
            find.byKey(const ValueKey('dashboard-password-error')),
            findsOneWidget,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }, () => client);
      },
    );

    testWidgets(
      '$language: failed Keystore write rolls back the entire verified access update',
      (tester) async {
        final manager = await onboardingManager();
        final connection = _connection();
        await manager.upsertConnection(connection);
        await manager.setDashboardSecrets(
          connection.id,
          username: 'synthetic-owner',
          password: 'synthetic-old-password',
        );
        final values = <String, String>{
          'dash_user_${connection.id}': 'synthetic-owner',
          'dash_pass_${connection.id}': 'synthetic-old-password',
        };
        var fail = true;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = call.arguments as Map;
            final key = args['key'] as String?;
            if (call.method == 'read') return values[key];
            if (call.method == 'write') {
              if (key == 'dash_pass_${connection.id}' && fail) {
                fail = false;
                throw PlatformException(code: 'synthetic-storage-failure');
              }
              values[key!] = args['value'] as String;
            }
            return null;
          },
        );
        final client = MockClient(
          (r) async => http.Response(
            '{}',
            200,
            headers: {
              'set-cookie': 'hermes_session_at=synthetic-cookie; Path=/',
            },
          ),
        );
        await http.runWithClient(() async {
          await tester.pumpWidget(
            host(
              DashboardPasswordScreen(
                connection: connection,
                connManager: manager,
                authorityCurrent: () => true,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _enterPassword(tester);
          await tapOnboarding(tester, 'dashboard-password-verify');
          final stored = await manager.getDashboardSecrets(connection.id);
          expect(stored.password, 'synthetic-old-password');
          expect(stored.username, 'synthetic-owner');
          expect(
            find.byKey(const ValueKey('dashboard-password-error')),
            findsOneWidget,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }, () => client);
      },
    );
  }
}
