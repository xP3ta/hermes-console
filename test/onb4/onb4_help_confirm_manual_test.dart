// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// ONB4: the help (intro, safe, one VPS note), the confirmation without the
// "where does it live" question and with the password asked once, Connect by
// hand with the new text, and the search gone for real.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/screens/recover_access_page.dart';
import 'package:hermes_android/core/widgets/instance_kind_picker.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/onboarding_fakes.dart';

String _v2(String url, {String? pass}) =>
    'hermes://pair?v=2&url=${Uri.encodeQueryComponent(url)}&user=admin'
    '${pass == null ? '' : '&pass=${Uri.encodeQueryComponent(pass)}'}';

ValueChanged<String>? _detect;
Widget _camera(ValueChanged<String> detect, ValueChanged<bool> _) {
  _detect = detect;
  return const SizedBox();
}

Future<Strings> _open(
  WidgetTester tester,
  String language, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    onboardingHost(
      OnboardingScreen(
        connManager: await onboardingManager(),
        onDone: () {},
        playOpening: false,
        cameraBuilder: _camera,
      ),
      language: language,
    ),
  );
  await tester.pumpAndSettle();
  return onboardingStrings(tester);
}

Future<void> _scanned(WidgetTester tester, String link) async {
  await tapOnboarding(tester, 'onboarding-scan');
  _detect!(link);
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

Finder _anyKind() => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey &&
      '${(w.key as ValueKey).value}'.startsWith('instance-kind-'),
);

