import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_motion.dart';
import 'package:hermes_android/core/screens/qr_scan_screen.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';

import 'support/design_shots.dart';
import 'support/onboarding_fakes.dart';

const _root = ValueKey('o2-shot-root');

String _v2(String url, {String? pass}) =>
    'hermes://pair?v=2&url=${Uri.encodeQueryComponent(url)}&user=admin'
    '${pass == null ? '' : '&pass=${Uri.encodeQueryComponent(pass)}'}';

ValueChanged<String>? _detect;
Widget _scanner(ValueChanged<String> detect, ValueChanged<bool> permission) {
  _detect = detect;
  return _camera(detect, permission);
}

Future<void> _shot(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull);
  final boundary =
      tester.renderObject(find.byKey(_root)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory('build/onboarding_shots')
      ..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void _phone(WidgetTester tester, [Size size = const Size(390, 844)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _host(
  Widget child, {
  String theme = 'dark',
  bool motion = false,
  double scale = 1,
}) => RepaintBoundary(
  key: _root,
  child: onboardingHost(child, theme: theme, motion: motion, scale: scale),
);

Widget _camera(ValueChanged<String> scan, ValueChanged<bool> permission) =>
    const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF4A5560), Color(0xFF23282E)],
        ),
      ),
    );

void main() {
  // Every screen runs with the flag as the APK is built (on by default): no
  // simpleConnectEnabled argument anywhere in this file.
  testWidgets('O2 opening, as a film strip', (tester) async {
    await loadDesignFonts();
    _phone(tester);
    OnboardingMotion.openingPlayed = false;
    final manager = await onboardingManager();
    await tester.pumpWidget(
      _host(
        OnboardingScreen(
          connManager: manager,
          onDone: () {},
          playOpening: true,
          scanCode: (_) async => null,
        ),
        motion: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, 'open_01');
    await tester.pump(const Duration(milliseconds: 600));
    await _shot(tester, 'open_02');
    await tester.pump(const Duration(milliseconds: 600));
    await _shot(tester, 'open_03');
    await tester.pump(const Duration(milliseconds: 1100));
    await _shot(tester, 'open_04');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox.shrink());
    OnboardingMotion.openingPlayed = true;
  });

  for (final theme in ['dark', 'light']) {
    testWidgets('ONB4 screens · $theme', (tester) async {
      await loadDesignFonts();
      // Tall enough to see the whole help page.
      _phone(tester, const Size(390, 1200));
      final manager = await onboardingManager();
      await tester.pumpWidget(
        _host(
          OnboardingScreen(
            connManager: manager,
            onDone: () {},
            diagnostics: OnboardingDiagnostics(),
            cameraBuilder: _scanner,
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();
      await _shot(tester, 'onb4_welcome_$theme');
      await tapOnboarding(tester, 'onboarding-help');
      await _shot(tester, 'onb4_help_unix_$theme');
      await tapOnboarding(tester, 'pairing-helper-windows');
      await _shot(tester, 'onb4_help_windows_$theme');
      await tapOnboarding(tester, 'onboarding-back');
      await tapOnboarding(tester, 'onboarding-manual');
      await _shot(tester, 'onb4_manual_$theme');
      Navigator.of(tester.element(find.byType(ManualConnectPage))).pop();
      await tester.pumpAndSettle();
      await tapOnboarding(tester, 'onboarding-scan');
      await _shot(tester, 'onb4_scan_$theme');
      await tapOnboarding(tester, 'pairing-helper-windows');
      await _shot(tester, 'onb4_scan_windows_$theme');
      _permission = null;
      // A code from the setup, without its password: asks it once.
      _detect!(_v2('http://192.168.1.20:9119'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await _shot(tester, 'onb4_connect_v2_no_password_$theme');
      await tapOnboarding(tester, 'onboarding-other');
      _detect!(_v2('http://192.168.1.20:9119', pass: 'synthetic-pass'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await _shot(tester, 'onb4_connect_v2_with_password_$theme');
    });

    testWidgets('O2 flow of a saved code · $theme', (tester) async {
      await loadDesignFonts();
      _phone(tester);
      final manager = await onboardingManager();
      final gate = Completer<void>();
      final diagnostics = OnboardingDiagnostics()..gate = gate;
      await tester.pumpWidget(
        _host(
          OnboardingScreen(
            connManager: manager,
            onDone: () {},
            diagnostics: diagnostics,
            initialLink: fakeFullPairing,
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();
      await _shot(tester, 'o2_confirm_$theme');
      await tapOnboarding(tester, 'onboarding-confirm');
      await tester.pump(const Duration(milliseconds: 100));
      await _shot(tester, 'o2_verifying_$theme');
      gate.complete();
      await tester.pumpAndSettle();
      await _shot(tester, 'o2_success_$theme');
    });

    testWidgets('O2 states · $theme', (tester) async {
      await loadDesignFonts();
      _phone(tester);
      final manager = await onboardingManager();
      await tester.pumpWidget(
        _host(
          OnboardingScreen(
            connManager: manager,
            onDone: () {},
            diagnostics: OnboardingDiagnostics(
              dashboardStatus: ProbeStatus.authInvalid,
            ),
            initialLink: fakeFullPairing,
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();
      await tapOnboarding(tester, 'onboarding-confirm');
      await _shot(tester, 'o2_missing_step_$theme');

      final other = await onboardingManager();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _host(
          OnboardingScreen(
            connManager: other,
            onDone: () {},
            diagnostics: OnboardingDiagnostics(
              reachStatus: ProbeStatus.timeout,
            ),
            initialLink: fakeFullPairing,
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();
      await tapOnboarding(tester, 'onboarding-confirm');
      await _shot(tester, 'o2_unreachable_$theme');

      final saved = await onboardingManager();
      await saved.upsertConnection(
        fakeFullPairing.toDraftConnection().copyWith(id: 'already-saved'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _host(
          OnboardingScreen(
            connManager: saved,
            onDone: () {},
            diagnostics: OnboardingDiagnostics(),
            initialLink: fakeFullPairing,
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();
      await _shot(tester, 'o2_duplicate_$theme');

      // The camera of the first-run flow when the permission is refused.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _host(
          OnboardingScreen(
            connManager: await onboardingManager(),
            onDone: () {},
            cameraBuilder: _denied,
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();
      await tapOnboarding(tester, 'onboarding-scan');
      _permission!(false);
      await tester.pumpAndSettle();
      await _shot(tester, 'onb4_camera_denied_$theme');

      // The camera of Settings: no panel.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _host(const QrScanScreen(cameraBuilder: _denied), theme: theme),
      );
      await tester.pumpAndSettle();
      _permission!(false);
      await tester.pumpAndSettle();
      await _shot(tester, 'o2_camera_denied_$theme');
    });
  }

  testWidgets('ONB4 welcome at 320 dp and at 2x text', (tester) async {
    await loadDesignFonts();
    final manager = await onboardingManager();
    _phone(tester, const Size(320, 640));
    await tester.pumpWidget(
      _host(OnboardingScreen(connManager: manager, onDone: () {})),
    );
    await tester.pumpAndSettle();
    await _shot(tester, 'onb4_welcome_320');
    await tester.pumpWidget(
      _host(OnboardingScreen(connManager: manager, onDone: () {}), scale: 2),
    );
    await tester.pumpAndSettle();
    await _shot(tester, 'onb4_welcome_320_2x');
    await tapOnboarding(tester, 'onboarding-help');
    await _shot(tester, 'onb4_help_320_2x');
  });

  for (final (name, size, scale) in [
    ('320', const Size(320, 640), 1.0),
    ('320_2x', const Size(320, 640), 2.0),
  ]) {
    testWidgets('O2 confirmation and success at $name', (tester) async {
      await loadDesignFonts();
      final manager = await onboardingManager();
      _phone(tester, size);
      await tester.pumpWidget(
        _host(
          OnboardingScreen(
            connManager: manager,
            onDone: () {},
            diagnostics: OnboardingDiagnostics(),
            initialLink: fakeFullPairing,
          ),
          scale: scale,
        ),
      );
      await tester.pumpAndSettle();
      await _shot(tester, 'o2_confirm_$name');
      await tapOnboarding(tester, 'onboarding-confirm');
      await tester.pumpAndSettle();
      await _shot(tester, 'o2_success_$name');
    });
  }
}

ValueChanged<bool>? _permission;
Widget _denied(ValueChanged<String> _, ValueChanged<bool> notify) {
  _permission = notify;
  return const SizedBox();
}
