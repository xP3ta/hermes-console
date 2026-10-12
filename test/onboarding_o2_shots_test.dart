import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_motion.dart';
import 'package:hermes_android/core/screens/qr_scan_screen.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/pairing_link.dart';

import 'support/design_shots.dart';
import 'support/onboarding_fakes.dart';

const _root = ValueKey('o2-shot-root');

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
    testWidgets('O2 screens · $theme', (tester) async {
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
            cameraBuilder: _camera,
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();
      await _shot(tester, 'o2_welcome_$theme');
      await tapOnboarding(tester, 'onboarding-help');
      await _shot(tester, 'o2_help_$theme');
      await tapOnboarding(tester, 'onboarding-code-visible');
      await _shot(tester, 'o2_scan_$theme');
      await tapOnboarding(tester, 'onboarding-back');
      await tapOnboarding(tester, 'onboarding-back');
      // A scanned code: the confirmation.
      await tester.pumpWidget(const SizedBox.shrink());
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
              gatewayStatus: ProbeStatus.timeout,
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

  testWidgets('O2 welcome at 320 dp and at 2x text', (tester) async {
    await loadDesignFonts();
    final manager = await onboardingManager();
    _phone(tester, const Size(320, 640));
    await tester.pumpWidget(
      _host(OnboardingScreen(connManager: manager, onDone: () {})),
    );
    await tester.pumpAndSettle();
    await _shot(tester, 'o2_welcome_320');
    await tester.pumpWidget(
      _host(OnboardingScreen(connManager: manager, onDone: () {}), scale: 2),
    );
    await tester.pumpAndSettle();
    await _shot(tester, 'o2_welcome_320_2x');
    await tapOnboarding(tester, 'onboarding-help');
    await _shot(tester, 'o2_help_320_2x');
  });

  for (final (name, size, scale) in [
    ('320', const Size(320, 640), 1.0),
    ('320_2x', const Size(320, 640), 2.0),
  ]) {
    testWidgets('O2 where-it-lives chooser at $name', (tester) async {
      await loadDesignFonts();
      final manager = await onboardingManager();
      _phone(tester, size);
      await tester.pumpWidget(
        _host(
          OnboardingScreen(
            connManager: manager,
            onDone: () {},
            diagnostics: OnboardingDiagnostics(),
            initialLink: PairingLink(
              host: 'nas.local',
              port: 8642,
              token: 'synthetic-chat-key',
              useHttps: true,
              label: 'Casa',
              dashboardUrl: 'https://nas.local:9119',
              dashboardUser: 'synthetic-owner',
              dashboardPassword: 'synthetic-panel-password',
            ),
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