void main() {
  const old = {
    'es': [
      'Recomendado: Tailscale. Cifra la conexión y funciona fuera de casa.',
      'En casa sin Tailscale, la contraseña viaja sin cifrar por tu Wi‑Fi.',
      'Si tu Hermes está en un servidor de internet (no en tu casa), no uses esta línea: usa Tailscale.',
      'Tengo un enlace',
    ],
    'en': [
      'Recommended: Tailscale. It encrypts the connection and works away from home.',
      'At home without Tailscale, the password travels unencrypted over your Wi‑Fi.',
      "If your Hermes runs on an internet server (not at home), don't use this line: use Tailscale.",
      'I have a link',
    ],
  };
  for (final language in ['es', 'en']) {
    testWidgets('$language: the help has intro, safe box and one VPS note', (
      tester,
    ) async {
      final s = await _open(tester, language);
      await tapOnboarding(tester, 'onboarding-help');
      for (final text in [
        s.onb4HelpTitle,
        s.onb4HelpIntro,
        s.onb4HelpSafeTitle,
        s.onb4HelpSafe,
        s.onb4HelpVps,
        s.onb4StepOpenTerminal,
        s.onb4StepWhere,
        s.onb3HelpStepScan,
      ]) {
        expect(
          find.text(text, skipOffstage: false),
          findsOneWidget,
          reason: text,
        );
      }
      await tapOnboarding(tester, 'pairing-helper-windows');
      expect(find.text(s.onb4StepOpenPowerShell), findsOneWidget);
      for (final gone in old[language]!) {
        expect(
          find.text(gone, skipOffstage: false),
          findsNothing,
          reason: gone,
        );
      }
      expect(find.byKey(const ValueKey('onboarding-paste')), findsNothing);
      expect(
        find.byKey(const ValueKey('onboarding-help-scan')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('onboarding-help-manual')),
        findsOneWidget,
      );
      expect(find.textContaining('0.0.0.0', skipOffstage: false), findsNothing);
    });

    testWidgets('$language: a v2 code without password asks for it at once', (
      tester,
    ) async {
      final s = await _open(tester, language);
      await _scanned(tester, _v2('http://192.168.1.20:9119'));
      expect(find.text(s.onb4HadPassword), findsOneWidget);
      expect(find.byKey(const ValueKey('onb3-password')), findsOneWidget);
      // «I don't know it» is there BEFORE any rejection.
      expect(find.byKey(const ValueKey('onb3-wrong-password')), findsNothing);
      expect(find.byKey(const ValueKey('onb3-recover')), findsOneWidget);
      expect(find.text(s.dashboardSetupForgotPassword), findsOneWidget);
      await tapOnboarding(tester, 'onb3-recover');
      expect(find.byType(RecoverAccessPage), findsOneWidget);
      // Nobody is asked where the Hermes lives.
      expect(find.byType(InstanceKindPicker), findsNothing);
      expect(_anyKind(), findsNothing);
    });

    testWidgets('$language: a v2 code with its password asks nothing', (
      tester,
    ) async {
      final s = await _open(tester, language);
      await _scanned(tester, _v2('http://192.168.1.20:9119', pass: 'x-canary'));
      expect(find.text(s.onb4HadPassword), findsNothing);
      expect(find.byKey(const ValueKey('onb3-password')), findsNothing);
      expect(find.byKey(const ValueKey('onb3-recover')), findsNothing);
      expect(find.byType(InstanceKindPicker), findsNothing);
      expect(_anyKind(), findsNothing);
    });

    testWidgets('$language: Connect by hand says what the setup showed', (
      tester,
    ) async {
      final s = await _open(tester, language);
      await tapOnboarding(tester, 'onboarding-manual');
      expect(find.text(s.onb4ManualBody), findsOneWidget);
      expect(find.text(s.onb4AddressLabel), findsWidgets);
      expect(find.text(s.onb3DontKnow), findsOneWidget);
      // «I don't know these» goes to the install help.
      await tapOnboarding(tester, 'manual-dont-know');
      expect(find.byType(ManualConnectPage), findsNothing);
      expect(find.text(s.onb4HelpTitle), findsOneWidget);
    });
  }

  test('no arb says the password was created at install time', () {
    for (final f in ['es', 'en']) {
      final text = File('lib/l10n/app_$f.arb').readAsStringSync();
      expect(text, isNot(contains('creaste al instalarlo')));
      expect(text, isNot(contains('you created when you installed')));
      expect(text, isNot(contains('onb3ManualBody')));
      // The 31 search keys are gone; the two that stayed were renamed.
      expect(
        RegExp(r'"sc(?!h|1215)[A-Z]\w*"').allMatches(text),
        isEmpty,
        reason: f,
      );
      expect(text, contains('"onb4AddressLabel"'));
    }
    expect(
      File('lib/l10n/app_es.arb').readAsStringSync(),
      contains('que te mostró la instalación al terminar'),
    );
  });

  test('the search is gone and nothing imports it', () {
    for (final path in [
      'lib/core/screens/onboarding/simple_connect_screen.dart',
      'lib/core/services/simple_connect/lan_discovery.dart',
    ]) {
      expect(File(path).existsSync(), isFalse, reason: path);
    }
    final libs = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final f in libs) {
      final text = f.readAsStringSync();
      expect(
        text,
        isNot(contains('simple_connect_screen.dart')),
        reason: f.path,
      );
      expect(text, isNot(contains('lan_discovery.dart')), reason: f.path);
      expect(text, isNot(contains('LanDiscovery')), reason: f.path);
    }
    // The pieces Connect by hand needs live in one file of their own.
    final manual = File(
      'lib/core/screens/onboarding/manual_connect_page.dart',
    ).readAsStringSync();
    expect(manual, contains("services/dashboard_address.dart'"));
  });

  test('the old search command is not in any onboarding source', () {
    final files = [
      File('lib/core/screens/onboarding_screen.dart'),
      ...Directory(
        'lib/core/screens/onboarding',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart')),
    ];
    for (final f in files) {
      expect(f.readAsStringSync(), isNot(contains('0.0.0.0')), reason: f.path);
    }
    for (final f in ['es', 'en']) {
      final text = File('lib/l10n/app_$f.arb').readAsStringSync();
      expect(text, isNot(contains('hermes dashboard --host 0.0.0.0')));
    }
  });
}
