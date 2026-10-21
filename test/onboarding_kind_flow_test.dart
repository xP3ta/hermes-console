import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screens/gateway_manager_screen.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:hermes_android/core/widgets/instance_kind_picker.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/connection_editor_actions.dart';
import 'support/onboarding_fakes.dart';

Finder _tile(InstanceKind kind) =>
    find.byKey(ValueKey('instance-kind-${kind.storageKey}'));

/// The kinds whose tile is marked selected, read from semantics.
Set<InstanceKind> _selected(WidgetTester tester) => {
  for (final kind in [...kOfferedInstanceKinds, InstanceKind.localhost])
    if (_tile(kind).evaluate().isNotEmpty &&
        tester.getSemantics(_tile(kind)).flagsCollection.isSelected ==
            Tristate.isTrue)
      kind,
};

PairingLink _link(String host) => PairingLink(
  host: host,
  port: 8642,
  token: 'synthetic-chat-key',
  useHttps: true,
  label: 'Casa',
  dashboardUrl: 'https://$host:9119',
  dashboardUser: 'synthetic-owner',
  dashboardPassword: 'synthetic-panel-password',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final language in ['es', 'en']) {
    testWidgets(
      '$language: the confirmation asks no kind, the one from the address is '
      'saved, shown on success and in the list of Hermes',
      (tester) async {
        final handle = tester.ensureSemantics();
        final manager = await onboardingManager();
        await tester.pumpWidget(
          onboardingHost(
            OnboardingScreen(
              connManager: manager,
              onDone: () {},
              diagnostics: OnboardingDiagnostics(),
              scanCode: (_) async => _link('nas.local'),
            ),
            language: language,
          ),
        );
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'onboarding-scan');
        final s = onboardingStrings(tester);
        expect(find.text(s.o2ConfirmFull), findsOneWidget);
        // ONB4: nobody is asked where the Hermes lives; the kind comes from
        // the address (a .local name lives at home) and the editor keeps
        // the picker.
        for (final kind in [...kOfferedInstanceKinds, InstanceKind.localhost]) {
          expect(_tile(kind), findsNothing);
        }
        expect(manager.getConnections(), isEmpty);

        await tapOnboarding(tester, 'onboarding-confirm');
        expect(find.text(s.o2SuccessTitle), findsOneWidget);
        final saved = manager.getConnections().single;
        expect(saved.kind, InstanceKind.homelab);

        // Success: the chosen icon beside the Hermes' name.
        final identity = find.byKey(const ValueKey('onboarding-identity'));
        expect(identity, findsOneWidget);
        expect(
          find.descendant(
            of: identity,
            matching: find.byIcon(instanceKindIcon(InstanceKind.homelab)),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: identity, matching: find.text('Casa')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: identity,
            matching: find.text(instanceKindLabel(s, InstanceKind.homelab)),
          ),
          findsOneWidget,
        );

        // The list of Hermes leads with the same icon.
        await tester.pumpWidget(
          onboardingHost(
            GatewayManagerScreen(connManager: manager),
            language: language,
          ),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final row = find.byKey(ValueKey('hermes-connection-${saved.id}'));
        expect(row, findsOneWidget);
        expect(
          find.descendant(
            of: row,
            matching: find.byIcon(instanceKindIcon(InstanceKind.homelab)),
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        handle.dispose();
      },
    );
  }

  testWidgets('an untouched choice is the default and is saved as such', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final manager = await onboardingManager();
    await tester.pumpWidget(
      onboardingHost(
        OnboardingScreen(
          connManager: manager,
          onDone: () {},
          diagnostics: OnboardingDiagnostics(),
          scanCode: (_) async => fakeFullPairing,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapOnboarding(tester, 'onboarding-scan');
    expect(_tile(InstanceKind.vps), findsNothing);
    await tapOnboarding(tester, 'onboarding-confirm');
    expect(manager.getConnections().single.kind, InstanceKind.vps);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('onboarding-identity')),
        matching: find.byIcon(instanceKindIcon(InstanceKind.vps)),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
  });

  for (final (host, expected) in [
    ('192.168.1.20', InstanceKind.homelab),
    ('100.64.0.9', InstanceKind.tailscale),
    ('host.tail1234.ts.net', InstanceKind.tailscale),
    ('hermes.example.com', InstanceKind.vps),
  ]) {
    testWidgets('a code for $host saves ${expected.name}', (tester) async {
      final handle = tester.ensureSemantics();
      final manager = await onboardingManager();
      await tester.pumpWidget(
        onboardingHost(
          OnboardingScreen(
            connManager: manager,
            onDone: () {},
            diagnostics: OnboardingDiagnostics(),
            scanCode: (_) async => _link(host),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapOnboarding(tester, 'onboarding-scan');
      await tapOnboarding(tester, 'onboarding-confirm');
      expect(manager.getConnections().single.kind, expected);
      await tester.pumpWidget(const SizedBox.shrink());
      handle.dispose();
    });
  }

  for (final (width, scale) in [(320.0, 1.0), (320.0, 2.0)]) {
    testWidgets(
      'the confirmation at ${width.toInt()} dp and x$scale text: every word '
      'shows and Connect stays reachable',
      (tester) async {
        tester.view.physicalSize = Size(width, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final manager = await onboardingManager();
        await tester.pumpWidget(
          onboardingHost(
            OnboardingScreen(
              connManager: manager,
              onDone: () {},
              diagnostics: OnboardingDiagnostics(),
              scanCode: (_) async => _link('nas.local'),
            ),
            scale: scale,
          ),
        );
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'onboarding-scan');
        expect(tester.takeException(), isNull);
        await tapOnboarding(tester, 'onboarding-confirm');
        expect(manager.getConnections().single.kind, InstanceKind.homelab);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final language in ['es', 'en']) {
    testWidgets(
      '$language: S puts the same row in the first block, outside Advanced, '
      'and a typed address picks the default',
      (tester) async {
        final handle = tester.ensureSemantics();
        final manager = await onboardingManager();
        await tester.pumpWidget(
          onboardingHost(
            InstanceEditScreen(connManager: manager),
            language: language,
          ),
        );
        await tester.pumpAndSettle();
        // Advanced is folded and the row is there anyway.
        expect(find.byKey(const ValueKey('instance-chat-port')), findsNothing);
        expect(find.byKey(const ValueKey('instance-icon')), findsOneWidget);
        for (final kind in kOfferedInstanceKinds) {
          expect(_tile(kind), findsOneWidget);
        }
        expect(_tile(InstanceKind.localhost), findsNothing);
        // The row lives in the block that asks where the Hermes is.
        final s = Strings.of(tester.element(find.byType(InstanceEditScreen)));
        expect(find.text(s.sWhere), findsOneWidget);
        expect(
          tester.getTopLeft(_tile(InstanceKind.homelab)).dy,
          greaterThan(tester.getTopLeft(find.text(s.sWhere)).dy),
        );
        // Right under the name and the address, in the same block.
        expect(
          tester.getTopLeft(_tile(InstanceKind.homelab)).dy,
          greaterThan(
            tester
                .getBottomLeft(
                  find.byKey(const ValueKey('instance-gateway-url')),
                )
                .dy,
          ),
        );

        Future<void> type(String address) async {
          await tester.enterText(
            find.byKey(const ValueKey('instance-gateway-url')),
            address,
          );
          await tester.pumpAndSettle();
          // A cleartext warning under the address can push the row down.
          await revealEditorControl(tester, _tile(InstanceKind.homelab));
        }

        await type('192.168.1.5');
        expect(_selected(tester), {InstanceKind.homelab});
        await type('100.64.0.5');
        expect(_selected(tester), {InstanceKind.tailscale});
        await type('hermes.example.com');
        expect(_selected(tester), {InstanceKind.vps});
        await type('localhost');
        expect(_selected(tester), {InstanceKind.pc});
        // Once chosen by hand, the address stops deciding.
        await revealEditorControl(tester, _tile(InstanceKind.homelab));
        await tester.tap(_tile(InstanceKind.homelab));
        await tester.pumpAndSettle();
        await type('hermes.example.com');
        expect(_selected(tester), {InstanceKind.homelab});
        await tester.pumpWidget(const SizedBox.shrink());
        handle.dispose();
      },
    );
  }

  testWidgets(
    'S for a saved Hermes: the row shows its kind and saves a change',
    (tester) async {
      final handle = tester.ensureSemantics();
      final manager = await onboardingManager();
      final initial = fakeFullPairing.toDraftConnection().copyWith(
        id: 'synthetic-kind-edit',
        kind: InstanceKind.pc,
      );
      await manager.upsertConnection(initial);
      await tester.pumpWidget(
        onboardingHost(
          InstanceEditScreen(connManager: manager, initial: initial),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('instance-chat-port')), findsNothing);
      await revealEditorControl(tester, _tile(InstanceKind.pc));
      expect(_selected(tester), {InstanceKind.pc});
      await revealEditorControl(tester, _tile(InstanceKind.homelab));
      await tester.tap(_tile(InstanceKind.homelab));
      await tester.pumpAndSettle();
      expect(_selected(tester), {InstanceKind.homelab});
      await tapOnboarding(tester, 'instance-save');
      expect(manager.getConnections().single.kind, InstanceKind.homelab);
      await tester.pumpWidget(const SizedBox.shrink());
      handle.dispose();
    },
  );

  testWidgets('S keeps showing a saved on-device kind', (tester) async {
    final handle = tester.ensureSemantics();
    final manager = await onboardingManager();
    final initial = fakeFullPairing.toDraftConnection().copyWith(
      id: 'synthetic-kind-local',
      kind: InstanceKind.localhost,
    );
    await manager.upsertConnection(initial);
    await tester.pumpWidget(
      onboardingHost(
        InstanceEditScreen(connManager: manager, initial: initial),
      ),
    );
    await tester.pumpAndSettle();
    expect(_tile(InstanceKind.localhost), findsOneWidget);
    expect(_selected(tester), {InstanceKind.localhost});
    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
  });
}
