// HermesLoader: the three-body loader (three dots that spin and breathe) and
// the ConsoleLoader presets that wrap it.
//
// Covers: geometry and timings of the animation, theme accent as the default
// colour (checked on painted pixels), reduce motion (still frame, no frames
// scheduled), loading-spinner semantics, the size presets of ConsoleLoader and
// contrast of the mark on the surfaces of every built-in theme.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';
import 'package:hermes_android/core/widgets/hermes_loader.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _app(
  Widget child, {
  Locale locale = const Locale('es'),
  ThemeData? theme,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    locale: locale,
    theme: theme,
    supportedLocales: Strings.supportedLocales,
    localizationsDelegates: const [
      Strings.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (context, inner) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: inner!,
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

void _near(Offset a, Offset b, [double tol = 1e-6]) {
  expect((a - b).distance, lessThan(tol), reason: '$a vs $b');
}

void main() {
  group('geometry', () {
    const s = 100.0;

    test('at rest the dots form a triangle of 30% circles', () {
      // Top dot has no delay: it starts at rest.
      final dots = HermesLoader.dotsAt(s, 0);
      expect(dots, hasLength(3));
      _near(dots[2].center, const Offset(50, 20));
      expect(dots[2].radius, closeTo(15, 1e-9));
      expect(dots[2].opacity, 1);
      // The lower ones are already part-way through a breath (negative delay).
      expect(dots[0].radius, lessThan(15));
      expect(dots[1].radius, lessThan(15));
      expect(dots[0].center.dx, lessThan(dots[1].center.dx));
      expect(dots[0].center.dy, greaterThan(dots[2].center.dy));
    });

    test('at mid-breath the dots are at 65% size, 80% opacity', () {
      // Top dot: half of the 0.8 s cycle. It moves down by 66% of its size.
      final top = HermesLoader.dotsAt(s, 0.4)[2];
      _near(top.center, const Offset(50, 20 + 0.66 * 30));
      expect(top.radius, closeTo(15 * 0.65, 1e-9));
      expect(top.opacity, closeTo(0.8, 1e-9));

      // Lower left dot reaches mid-breath at 0.16 s (delay of 0.3 cycles); it
      // moves along its column's "up", turned 60 degrees: toward the middle.
      final left = HermesLoader.dotsAt(s, 0.16)[0];
      expect(left.radius, closeTo(15 * 0.65, 1e-9));
      expect(left.opacity, closeTo(0.8, 1e-9));
      const lift = 0.66 * 30;
      _near(left.center, const Offset(15 + lift * 0.8660254, 80 - lift / 2));

      // Lower right: delay of 0.15 cycles, so mid-breath at 0.28 s, mirrored.
      final right = HermesLoader.dotsAt(s, 0.28)[1];
      expect(right.radius, closeTo(15 * 0.65, 1e-9));
      _near(right.center, const Offset(85 - lift * 0.8660254, 80 - lift / 2));
    });

    test('the breath repeats every 0.8 s and scales with the size', () {
      for (var i = 0; i < 3; i++) {
        final a = HermesLoader.dotsAt(s, 0.1 * (i + 1));
        final b = HermesLoader.dotsAt(s, 0.1 * (i + 1) + 0.8);
        for (var k = 0; k < 3; k++) {
          _near(a[k].center, b[k].center, 1e-6);
          expect(a[k].radius, closeTo(b[k].radius, 1e-6));
        }
      }
      final small = HermesLoader.dotsAt(35, 0.3);
      final big = HermesLoader.dotsAt(70, 0.3);
      for (var k = 0; k < 3; k++) {
        _near(small[k].center * 2, big[k].center, 1e-6);
        expect(small[k].radius * 2, closeTo(big[k].radius, 1e-6));
      }
    });

    test('the loop fits a whole number of turns and breaths', () {
      const loop = HermesLoader.loopPeriod;
      expect(loop.inMicroseconds % HermesLoader.spinPeriod.inMicroseconds, 0);
      expect(loop.inMicroseconds % HermesLoader.wobblePeriod.inMicroseconds, 0);
      expect(HermesLoader.spinPeriod, const Duration(seconds: 2));
      expect(HermesLoader.wobblePeriod, const Duration(milliseconds: 800));
    });
  });

  group('widget', () {
    testWidgets('has a configurable size, 36 dp by default', (tester) async {
      await tester.pumpWidget(_app(const HermesLoader()));
      expect(
        tester.getSize(find.byKey(HermesLoader.markKey)),
        const Size(36, 36),
      );
      await tester.pumpWidget(_app(const HermesLoader(size: 64)));
      expect(
        tester.getSize(find.byKey(HermesLoader.markKey)),
        const Size(64, 64),
      );
    });

    testWidgets('animates: it keeps asking for frames', (tester) async {
      await tester.pumpWidget(_app(const HermesLoader()));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.hasScheduledFrame, isTrue);
    });

    testWidgets('reduce motion: a still frame and no frames scheduled', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(const HermesLoader(), disableAnimations: true),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpAndSettle();
    });

    testWidgets('leaving reduce motion starts the animation', (tester) async {
      await tester.pumpWidget(
        _app(const HermesLoader(), disableAnimations: true),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(_app(const HermesLoader()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);
    });

    testWidgets('disposing leaves no ticker behind', (tester) async {
      await tester.pumpWidget(_app(const HermesLoader()));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(_app(const SizedBox()));
      // The framework fails the test if a ticker outlives its State.
      await tester.pumpAndSettle();
    });

    testWidgets('announces a loading spinner, localized and overridable', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      for (final (locale, text) in [
        (const Locale('es'), 'Cargando…'),
        (const Locale('en'), 'Loading…'),
      ]) {
        await tester.pumpWidget(_app(const HermesLoader(), locale: locale));
        final node = tester.getSemantics(find.byType(HermesLoader));
        expect(node.label, text);
        expect(node.role, ui.SemanticsRole.loadingSpinner);
      }
      await tester.pumpWidget(
        _app(const HermesLoader(semanticLabel: 'Conectando')),
      );
      expect(
        tester.getSemantics(find.byType(HermesLoader)).label,
        'Conectando',
      );
      handle.dispose();
    });

    for (final id in const ['hermes-console', 'github', 'phosphor', 'claude']) {
      testWidgets('paints with the theme accent ink by default ($id)', (
        tester,
      ) async {
        final theme = AppTheme.fromId(id);
        await tester.pumpWidget(
          _app(
            const HermesLoader(size: 80),
            theme: theme,
            disableAnimations: true,
          ),
        );
        final ink = await _inkedPixels(tester, theme.hermes.accentText);
        expect(ink.inked, greaterThan(100));
        expect(ink.matching, ink.inked);
      });
    }

    testWidgets('an explicit colour wins over the theme', (tester) async {
      const want = Color(0xFF123456);
      await tester.pumpWidget(
        _app(
          const HermesLoader(size: 80, color: want),
          disableAnimations: true,
        ),
      );
      final ink = await _inkedPixels(tester, want);
      expect(ink.inked, greaterThan(100));
      expect(ink.matching, ink.inked);
    });
  });

  group('ConsoleLoader presets', () {
    testWidgets('small is mark-only, 18 dp and clamps 16-20', (tester) async {
      await tester.pumpWidget(_app(const ConsoleLoader.small()));
      expect(
        tester.getSize(find.byKey(HermesLoader.markKey)),
        const Size(18, 18),
      );
      expect(find.text('Cargando…'), findsNothing);
      for (final (asked, got) in [(16.0, 16.0), (20.0, 20.0), (40.0, 20.0)]) {
        await tester.pumpWidget(_app(ConsoleLoader.small(dimension: asked)));
        expect(
          tester.getSize(find.byKey(HermesLoader.markKey)),
          Size(got, got),
        );
      }
    });

    testWidgets('medium is 32 dp; its label is optional', (tester) async {
      await tester.pumpWidget(_app(const ConsoleLoader.medium()));
      expect(
        tester.getSize(find.byKey(HermesLoader.markKey)),
        const Size(32, 32),
      );
      expect(find.text('Cargando…'), findsNothing);
      await tester.pumpWidget(
        _app(const ConsoleLoader.medium(showLabel: true)),
      );
      expect(find.text('Cargando…'), findsOneWidget);
      expect(
        tester.getRect(find.text('Cargando…')).top,
        greaterThan(tester.getRect(find.byKey(HermesLoader.markKey)).bottom),
      );
    });

    testWidgets('large is 56 dp with the label; a custom label replaces it', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const ConsoleLoader.large()));
      expect(
        tester.getSize(find.byKey(HermesLoader.markKey)),
        const Size(56, 56),
      );
      expect(find.text('Cargando…'), findsOneWidget);
      await tester.pumpWidget(
        _app(const ConsoleLoader.large(label: 'Conectando')),
      );
      expect(find.text('Conectando'), findsOneWidget);
      expect(find.text('Cargando…'), findsNothing);
    });

    testWidgets('announces a loading spinner with and without a label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      for (final loader in const [
        ConsoleLoader.small(),
        ConsoleLoader.medium(),
        ConsoleLoader.large(),
      ]) {
        await tester.pumpWidget(_app(loader, locale: const Locale('en')));
        final node = tester.getSemantics(find.byType(ConsoleLoader));
        expect(node.label, 'Loading…', reason: '$loader');
        expect(node.role, ui.SemanticsRole.loadingSpinner);
      }
      handle.dispose();
    });
  });

  test('the mark reaches 3:1 on every surface of every built-in theme', () {
    final fails = <String>[];
    for (final p in AppTheme.presets) {
      final theme = AppTheme.fromId(p.id);
      final c = theme.hermes;
      for (final (name, bg) in [
        ('background', c.background),
        ('surface', c.surface),
        ('surfaceVariant', c.surfaceVariant),
        ('scaffold', theme.scaffoldBackgroundColor),
      ]) {
        final ratio = ThemeContrast.ratio(c.accentText, bg);
        if (ratio < 3) fails.add('${p.id} $name $ratio');
      }
    }
    expect(fails, isEmpty, reason: fails.join('\n'));
  });
}

/// Pixels of the loader's mark that are opaque enough to judge, and how many
/// of them have [want] as their colour (straight alpha, so the dots' 80-100%
/// opacity does not change it).
Future<({int inked, int matching})> _inkedPixels(
  WidgetTester tester,
  Color want,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(HermesLoader.markKey),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    return data!;
  });
  int ch(double v) => (v * 255).round();
  var inked = 0;
  var matching = 0;
  for (var i = 0; i < bytes!.lengthInBytes; i += 4) {
    if (bytes.getUint8(i + 3) < 200) continue;
    inked++;
    // Allow a rounding step per channel from premultiplied rendering.
    if ((bytes.getUint8(i) - ch(want.r)).abs() <= 3 &&
        (bytes.getUint8(i + 1) - ch(want.g)).abs() <= 3 &&
        (bytes.getUint8(i + 2) - ch(want.b)).abs() <= 3) {
      matching++;
    }
  }
  return (inked: inked, matching: matching);
}
