import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/connection_editor_actions.dart';
import 'support/onboarding_fakes.dart';

void main() {
  for (final language in ['es', 'en']) {
    testWidgets(
      'S $language: every control at 320 dp / 2x, technical fields folded',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final manager = await onboardingManager();
        final connection = fakeFullPairing.toDraftConnection().copyWith(
          id: 'synthetic-connection',
          dashboardAuthMode: AuthMode.basicAuth,
        );
        await manager.upsertConnection(connection);
        await manager.setDashboardSecrets(
          connection.id,
          username: 'synthetic-owner',
          password: 'synthetic-existing-password',
        );
        final diagnostics = OnboardingDiagnostics();
        await tester.pumpWidget(
          onboardingHost(
            InstanceEditScreen(
              connManager: manager,
              initial: connection,
              diagnostics: diagnostics,
            ),
            language: language,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        final s = Strings.of(tester.element(find.byType(InstanceEditScreen)));
        expect(find.byKey(const ValueKey('instance-chat-port')), findsNothing);
        expect(
          find.byKey(const ValueKey('dashboard-manual-auth-mode')),
          findsNothing,
        );
        expect(find.textContaining('API_SERVER_KEY'), findsNothing);
        await tapOnboarding(tester, 'instance-test');
        expect(find.text(s.sReady), findsOneWidget);
        expect(diagnostics.calls, 1);
        expect(tester.takeException(), isNull);
        await openEditorAdvanced(tester);
        for (final key in [
          'instance-chat-port',
          'instance-dashboard-port',
          'instance-dashboard-url',
          'instance-gateway-token',
          'instance-note',
          'instance-read-only',
          'instance-oauth',
          'instance-copy-diagnostic',
        ]) {
          await revealEditorControl(tester, find.byKey(ValueKey(key)));
          expect(find.byKey(ValueKey(key)), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        final select = find.byKey(const ValueKey('dashboard-manual-auth-mode'));
        await revealEditorControl(tester, select);
        await tester.tap(select);
        await tester.pumpAndSettle();
        await tester.tap(find.text(s.ieDashboardAuthSession).last);
        await tester.pumpAndSettle();
        final token = find.byKey(const ValueKey('dashboard-manual-token'));
        await revealEditorControl(tester, token);
        await tester.enterText(token, 'synthetic-session-token');
        await revealEditorControl(
          tester,
          find.byKey(const ValueKey('instance-note')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('instance-note')),
          'Synthetic note',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'instance-read-only');
        expect(
          tester
              .widget<HermesPrimaryButton>(
                find.byKey(const ValueKey('instance-save')),
              )
              .onTap,
          isNotNull,
        );
        await tapOnboarding(tester, 'instance-save');
        final saved = manager.getConnections().single;
        expect(saved.id, connection.id);
        expect(saved.readOnly, isTrue);
        expect(saved.notes, 'Synthetic note');
        expect(saved.dashboardAuthMode, AuthMode.sessionToken);
        expect(
          (await manager.getDashboardSecrets(saved.id)).sessionToken,
          'synthetic-session-token',
        );
        expect(
          manager.prefs.getKeys().any(
            (k) => manager.prefs
                .get(k)
                .toString()
                .contains('synthetic-session-token'),
          ),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in ['es', 'en']) {
    Widget host(Widget child) => onboardingHost(child, language: language);

    for (final status in [
      ProbeStatus.authInvalid,
      ProbeStatus.timeout,
      ProbeStatus.dnsError,
      ProbeStatus.refused,
      ProbeStatus.tlsError,
    ]) {
      testWidgets(
        '$language: S $status is one plain sentence; details stay behind Details',
        (tester) async {
          final manager = await onboardingManager();
          final connection = fakeFullPairing.toDraftConnection().copyWith(
            id: 'synthetic-errors',
          );
          await manager.upsertConnection(connection);
          await tester.pumpWidget(
            host(
              InstanceEditScreen(
                connManager: manager,
                initial: connection,
                diagnostics: OnboardingDiagnostics(gatewayStatus: status),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tapOnboarding(tester, 'instance-test');
          final s = Strings.of(tester.element(find.byType(InstanceEditScreen)));
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('instance-connection-status')),
                )
                .data,
            status == ProbeStatus.authInvalid
                ? s.sChatKeyRejected
                : status == ProbeStatus.tlsError
                ? s.sCertificate
                : s.o2Unreachable,
          );
          expect(
            find.byKey(const ValueKey('diagnostics-technical')),
            findsNothing,
          );
          expect(find.textContaining('ProbeStatus'), findsNothing);
        },
      );
    }

    testWidgets(
      '$language: S Dashboard rejection tells what still works and offers sign-in',
      (tester) async {
        final manager = await onboardingManager();
        final connection = fakeFullPairing.toDraftConnection().copyWith(
          id: 'synthetic-panel',
        );
        await manager.upsertConnection(connection);
        await tester.pumpWidget(
          host(
            InstanceEditScreen(
              connManager: manager,
              initial: connection,
              diagnostics: OnboardingDiagnostics(
                dashboardStatus: ProbeStatus.authInvalid,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'instance-test');
        final s = Strings.of(tester.element(find.byType(InstanceEditScreen)));
        expect(find.text(s.o2MissingDashboard), findsOneWidget);
        await revealEditorControl(
          tester,
          find.byKey(const ValueKey('instance-dashboard-sign-in')),
        );
        expect(
          find.byKey(const ValueKey('instance-dashboard-sign-in')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '$language: S scan into an existing instance preserves its identity and icon',
      (tester) async {
        final manager = await onboardingManager();
        final initial = fakeFullPairing.toDraftConnection().copyWith(
          id: 'synthetic-existing',
          kind: InstanceKind.pc,
          dashboardAuthMode: AuthMode.basicAuth,
        );
        await manager.upsertConnection(initial);
        await tester.pumpWidget(
          host(
            InstanceEditScreen(
              connManager: manager,
              initial: initial,
              diagnostics: OnboardingDiagnostics(),
              scanCode: (_) async => fakeFullPairing,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'instance-scan');
        await revealEditorControl(
          tester,
          find.byKey(const ValueKey('pairing-link-summary')),
        );
        expect(
          find.byKey(const ValueKey('pairing-link-summary')),
          findsOneWidget,
        );
        expect(find.textContaining('synthetic-panel-password'), findsNothing);
        await tapOnboarding(tester, 'instance-save');
        expect(manager.getConnections(), hasLength(1));
        expect(manager.getConnections().single.id, initial.id);
        expect(manager.getConnections().single.kind, InstanceKind.pc);
        expect(
          (await manager.getDashboardSecrets(initial.id)).password,
          fakeFullPairing.dashboardPassword,
        );
      },
    );

    testWidgets(
      '$language: S delete removes only this saved connection after confirmation',
      (tester) async {
        final manager = await onboardingManager();
        final first = fakeFullPairing.toDraftConnection().copyWith(
          id: 'synthetic-first',
        );
        final second = first.copyWith(
          id: 'synthetic-second',
          host: 'other.invalid',
        );
        await manager.upsertConnection(first);
        await manager.upsertConnection(second);
        await tester.pumpWidget(
          host(InstanceEditScreen(connManager: manager, initial: first)),
        );
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'instance-delete');
        expect(manager.getConnections(), hasLength(2));
        final s = Strings.of(tester.element(find.byType(InstanceEditScreen)));
        final dialog = find.byKey(const ValueKey('hermes-dialog'));
        await tester.tap(
          find.descendant(of: dialog, matching: find.text(s.sRemove)),
        );
        await tester.pumpAndSettle();
        expect(manager.getConnections().single.id, second.id);
      },
    );

    testWidgets(
      '$language: S manual private credentials cannot be tested before consent',
      (tester) async {
        final manager = await onboardingManager();
        final diagnostics = OnboardingDiagnostics();
        await tester.pumpWidget(
          host(
            InstanceEditScreen(
              connManager: manager,
              diagnostics: diagnostics,
              prefill: SavedConnection(
                id: '',
                label: 'Synthetic',
                host: 'hermes.local',
                port: 8642,
                apiKey: '',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await openEditorAdvanced(tester);
        for (final (key, value) in [
          ('instance-gateway-token', 'synthetic-key'),
          ('dashboard-manual-user', 'synthetic-owner'),
          ('dashboard-manual-password', 'synthetic-password'),
        ]) {
          await revealEditorControl(tester, find.byKey(ValueKey(key)));
          await tester.enterText(find.byKey(ValueKey(key)), value);
        }
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'instance-test');
        expect(diagnostics.calls, 0);
        await tapOnboarding(tester, 'instance-http-consent');
        await tapOnboarding(tester, 'instance-test');
        expect(diagnostics.calls, 1);
      },
    );

    testWidgets('$language: S says when the connection is not encrypted', (
      tester,
    ) async {
      final manager = await onboardingManager();
      await tester.pumpWidget(
        host(
          InstanceEditScreen(
            connManager: manager,
            diagnostics: OnboardingDiagnostics(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final s = Strings.of(tester.element(find.byType(InstanceEditScreen)));
      final address = find.byKey(const ValueKey('instance-gateway-url'));
      final privateNote = find.byKey(
        const ValueKey('instance-cleartext-private'),
      );
      final publicNote = find.byKey(
        const ValueKey('instance-cleartext-public'),
      );
      expect(privateNote, findsNothing);
      expect(publicNote, findsNothing);
      await tester.enterText(address, 'https://hermes.example.com');
      await tester.pumpAndSettle();
      expect(privateNote, findsNothing);
      expect(publicNote, findsNothing);
      await tester.enterText(address, 'http://hermes.local:8642');
      await tester.pumpAndSettle();
      expect(privateNote, findsOneWidget);
      expect(find.text(s.commonCleartextPrivate), findsOneWidget);
      await tester.enterText(address, 'http://hermes.example.com:8642');
      await tester.pumpAndSettle();
      expect(publicNote, findsOneWidget);
      expect(find.text(s.commonCleartextPublic), findsOneWidget);
    });

    testWidgets(
      '$language: S pasting another address drops the code\'s Dashboard access, just like typing',
      (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? {'text': 'https://other.invalid:8642'}
              : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final manager = await onboardingManager();
        await tester.pumpWidget(
          host(
            InstanceEditScreen(
              connManager: manager,
              initialLink: fakeFullPairing,
              diagnostics: OnboardingDiagnostics(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final address = find.byKey(const ValueKey('instance-gateway-url'));
        await revealEditorControl(tester, address);
        final s = Strings.of(tester.element(find.byType(InstanceEditScreen)));
        final paste = find.descendant(
          of: address,
          matching: find.byTooltip(s.sPaste),
        );
        expect(paste.hitTestable(), findsOneWidget);
        await tester.tap(paste);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('pairing-link-summary')),
          findsNothing,
        );
        await tapOnboarding(tester, 'instance-save');
        final saved = manager.getConnections().single;
        final secrets = await manager.getDashboardSecrets(saved.id);
        expect(saved.host, 'other.invalid');
        expect(saved.dashboardAuthMode, isNot(AuthMode.basicAuth));
        expect(secrets.username, isNull);
        expect(secrets.password, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$language: S diagnostic copy omits remote details and server model names',
      (tester) async {
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final manager = await onboardingManager();
        final connection = fakeFullPairing.toDraftConnection().copyWith(
          id: 'synthetic-copy',
        );
        await manager.upsertConnection(connection);
        await tester.pumpWidget(
          host(
            InstanceEditScreen(
              connManager: manager,
              initial: connection,
              diagnostics: _PrivateDiagnostic(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'instance-test');
        await openEditorAdvanced(tester);
        await tapOnboarding(tester, 'instance-copy-diagnostic');
        expect(copied, isNotNull);
        expect(copied, isNot(contains('synthetic-secret')));
        expect(copied, isNot(contains('private.invalid')));
        final s = Strings.of(tester.element(find.byType(InstanceEditScreen)));
        expect(copied, contains(s.ieProbeSessions));
        await tester.pump(const Duration(seconds: 10));
      },
    );

    testWidgets(
      '$language: S ports change the actual destinations, and invalid ports stop requests',
      (tester) async {
        final manager = await onboardingManager();
        final diagnostics = OnboardingDiagnostics();
        await tester.pumpWidget(
          host(
            InstanceEditScreen(
              connManager: manager,
              prefill: fakeFullPairing.toDraftConnection().copyWith(
                id: '',
                apiKey: '',
              ),
              diagnostics: diagnostics,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final key = find.byKey(const ValueKey('instance-gateway-token'));
        await revealEditorControl(tester, key);
        await tester.enterText(key, 'synthetic-manual-key');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await openEditorAdvanced(tester);
        final chatPort = find.byKey(const ValueKey('instance-chat-port'));
        await revealEditorControl(tester, chatPort);
        await tester.enterText(chatPort, '18642');
        final dashboardPort = find.byKey(
          const ValueKey('instance-dashboard-port'),
        );
        await revealEditorControl(tester, dashboardPort);
        await tester.enterText(dashboardPort, '19119');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'instance-test');
        expect(diagnostics.calls, 1);
        expect(diagnostics.target!.gatewayUrl, 'https://fixture.invalid:18642');
        expect(
          diagnostics.target!.effectiveDashboardUrl,
          'https://fixture.invalid:19119',
        );
        await revealEditorControl(tester, chatPort);
        await tester.enterText(chatPort, '70000');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'instance-test');
        expect(diagnostics.calls, 1, reason: 'no request for an invalid port');
        final s = Strings.of(tester.element(find.byType(InstanceEditScreen)));
        expect(find.text(s.sInvalidPort), findsOneWidget);
        await tapOnboarding(tester, 'instance-save');
        expect(manager.getConnections(), isEmpty);
        await revealEditorControl(tester, chatPort);
        await tester.enterText(chatPort, '18643');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(
          find.text(s.sInvalidPort),
          findsNothing,
          reason: 'correcting a field dismisses its previous error',
        );
        await tapOnboarding(tester, 'instance-test');
        expect(diagnostics.calls, 2);
        expect(diagnostics.target!.gatewayUrl, 'https://fixture.invalid:18643');
        expect(find.text(s.sReady), findsOneWidget);
        await tapOnboarding(tester, 'instance-save');
        expect(manager.getConnections().single.port, 18643);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$language: S discards a probe if its saved credentials rotate while it waits',
      (tester) async {
        final manager = await onboardingManager();
        final initial = fakeFullPairing.toDraftConnection().copyWith(
          id: 'synthetic-held-probe',
        );
        await manager.upsertConnection(initial);
        final held = _HeldDiagnostic();
        await tester.pumpWidget(
          host(
            InstanceEditScreen(
              connManager: manager,
              initial: initial,
              diagnostics: held,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('instance-test')));
        for (var frame = 0; frame < 10 && !held.entered.isCompleted; frame++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(held.entered.isCompleted, isTrue);
        await manager.updateApiKey(initial.id, 'synthetic-rotated-key');
        final s = Strings.of(tester.element(find.byType(InstanceEditScreen)));
        held.answer.complete(
          await OnboardingDiagnostics().run(
            s,
            initial,
            const DashboardSecrets(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(s.sConnectionChanged), findsOneWidget);
        expect(find.text(s.sReady), findsNothing);
        expect(manager.loadCapabilities(initial.id).checkedAtMs, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final language in ['es', 'en']) {
    testWidgets('S $language: kind row and local chat mode remain usable', (
      tester,
    ) async {
      final manager = await onboardingManager();
      final initial = fakeFullPairing.toDraftConnection().copyWith(
        id: 'synthetic-icons',
        kind: InstanceKind.localhost,
      );
      await manager.upsertConnection(initial);
      await tester.pumpWidget(
        onboardingHost(
          InstanceEditScreen(connManager: manager, initial: initial),
          language: language,
        ),
      );
      await tester.pumpAndSettle();
      final s = Strings.of(tester.element(find.byType(InstanceEditScreen)));
      // The kind row is in the first block, with Advanced still folded; a
      // saved on-device kind keeps its tile next to the four on offer.
      expect(find.byKey(const ValueKey('instance-chat-port')), findsNothing);
      for (final label in [
        s.o2KindHome,
        s.o2KindServer,
        s.o2KindPrivate,
        s.o2KindComputer,
        s.sIconTerminal,
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await openEditorAdvanced(tester);
      await tapOnboarding(tester, 'instance-local-chat-mode');
      expect(find.text(s.ieLocalModeAuto).last, findsOneWidget);
      expect(find.text(s.ieLocalModeSimple).last, findsOneWidget);
      expect(find.text(s.ieLocalModeAgent).last, findsOneWidget);
      await tester.tap(find.text(s.ieLocalModeSimple).last);
      await tester.pumpAndSettle();
      await tapOnboarding(tester, 'instance-save');
      final saved = manager.getConnections().single;
      expect(saved.id, initial.id);
      expect(saved.kind, InstanceKind.localhost);
      expect(saved.localChatMode, LocalChatMode.simple);
      expect(saved.gatewayUrl, initial.gatewayUrl);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _PrivateDiagnostic extends OnboardingDiagnostics {
  @override
  Future<DiagnosticsReport> run(
    Strings s,
    SavedConnection connection,
    DashboardSecrets secrets, {
    DiagnosticsStageCallback? onStage,
  }) async => DiagnosticsReport(
    gateway: const [
      ProbeResult(
        name: 'sessions',
        status: ProbeStatus.ok,
        detail: 'synthetic-secret private.invalid',
      ),
    ],
    dashboard: const [],
    matrix: const CapabilityMatrix(),
    suggestions: const ['private.invalid'],
    serverCapabilities: const ServerCapabilities(model: 'private.invalid'),
    ranAt: DateTime(2026),
  );
}

class _HeldDiagnostic extends OnboardingDiagnostics {
  final entered = Completer<void>();
  final answer = Completer<DiagnosticsReport>();

  @override
  Future<DiagnosticsReport> run(
    Strings s,
    SavedConnection connection,
    DashboardSecrets secrets, {
    DiagnosticsStageCallback? onStage,
  }) {
    entered.complete();
    return answer.future;
  }
}
