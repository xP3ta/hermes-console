import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/hermes_setup_commands.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/connection_editor_actions.dart';
import 'support/onboarding_fakes.dart';

void main() {
  for (final language in ['es', 'en']) {
    testWidgets(
      '$language: one real helper command per system, setup or show again',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
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
        await tester.pumpWidget(
          onboardingHost(
            OnboardingScreen(connManager: manager, onDone: () {}),
            language: language,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'onboarding-help');
        final s = Strings.of(tester.element(find.byType(OnboardingScreen)));
        final command = find.byKey(const ValueKey('pairing-helper-command'));
        await revealEditorControl(tester, command);
        expect(
          tester.widget<OnbCodeBlock>(find.byType(OnbCodeBlock)).command,
          HermesSetupCommands.setup(SetupHostSystem.unix),
        );
        expect(find.text(s.o2StepTerminal), findsOneWidget);
        await tapOnboarding(tester, 'pairing-helper-windows');
        expect(
          tester.widget<OnbCodeBlock>(find.byType(OnbCodeBlock)).command,
          HermesSetupCommands.setup(SetupHostSystem.windows),
        );
        expect(find.text(s.o2StepPowerShell), findsOneWidget);
        await tapOnboarding(tester, 'pairing-helper-prepared');
        expect(
          tester.widget<OnbCodeBlock>(find.byType(OnbCodeBlock)).command,
          HermesSetupCommands.showCodeAgain(SetupHostSystem.windows),
        );
        await tapOnboarding(tester, 'pairing-helper-copy');
        expect(
          copied,
          HermesSetupCommands.showCodeAgain(SetupHostSystem.windows),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('the steps are numbered, the helper is asked of the computer', (
    tester,
  ) async {
    final manager = await onboardingManager();
    await tester.pumpWidget(
      onboardingHost(OnboardingScreen(connManager: manager, onDone: () {})),
    );
    await tester.pumpAndSettle();
    await tapOnboarding(tester, 'onboarding-help');
    expect(find.text('Saca el código en tu ordenador'), findsOneWidget);
    for (final n in ['1', '2', '3']) {
      expect(find.text(n), findsOneWidget);
    }
    expect(find.textContaining('Pídeselo'), findsNothing);
    // The way out of the help is the scanner, or a link, never a dead end.
    await tapOnboarding(tester, 'onboarding-code-visible');
    expect(find.byKey(const ValueKey('qr-frame')), findsOneWidget);
    await tapOnboarding(tester, 'onboarding-back');
    expect(find.text('Saca el código en tu ordenador'), findsOneWidget);
    expect(manager.getConnections(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the documented by-hand recipe lives in the manual screen', (
    tester,
  ) async {
    final manager = await onboardingManager();
    await tester.pumpWidget(
      onboardingHost(InstanceEditScreen(connManager: manager)),
    );
    await tester.pumpAndSettle();
    await openEditorAdvanced(tester);
    expect(
      find.byKey(const ValueKey('setup-step-dashboard-env')),
      findsNothing,
    );
    await tapOnboarding(tester, 'instance-by-hand-help');
    final env = find.byKey(const ValueKey('setup-step-dashboard-env'));
    await revealEditorControl(tester, env);
    expect(env, findsOneWidget);
    final run = find.byKey(const ValueKey('setup-step-gateway-run'));
    await revealEditorControl(tester, run);
    expect(run, findsOneWidget);
  });
}
