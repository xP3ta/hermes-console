// C3a: «Get your computer ready», the by-hand page and the password help
// all show the one official command, copy exactly it, and say what the
// Dashboard really does the first time.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/onboarding/manual_setup_page.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/official_dashboard_command.dart';
import 'package:hermes_android/core/widgets/command_block.dart';
import 'package:hermes_android/core/widgets/dashboard_password_help.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/onboarding_fakes.dart';

String? _copied;

void _captureClipboard(WidgetTester tester) {
  _copied = null;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        _copied = (call.arguments as Map)['text'] as String;
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
}

Future<Strings> _openHelp(WidgetTester tester, String language) async {
  tester.view.physicalSize = const Size(400, 900);
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
      ),
      language: language,
    ),
  );
  await tester.pumpAndSettle();
  await tapOnboarding(tester, 'onboarding-help');
  return Strings.of(tester.element(find.byType(OnboardingScreen)));
}

const _unix =
    'curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/'
    'hermes-dashboard-setup.sh | sh';
const _windows =
    '& ([scriptblock]::Create((irm '
    'https://raw.githubusercontent.com/xP3ta/hermes-setup/main/'
    'hermes-dashboard-setup.ps1)))';

void main() {
  test('the official command is the Hermes one, in one place', () {
    expect(kOfficialDashboardCommand, 'hermes dashboard --host 0.0.0.0');
  });

  for (final language in ['es', 'en']) {
    testWidgets('$language: help shows the command and copies exactly it', (
      tester,
    ) async {
      _captureClipboard(tester);
      final s = await _openHelp(tester, language);
      expect(
        tester.widget<OnbCodeBlock>(find.byType(OnbCodeBlock)).command,
        _unix,
      );
      await tapOnboarding(tester, 'pairing-helper-copy');
      expect(_copied, _unix);
      // The system tab changes the program and its line.
      expect(find.text(s.onb4StepOpenTerminal), findsOneWidget);
      await tapOnboarding(tester, 'pairing-helper-windows');
      expect(find.text(s.onb4StepOpenPowerShell), findsOneWidget);
      expect(
        tester.widget<OnbCodeBlock>(find.byType(OnbCodeBlock)).command,
        _windows,
      );
      // No script, no "already set up" switch, no "I can see the code".
      expect(
        find.byKey(const ValueKey('pairing-helper-prepared')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('onboarding-code-visible')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$language: help carries the intro, the safe note, the VPS note and a way out',
      (tester) async {
        final s = await _openHelp(tester, language);
        for (final note in [
          s.onb4HelpIntro,
          s.onb4HelpSafe,
          s.onb4HelpVps,
          s.onb3HelpStepScan,
        ]) {
          final finder = find.text(note, skipOffstage: false);
          expect(finder, findsOneWidget, reason: note);
        }
        // The way out is typing it by hand, never a dead end.
        await tapOnboarding(tester, 'onboarding-help-manual');
        expect(find.byType(InstanceEditScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('$language: the by-hand page is the guided setup alone', (
      tester,
    ) async {
      _captureClipboard(tester);
      final manager = await onboardingManager();
      await tester.pumpWidget(
        onboardingHost(
          ManualSetupPage(connManager: manager, simpleConnectEnabled: false),
          language: language,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(CommandBlock, skipOffstage: false),
        findsNothing,
        reason: 'the page uses the onboarding panel, not a second command',
      );
      final shown = tester
          .widgetList<Text>(find.byType(Text, skipOffstage: false))
          .map((t) => t.data ?? '')
          .join('\n')
          .toLowerCase();
      for (final word in ['api_server', 'openssl', '.env']) {
        expect(shown, isNot(contains(word)), reason: word);
      }
      await tester.ensureVisible(
        find.byKey(const ValueKey('pairing-helper-copy')),
      );
      await tester.tap(find.byKey(const ValueKey('pairing-helper-copy')));
      await tester.pump();
      expect(_copied, _unix);
    });

    testWidgets('$language: password help is the official reset recipe', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        onboardingHost(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDashboardPasswordHelp(context),
              child: const Text('open'),
            ),
          ),
          language: language,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final commands = tester
          .widgetList<CommandBlock>(find.byType(CommandBlock))
          .map((b) => b.command)
          .toList();
      expect(commands, [
        'hermes config unset dashboard.basic_auth.password_hash\n'
            'hermes dashboard --stop\n'
            '$kOfficialDashboardCommand',
      ]);
      final lines = commands.single.split('\n');
      expect(lines.indexWhere((l) => l.contains('config unset')), 0);
      expect(lines.indexWhere((l) => l.contains('--stop')), 1);
      expect(lines.indexWhere((l) => l == kOfficialDashboardCommand), 2);
      final note = Strings.of(
        tester.element(find.byType(CommandBlock)),
      ).dashPasswordHelpEnvNote;
      expect(note, contains('HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH'));
      expect(note, contains('dashboard.basic_auth.password'));
      final s = Strings.of(tester.element(find.byType(CommandBlock)));
      expect(
        find.text(s.dashPasswordHelpOthers, skipOffstage: false),
        findsOneWidget,
      );
    });
  }
}
