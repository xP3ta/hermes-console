import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_motion.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_scanner.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

import 'support/onboarding_fakes.dart';

OpacityAncestor _opacityOf(WidgetTester tester, Finder f) => OpacityAncestor(
  tester
      .widgetList<Opacity>(find.ancestor(of: f, matching: find.byType(Opacity)))
      .map((o) => o.opacity)
      .fold<double>(1, (a, b) => a * b),
);

class OpacityAncestor {
  const OpacityAncestor(this.value);
  final double value;
}

void main() {
  setUp(() => OnboardingMotion.openingPlayed = false);
  tearDown(() => OnboardingMotion.openingPlayed = true);

  test('the mark is drawn from the asset\'s own geometry', () {
    final svg = File('assets/branding/console_mark.svg').readAsStringSync();
    expect(svg, contains('viewBox="118 158 680 684"'));
    expect(svg, contains('M664.4,316.0 A275,275 0 1,0 664.4,684.0'));
    expect(svg, contains('stroke-width="134"'));
    expect(svg, contains('<rect x="694" y="398" width="104" height="204"'));
    expect(kMarkViewBox, const Rect.fromLTWH(118, 158, 680, 684));
    expect(kMarkArcStart, const Offset(664.4, 316.0));
    expect(kMarkArcEnd, const Offset(664.4, 684.0));
    expect(kMarkArcRadius, 275);
    expect(kMarkStroke, 134);
    expect(kMarkBar, const Rect.fromLTWH(694, 398, 104, 204));
  });

  testWidgets('a touch ends the opening on its exact end state', (
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
        motion: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final title = find.text('Conecta con tu Hermes');
    expect(_opacityOf(tester, title).value, lessThan(1));
    // Anywhere on the screen.
    await tester.tapAt(const Offset(10, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(_opacityOf(tester, title).value, 1);
    expect(find.text('CONSOLE'), findsNothing);
    // The scan button is the full pill.
    final primary = tester.widget<OnbPrimary>(
      find.byKey(const ValueKey('onboarding-scan')),
    );
    expect(primary.expand, 1);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the scan button works from the first frame', (tester) async {
    final manager = await onboardingManager();
    var scans = 0;
    await tester.pumpWidget(
      onboardingHost(
        OnboardingScreen(
          simpleConnectEnabled: false,
          connManager: manager,
          onDone: () {},
          scanCode: (_) async {
            scans++;
            return null;
          },
        ),
        motion: true,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('onboarding-scan')));
    await tester.pump();
    expect(scans, 1);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the opening plays once per process', (tester) async {
    final manager = await onboardingManager();
    Future<void> mount() async {
      await tester.pumpWidget(
        onboardingHost(
          OnboardingScreen(
            simpleConnectEnabled: false,
            connManager: manager,
            onDone: () {},
          ),
          motion: true,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    await mount();
    expect(
      _opacityOf(tester, find.text('Conecta con tu Hermes')).value,
      lessThan(1),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await mount();
    expect(_opacityOf(tester, find.text('Conecta con tu Hermes')).value, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion shows the end states and nothing runs', (
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
    await tester.pump();
    expect(_opacityOf(tester, find.text('Conecta con tu Hermes')).value, 1);
    expect(find.text('CONSOLE'), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the command types itself in, and a tap completes it', (
    tester,
  ) async {
    const command = 'echo one two three four five six seven eight nine ten';
    await tester.pumpWidget(
      onboardingHost(
        const Scaffold(body: OnbCodeBlock(command: command)),
        motion: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('█'), findsOneWidget);
    await tester.tap(find.byType(OnbCodeBlock));
    await tester.pump();
    expect(find.text(command), findsOneWidget);
    expect(find.textContaining('█'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the scanner locks onto a code, ticks, then hands it over', (
    tester,
  ) async {
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments as String);
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
    ValueChanged<String>? detected;
    final links = <Object>[];
    await tester.pumpWidget(
      onboardingHost(
        Scaffold(
          body: QrScanView(
            onBack: () {},
            onLink: links.add,
            cameraBuilder: (scan, _) {
              detected = scan;
              return const SizedBox();
            },
          ),
        ),
        motion: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 900));
    detected!(fakeFullPairing.build());
    await tester.pump(const Duration(milliseconds: 100));
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    expect(links, isEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    expect(links, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  ProgressRingPainter ring(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(
                find.byKey(const ValueKey('onboarding-ring')),
              )
              .painter!
          as ProgressRingPainter;

  testWidgets('the ring completes only as the real checks do', (tester) async {
    final manager = await onboardingManager();
    final gate = Completer<void>();
    final diagnostics = OnboardingDiagnostics()..gate = gate;
    await tester.pumpWidget(
      onboardingHost(
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
    await tester.pump(const Duration(milliseconds: 300));
    // The Dashboard is the only thing asked, and it has not answered yet.
    expect(ring(tester).progress, closeTo(0.06, 0.001));
    expect(manager.getConnections(), isEmpty);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Conectado'), findsOneWidget);
    expect(manager.getConnections(), hasLength(1));
  });

  testWidgets(
    'a failed check stops the ring, tints it and says what is missing',
    (tester) async {
      final manager = await onboardingManager();
      final gate = Completer<void>();
      final diagnostics = OnboardingDiagnostics(
        dashboardStatus: ProbeStatus.authInvalid,
      )..gate = gate;
      await tester.pumpWidget(
        onboardingHost(
          OnboardingScreen(
            simpleConnectEnabled: false,
            connManager: manager,
            onDone: () {},
            diagnostics: diagnostics,
            initialLink: fakeFullPairing,
          ),
          motion: true,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.byKey(const ValueKey('onboarding-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 480));
      final painter = ring(tester);
      final warning = Theme.of(
        tester.element(find.byKey(const ValueKey('onboarding-ring'))),
      ).hermes.warning;
      // Reachable, but the login read did not go through.
      expect(painter.progress, closeTo(1 / 3, 0.001));
      expect(painter.color, warning);
      // Never a success: the screen moves on to what is missing.
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('Falta un paso'), findsOneWidget);
      expect(find.text('Conectado'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('every controller is gone when the flow leaves', (tester) async {
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
        motion: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });
}
