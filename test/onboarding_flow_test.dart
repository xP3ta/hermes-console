import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/onboarding_fakes.dart';
import 'support/connection_editor_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'manual sign-in and verified chat lead to success without a second login',
    (tester) async {
      final manager = await onboardingManager();
      final diagnostics = OnboardingDiagnostics();
      var done = false;
      final client = MockClient((r) async {
        if (r.url.path == '/api/status') {
          return http.Response('{"auth_required":true}', 200);
        }
        if (r.url.path == '/api/auth/providers') {
          return http.Response(
            '{"providers":[{"name":"basic","supports_password":true}]}',
            200,
          );
        }
        if (r.url.path == '/auth/password-login') {
          return http.Response(
            '{}',
            200,
            headers: {
              'set-cookie': 'hermes_session_at=synthetic-manual-cookie; Path=/',
            },
          );
        }
        return http.Response('{"user_id":"synthetic-owner"}', 200);
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(
          onboardingHost(
            OnboardingScreen(
              simpleConnectEnabled: false,
              connManager: manager,
              onDone: () => done = true,
              diagnostics: diagnostics,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'onboarding-manual');
        for (final (key, value) in [
          ('instance-gateway-url', 'https://fixture.invalid:8642'),
        ]) {
          await revealEditorControl(tester, find.byKey(ValueKey(key)));
          await tester.enterText(find.byKey(ValueKey(key)), value);
        }
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'instance-dashboard-sign-in');
        final fields = find.descendant(
          of: find.byType(DashboardSetupScreen),
          matching: find.byType(TextField),
        );
        await tester.enterText(fields.at(0), 'synthetic-owner');
        await tester.enterText(fields.at(1), 'synthetic-manual-password');
        await tapOnboarding(tester, 'dashboard-login-submit');
        expect(manager.getConnections(), isEmpty);
        await tapOnboarding(tester, 'instance-save');
        expect(diagnostics.calls, 1);
        expect(find.byKey(const ValueKey('onboarding-sign-in')), findsNothing);
        expect(find.text('Conectado'), findsOneWidget);
        // No Gateway key was asked for, so none is stored.
        expect(manager.getConnections().single.apiKey, '');
        expect(done, isFalse);
        await tapOnboarding(tester, 'onboarding-done');
        expect(done, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
  );

  for (final language in ['es', 'en']) {
    testWidgets(
      '$language: welcome is QR first and finishes only after connection',
      (tester) async {
        final manager = await onboardingManager();
        final diagnostics = OnboardingDiagnostics();
        var done = 0;
        var scans = 0;
        await tester.pumpWidget(
          onboardingHost(
            OnboardingScreen(
              simpleConnectEnabled: false,
              connManager: manager,
              onDone: () => done++,
              diagnostics: diagnostics,
              scanCode: (_) async {
                scans++;
                return fakeFullPairing;
              },
            ),
            language: language,
          ),
        );
        await tester.pumpAndSettle();
        final s = onboardingStrings(tester);
        expect(find.text(s.o2WelcomeTitle), findsOneWidget);
        expect(find.text(s.onb4WelcomeBody), findsOneWidget);
        expect(find.byKey(const ValueKey('console-mark')), findsOneWidget);
        expect(find.byType(PageView), findsNothing);
        expect(find.text('Saltar'), findsNothing);
        expect(scans, 0);
        expect(done, 0);
        expect(manager.getConnections(), isEmpty);
        await tapOnboarding(tester, 'onboarding-scan');
        expect(scans, 1);
        expect(find.text(s.o2ConfirmFull), findsOneWidget);
        expect(diagnostics.calls, 0);
        expect(manager.getConnections(), isEmpty);
        expect(find.textContaining('synthetic-panel-password'), findsNothing);
        await tapOnboarding(tester, 'onboarding-confirm');
        expect(find.text(s.o2SuccessTitle), findsOneWidget);
        expect(diagnostics.calls, 1);
        final saved = manager.getConnections().single;
        expect(saved.dashboardAuthMode, AuthMode.basicAuth);
        final secrets = await manager.getDashboardSecrets(saved.id);
        expect(secrets.password, fakeFullPairing.dashboardPassword);
        expect(secrets.username, fakeFullPairing.dashboardUser);
        expect(
          manager.prefs.getKeys().any(
            (key) => manager.prefs
                .get(key)
                .toString()
                .contains('synthetic-panel-password'),
          ),
          isFalse,
        );
        expect(done, 0);
        await tapOnboarding(tester, 'onboarding-done');
        expect(done, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$language: manual path opens the editor, backing out completes nothing',
      (tester) async {
        final manager = await onboardingManager();
        var done = false;
        await tester.pumpWidget(
          onboardingHost(
            OnboardingScreen(
              simpleConnectEnabled: false,
              connManager: manager,
              onDone: () => done = true,
            ),
            language: language,
          ),
        );
        await tapOnboarding(tester, 'onboarding-manual');
        expect(find.byType(InstanceEditScreen), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(done, isFalse);
        expect(manager.getConnections(), isEmpty);
      },
    );

    testWidgets(
      '$language: 320 dp and 200% text, welcome, confirmation and success',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final manager = await onboardingManager();
        await tester.pumpWidget(
          onboardingHost(
            OnboardingScreen(
              simpleConnectEnabled: false,
              connManager: manager,
              onDone: () {},
              diagnostics: OnboardingDiagnostics(),
              scanCode: (_) async => fakeFullPairing,
            ),
            language: language,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tapOnboarding(tester, 'onboarding-scan');
        expect(tester.takeException(), isNull);
        await tapOnboarding(tester, 'onboarding-confirm');
        expect(tester.takeException(), isNull);
        await tapOnboarding(tester, 'onboarding-done');
      },
    );
  }

  for (final language in ['es', 'en']) {
    Widget host(Widget child) => onboardingHost(child, language: language);

    testWidgets('$language: a public HTTP code sends no credentials', (
      tester,
    ) async {
      final manager = await onboardingManager();
      final diagnostics = OnboardingDiagnostics();
      await tester.pumpWidget(
        host(
          OnboardingScreen(
            simpleConnectEnabled: false,
            connManager: manager,
            onDone: () {},
            diagnostics: diagnostics,
            initialLink: const PairingLink(
              host: '203.0.113.10',
              port: 8642,
              token: 'synthetic-chat-key',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapOnboarding(tester, 'onboarding-confirm');
      expect(
        find.text(onboardingStrings(tester).commonCleartextPublic),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('onboarding-retry')), findsOneWidget);
      expect(diagnostics.calls, 0);
      expect(manager.getConnections(), isEmpty);
      expect(manager.prefs.getBool('onboarding_done'), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    // A Dashboard that does not answer: the Gateway key is no part of it.
    for (final status in [
      ProbeStatus.timeout,
      ProbeStatus.dnsError,
      ProbeStatus.refused,
      ProbeStatus.tlsError,
    ]) {
      testWidgets(
        '$language: $status: one sentence, one retry and no saved connection',
        (tester) async {
          final manager = await onboardingManager();
          final diagnostics = OnboardingDiagnostics(reachStatus: status);
          await tester.pumpWidget(
            host(
              OnboardingScreen(
                simpleConnectEnabled: false,
                connManager: manager,
                onDone: () {},
                diagnostics: diagnostics,
                initialLink: fakeFullPairing,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tapOnboarding(tester, 'onboarding-confirm');
          final s = onboardingStrings(tester);
          expect(find.text(s.o2Unreachable), findsOneWidget);
          expect(
            find.byKey(const ValueKey('onboarding-retry')),
            findsOneWidget,
          );
          expect(manager.getConnections(), isEmpty);
          expect(manager.prefs.getBool('onboarding_done'), isNull);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final fullCode in [false, true]) {
      testWidgets(
        '$language: missing/rejected Dashboard login ($fullCode) says Falta un paso',
        (tester) async {
          final manager = await onboardingManager();
          final link = fullCode
              ? fakeFullPairing
              : const PairingLink(
                  host: 'fixture.invalid',
                  port: 8642,
                  token: 'synthetic-chat-key',
                  useHttps: true,
                );
          final client = MockClient((r) async => http.Response('{}', 503));
          await http.runWithClient(() async {
            await tester.pumpWidget(
              host(
                OnboardingScreen(
                  simpleConnectEnabled: false,
                  connManager: manager,
                  onDone: () {},
                  initialLink: link,
                  diagnostics: OnboardingDiagnostics(
                    dashboardStatus: ProbeStatus.authInvalid,
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tapOnboarding(tester, 'onboarding-confirm');
            expect(
              find.text(onboardingStrings(tester).o2MissingStep),
              findsOneWidget,
            );
            expect(find.byKey(const ValueKey('onboarding-done')), findsNothing);
            expect(manager.getConnections(), hasLength(1));
            await tapOnboarding(tester, 'onboarding-sign-in');
            expect(find.byType(DashboardSetupScreen), findsOneWidget);
            expect(manager.prefs.getBool('onboarding_done'), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          }, () => client);
        },
      );
    }

    testWidgets(
      '$language: Dashboard sign-in after a chat-only code finishes with Keystore access',
      (tester) async {
        final manager = await onboardingManager();
        final client = MockClient((r) async {
          switch (r.url.path) {
            case '/api/status':
              return http.Response('{"auth_required":true}', 200);
            case '/api/auth/providers':
              return http.Response(
                '{"providers":[{"name":"basic","supports_password":true}]}',
                200,
              );
            case '/auth/password-login':
              return http.Response(
                '{}',
                200,
                headers: {
                  'set-cookie': 'hermes_session_at=synthetic-session; Path=/',
                },
              );
            case '/api/auth/me':
              return http.Response('{"username":"synthetic-owner"}', 200);
          }
          return http.Response('{}', 404);
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(
            host(
              OnboardingScreen(
                simpleConnectEnabled: false,
                connManager: manager,
                onDone: () {},
                diagnostics: OnboardingDiagnostics(),
                initialLink: const PairingLink(
                  host: 'fixture.invalid',
                  port: 8642,
                  token: 'synthetic-chat-key',
                  useHttps: true,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tapOnboarding(tester, 'onboarding-confirm');
          final partial = manager.getConnections().single;
          await manager.saveCapabilities(
            partial.id,
            const CapabilityMatrix(
              gatewayAuthValid: CapState.yes,
              chatSupported: CapState.yes,
              dashboardAuthValid: CapState.no,
              memoryRead: CapState.no,
              configRead: CapState.no,
            ),
          );
          await tapOnboarding(tester, 'onboarding-sign-in');
          await tester.enterText(
            find.byType(TextField).at(0),
            'synthetic-owner',
          );
          await tester.enterText(
            find.byType(TextField).at(1),
            'synthetic-new-password',
          );
          await tapOnboarding(tester, 'dashboard-login-submit');
          expect(
            find.text(onboardingStrings(tester).o2SuccessTitle),
            findsOneWidget,
          );
          final saved = manager.getConnections().single;
          expect(saved.dashboardAuthMode, AuthMode.basicAuth);
          final capabilities = manager.loadCapabilities(saved.id);
          expect(capabilities.dashboardAuthValid, CapState.yes);
          expect(capabilities.chatSupported, CapState.yes);
          expect(capabilities.memoryRead, CapState.unknown);
          expect(capabilities.configRead, CapState.unknown);
          expect(
            (await manager.getDashboardSecrets(saved.id)).password,
            'synthetic-new-password',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }, () => client);
      },
    );

    testWidgets(
      '$language: duplicate opens the existing connection without rotating it',
      (tester) async {
        final manager = await onboardingManager();
        await manager.upsertConnection(
          fakeFullPairing.toDraftConnection().copyWith(
            id: 'already-saved',
            apiKey: 'synthetic-original',
          ),
        );
        final diagnostics = OnboardingDiagnostics();
        await tester.pumpWidget(
          host(
            OnboardingScreen(
              simpleConnectEnabled: false,
              connManager: manager,
              onDone: () {},
              initialLink: fakeFullPairing,
              diagnostics: diagnostics,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(onboardingStrings(tester).o2Duplicate),
          findsOneWidget,
        );
        expect(diagnostics.calls, 0);
        await tapOnboarding(tester, 'onboarding-open-existing');
        expect(
          tester
              .widget<InstanceEditScreen>(find.byType(InstanceEditScreen))
              .initial!
              .id,
          'already-saved',
        );
        expect(manager.getConnections().single.apiKey, 'synthetic-original');
      },
    );

    testWidgets(
      '$language: private HTTP credentials require explicit consent',
      (tester) async {
        final manager = await onboardingManager();
        final diagnostics = OnboardingDiagnostics();
        await tester.pumpWidget(
          host(
            OnboardingScreen(
              simpleConnectEnabled: false,
              connManager: manager,
              onDone: () {},
              diagnostics: diagnostics,
              initialLink: const PairingLink(
                host: 'hermes.local',
                port: 8642,
                token: 'synthetic-key',
                dashboardUser: 'synthetic-owner',
                dashboardPassword: 'synthetic-pass',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<OnbPrimary>(
                find.byKey(const ValueKey('onboarding-confirm')),
              )
              .onTap,
          isNull,
        );
        expect(diagnostics.calls, 0);
        await tapOnboarding(tester, 'pairing-http-consent');
        await tapOnboarding(tester, 'onboarding-confirm');
        expect(diagnostics.calls, 1);
      },
    );

    testWidgets(
      '$language: closing a partial connection reaches Home with usable chat',
      (tester) async {
        final manager = await onboardingManager();
        var completed = false;
        await tester.pumpWidget(
          host(
            OnboardingScreen(
              simpleConnectEnabled: false,
              connManager: manager,
              onDone: () => completed = true,
              initialLink: fakeFullPairing,
              diagnostics: OnboardingDiagnostics(
                dashboardStatus: ProbeStatus.authInvalid,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'onboarding-confirm');
        expect(
          find.text(onboardingStrings(tester).o2MissingStep),
          findsOneWidget,
        );
        expect(completed, isFalse);
        await tapOnboarding(tester, 'onboarding-chat-only');
        expect(completed, isTrue);
        expect(manager.getConnections(), hasLength(1));
        expect(
          manager.activeConnectionId.value,
          manager.getConnections().single.id,
        );
        expect(manager.getConnections().single.apiKey, fakeFullPairing.token);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$language: closing a confirmation never completes an empty setup',
      (tester) async {
        final manager = await onboardingManager();
        var completed = false;
        await tester.pumpWidget(
          host(
            OnboardingScreen(
              simpleConnectEnabled: false,
              connManager: manager,
              onDone: () => completed = true,
              initialLink: fakeFullPairing,
              diagnostics: OnboardingDiagnostics(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'onboarding-back');
        expect(find.byKey(const ValueKey('onboarding-scan')), findsOneWidget);
        expect(completed, isFalse);
        expect(manager.getConnections(), isEmpty);
        expect(manager.prefs.getBool('onboarding_done'), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$language: read-only server tells the truth and stores read-only access',
      (tester) async {
        final manager = await onboardingManager();
        await tester.pumpWidget(
          host(
            OnboardingScreen(
              simpleConnectEnabled: false,
              connManager: manager,
              onDone: () {},
              diagnostics: OnboardingDiagnostics(readOnly: true),
              initialLink: fakeFullPairing,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'onboarding-confirm');
        expect(find.text(onboardingStrings(tester).o2ReadOnly), findsOneWidget);
        expect(manager.getConnections().single.readOnly, isTrue);
      },
    );

    testWidgets(
      '$language: empty Home keeps its single action into the new flow',
      (tester) async {
        final manager = await onboardingManager();
        await tester.pumpWidget(
          host(HomeDashboardScreen(connManager: manager)),
        );
        await tester.pumpAndSettle();
        final s = Strings.of(tester.element(find.byType(HomeDashboardScreen)));
        expect(find.text(s.homeNoInstances), findsOneWidget);
        await tester.tap(find.text(s.homeAddInstance));
        await tester.pumpAndSettle();
        expect(find.byType(OnboardingScreen), findsOneWidget);
        expect(manager.getConnections(), isEmpty);
      },
    );

    testWidgets(
      '$language: connection progress is announced while probes wait',
      (tester) async {
        final manager = await onboardingManager();
        final held = _HeldDiagnostics();
        await tester.pumpWidget(
          host(
            OnboardingScreen(
              simpleConnectEnabled: false,
              connManager: manager,
              onDone: () {},
              diagnostics: held,
              initialLink: fakeFullPairing,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('onboarding-confirm')));
        await tester.pump();
        expect(
          find.text(onboardingStrings(tester).o2Connecting),
          findsOneWidget,
        );
        expect(manager.getConnections(), isEmpty);
        held.release.complete();
        await tester.pumpAndSettle();
        expect(
          find.text(onboardingStrings(tester).o2SuccessTitle),
          findsOneWidget,
        );
      },
    );
  }
}

class _HeldDiagnostics extends OnboardingDiagnostics {
  final release = Completer<void>();
  @override
  Future<DiagnosticsReport> run(
    Strings s,
    SavedConnection conn,
    DashboardSecrets secrets, {
    DiagnosticsStageCallback? onStage,
  }) async {
    await release.future;
    return super.run(s, conn, secrets, onStage: onStage);
  }
}
