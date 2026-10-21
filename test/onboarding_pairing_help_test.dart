import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/onboarding/manual_setup_page.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/connection_editor_actions.dart';
import 'support/onboarding_fakes.dart';

const _unixSetup =
    'curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/'
    'hermes-dashboard-setup.sh | sh';
const _windowsSetup =
    '& ([scriptblock]::Create((irm '
    'https://raw.githubusercontent.com/xP3ta/hermes-setup/main/'
    'hermes-dashboard-setup.ps1)))';

void main() {
  for (final language in ['es', 'en']) {
    testWidgets(
      '$language: the setup line of the picked system, shown and copied',
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
            OnboardingScreen(
              simpleConnectEnabled: false,
              connManager: manager,
              onDone: () {},
            ),
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
          _unixSetup,
        );
        expect(find.text(s.onb4StepOpenTerminal), findsOneWidget);
        await tapOnboarding(tester, 'pairing-helper-windows');
        expect(
          tester.widget<OnbCodeBlock>(find.byType(OnbCodeBlock)).command,
          _windowsSetup,
        );
        expect(find.text(s.onb4StepOpenPowerShell), findsOneWidget);
        await tapOnboarding(tester, 'pairing-helper-copy');
        expect(copied, _windowsSetup);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('the steps are numbered, the way out is typing it by hand', (
    tester,
  ) async {
    final manager = await onboardingManager();
    await tester.pumpWidget(
      onboardingHost(
        OnboardingScreen(
          simpleConnectEnabled: false,
          connManager: manager,
          onDone: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapOnboarding(tester, 'onboarding-help');
    expect(find.text('Instala Hermes'), findsOneWidget);
    for (final n in ['1', '2', '3']) {
      expect(find.text(n), findsOneWidget);
    }
    expect(find.textContaining('Pídeselo'), findsNothing);
    // The old script and its "I can see the code" step are gone.
    expect(find.byKey(const ValueKey('onboarding-code-visible')), findsNothing);
    await tapOnboarding(tester, 'onboarding-help-manual');
    expect(find.byType(InstanceEditScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Instala Hermes'), findsOneWidget);
    expect(manager.getConnections(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the documented by-hand recipe lives in the manual screen', (
    tester,
  ) async {
    final manager = await onboardingManager();
    await tester.pumpWidget(
      onboardingHost(
        InstanceEditScreen(simpleConnect: false, connManager: manager),
      ),
    );
    await tester.pumpAndSettle();
    await openEditorAdvanced(tester);
    expect(
      find.byKey(const ValueKey('setup-step-dashboard-run')),
      findsNothing,
    );
    ManualSetupPage.managerForTest = manager;
    await tapOnboarding(tester, 'instance-by-hand-help');
    expect(find.byType(ManualSetupPage), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-helper-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-step-gateway-run')), findsNothing);
  });
}
