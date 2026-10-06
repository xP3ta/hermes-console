// ConsoleLoader: the branded loading state (Console "C" with a blinking
// terminal cursor + "Cargando…"/"Loading…").
//
// Covers: every size renders at its contract dimension, the label is
// localized, the semantics announce a loading spinner, the blink is capped at
// 30 fps and only repaints the cursor layer, the loader stops (and shows the
// cursor) when covered, muted by TickerMode, backgrounded or under reduce
// motion, and the mark/label colours reach 3:1 / 4.5:1 in every built-in
// theme, verified on painted pixels.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';
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

/// Counts host repaints: a sibling painter under the same parent as the
/// loader. If the loader's frames leak out of its repaint boundary the host
/// is repainted too.
class _HostPainter extends CustomPainter {
  int paints = 0;
  @override
  void paint(Canvas canvas, Size size) => paints++;
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

Future<void> _pumpFor(WidgetTester tester, Duration total, {int stepMs = 4}) {
  return () async {
    final steps = total.inMilliseconds ~/ stepMs;
    for (var i = 0; i < steps; i++) {
      await tester.pump(Duration(milliseconds: stepMs));
    }
  }();
}

double _opacity(WidgetTester tester) => ConsoleLoader.debugCursorOpacity(
  tester.element(find.byType(ConsoleLoader)),
);

double _arc(WidgetTester tester) =>
    ConsoleLoader.debugArcProgress(tester.element(find.byType(ConsoleLoader)));

void main() {
  setUp(ConsoleLoader.debugResetPaintCounters);

  group('sizes', () {
    testWidgets('small is a mark-only 18 dp square with no visible label', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const ConsoleLoader.small()));
      final mark = find.byKey(ConsoleLoader.markKey);
      expect(mark, findsOneWidget);
      expect(tester.getSize(mark), const Size(18, 18));
      expect(find.text('Cargando…'), findsNothing);
    });

    testWidgets('small accepts 16–20 dp and clamps outside that band', (
      tester,
    ) async {
      for (final (asked, got) in [(16.0, 16.0), (20.0, 20.0), (40.0, 20.0)]) {
        await tester.pumpWidget(_app(ConsoleLoader.small(dimension: asked)));
        expect(
          tester.getSize(find.byKey(ConsoleLoader.markKey)),
          Size(got, got),
          reason: 'small($asked)',
        );
      }
    });

    testWidgets('medium is 32 dp; its label is optional', (tester) async {
      await tester.pumpWidget(_app(const ConsoleLoader.medium()));
      expect(
        tester.getSize(find.byKey(ConsoleLoader.markKey)),
        const Size(32, 32),
      );
      expect(find.text('Cargando…'), findsNothing);

      await tester.pumpWidget(
        _app(const ConsoleLoader.medium(showLabel: true)),
      );
      expect(find.text('Cargando…'), findsOneWidget);
      final markBox = tester.getRect(find.byKey(ConsoleLoader.markKey));
      final labelBox = tester.getRect(find.text('Cargando…'));
      expect(labelBox.top, greaterThan(markBox.bottom), reason: 'label below');
    });

    testWidgets('large is 64 dp with the label by default', (tester) async {
      await tester.pumpWidget(_app(const ConsoleLoader.large()));
      expect(
        tester.getSize(find.byKey(ConsoleLoader.markKey)),
        const Size(64, 64),
      );
      expect(find.text('Cargando…'), findsOneWidget);
    });

    testWidgets('a custom label replaces the default one', (tester) async {
      await tester.pumpWidget(
        _app(const ConsoleLoader.large(label: 'Abriendo chat…')),
      );
      expect(find.text('Abriendo chat…'), findsOneWidget);
      expect(find.text('Cargando…'), findsNothing);
    });
  });

  group('localization and semantics', () {
    testWidgets('label reads Cargando… in Spanish and Loading… in English', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const ConsoleLoader.large()));
      expect(find.text('Cargando…'), findsOneWidget);
      await tester.pumpWidget(
        _app(const ConsoleLoader.large(), locale: const Locale('en')),
      );
      await tester.pump();
      expect(find.text('Loading…'), findsOneWidget);
      expect(find.text('Cargando…'), findsNothing);
    });

    testWidgets('announces a loading spinner with the localized label, '
        'even for the mark-only small size', (tester) async {
      final handle = tester.ensureSemantics();
      for (final (locale, text) in [
        (const Locale('es'), 'Cargando…'),
        (const Locale('en'), 'Loading…'),
      ]) {
        for (final loader in const [
          ConsoleLoader.small(),
          ConsoleLoader.medium(),
          ConsoleLoader.large(),
        ]) {
          await tester.pumpWidget(_app(loader, locale: locale));
          await tester.pump();
          final node = tester.getSemantics(find.byType(ConsoleLoader));
          expect(node.label, text, reason: '$loader $locale');
          expect(node.role, ui.SemanticsRole.loadingSpinner);
        }
      }
      handle.dispose();
    });
  });

  group('blink', () {
    testWidgets('cursor eases between visible and hidden on a ~1060 ms cycle', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const ConsoleLoader.medium()));
      final samples = <double>[];
      for (var t = 0; t < 2120; t += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        samples.add(_opacity(tester));
      }
      expect(samples.reduce(math.max), closeTo(1, 0.01));
      expect(samples.reduce(math.min), lessThan(0.2));
      // Eased, not a hard on/off: intermediate opacities exist.
      var falling = 0, rising = 0;
      for (var i = 1; i < samples.length; i++) {
        final o = samples[i];
        if (o <= 0.1 || o >= 0.9) continue;
        if (samples[i - 1] > o) falling++;
        if (samples[i - 1] < o) rising++;
      }
      expect(falling, greaterThanOrEqualTo(2), reason: 'eased fade out');
      expect(rising, greaterThanOrEqualTo(2), reason: 'eased fade in');
      // Two cycles in 2120 ms: the cursor goes dark exactly twice.
      var dips = 0;
      for (var i = 1; i < samples.length; i++) {
        if (samples[i - 1] >= 0.5 && samples[i] < 0.5) dips++;
      }
      expect(dips, 2);
    });

    testWidgets('repaints at most 30 times a second and only the cursor', (
      tester,
    ) async {
      final host = _HostPainter();
      await tester.pumpWidget(
        _app(
          Stack(
            children: [
              CustomPaint(painter: host, size: const Size(200, 200)),
              const ConsoleLoader.large(),
            ],
          ),
        ),
      );
      // Let the large size finish its one-shot typing intro.
      await _pumpFor(tester, const Duration(seconds: 2));
      ConsoleLoader.debugResetPaintCounters();
      final hostBefore = host.paints;

      await _pumpFor(tester, const Duration(seconds: 3));
      final cursor = ConsoleLoader.debugCursorPaints;
      expect(cursor, lessThanOrEqualTo(3 * 30));
      expect(cursor, greaterThanOrEqualTo(6), reason: 'it must blink');
      // Only the fades produce frames; the visible/hidden plateaus are idle.
      expect(cursor, lessThanOrEqualTo(45), reason: 'plateaus must be idle');
      expect(ConsoleLoader.debugArcPaints, 0, reason: 'arc layer is static');
      expect(host.paints, hostBefore, reason: 'host must not repaint');
    });

    testWidgets('large types the C arc in once, then holds it', (tester) async {
      await tester.pumpWidget(_app(const ConsoleLoader.large()));
      final start = _arc(tester);
      expect(start, lessThan(0.5));
      await _pumpFor(tester, const Duration(seconds: 2));
      expect(_arc(tester), 1.0);

      await tester.pumpWidget(_app(const ConsoleLoader.medium()));
      expect(_arc(tester), 1.0);
    });
  });

  group('pause policy', () {
    Future<void> expectIdle(WidgetTester tester, String why) async {
      await tester.pump(const Duration(milliseconds: 50));
      ConsoleLoader.debugResetPaintCounters();
      // Sample every step: a blink that keeps running without frames (the
      // test binding stops frames when the app is backgrounded) still moves
      // the cursor's opacity.
      final seen = <double>{};
      for (var i = 0; i < 125; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        seen.add(_opacity(tester));
      }
      expect(ConsoleLoader.debugCursorPaints, 0, reason: why);
      expect(seen, {1.0}, reason: '$why: the cursor stays solid');
      expect(tester.binding.hasScheduledFrame, isFalse, reason: why);
    }

    testWidgets('reduce motion: static mark, cursor visible, label shown', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(const ConsoleLoader.large(), disableAnimations: true),
      );
      expect(_arc(tester), 1.0);
      expect(find.text('Cargando…'), findsOneWidget);
      await expectIdle(tester, 'reduce motion');
    });

    testWidgets('TickerMode off stops the blink; back on resumes it', (
      tester,
    ) async {
      final enabled = ValueNotifier<bool>(false);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (_, on, _) =>
                TickerMode(enabled: on, child: const ConsoleLoader.medium()),
          ),
        ),
      );
      await expectIdle(tester, 'TickerMode off');

      enabled.value = true;
      await tester.pump();
      ConsoleLoader.debugResetPaintCounters();
      await _pumpFor(tester, const Duration(seconds: 2), stepMs: 16);
      expect(ConsoleLoader.debugCursorPaints, greaterThan(0));
    });

    testWidgets('stopping while the cursor is hidden shows it solid', (
      tester,
    ) async {
      final enabled = ValueNotifier<bool>(true);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (_, on, _) =>
                TickerMode(enabled: on, child: const ConsoleLoader.medium()),
          ),
        ),
      );
      // Hidden plateau of the first blink (530–910 ms).
      await _pumpFor(tester, const Duration(milliseconds: 720), stepMs: 16);
      expect(_opacity(tester), lessThan(0.05), reason: 'precondition');
      enabled.value = false;
      await tester.pump();
      expect(_opacity(tester), 1.0);
      await expectIdle(tester, 'stopped while hidden');
    });

    testWidgets('a loader under an opaque route stops blinking', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const ConsoleLoader.large()));
      await _pumpFor(tester, const Duration(seconds: 1));
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('top')),
        ),
      );
      await tester.pumpAndSettle();
      // The covered loader is offstage: it no longer drives frames.
      ConsoleLoader.debugResetPaintCounters();
      await _pumpFor(tester, const Duration(seconds: 2), stepMs: 16);
      expect(ConsoleLoader.debugCursorPaints, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('backgrounding the app stops the blink; resuming restarts it', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const ConsoleLoader.medium()));
      await tester.pump(const Duration(milliseconds: 100));
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await expectIdle(tester, 'backgrounded');
      for (final s in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      ConsoleLoader.debugResetPaintCounters();
      await _pumpFor(tester, const Duration(seconds: 2), stepMs: 16);
      expect(ConsoleLoader.debugCursorPaints, greaterThan(0));
    });

    testWidgets('disposing leaves no timers behind', (tester) async {
      await tester.pumpWidget(_app(const ConsoleLoader.large()));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(_app(const SizedBox()));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('theme colours', () {
    test('mark ≥ 3:1 and label ≥ 4.5:1 on every surface of every theme', () {
      final fails = <String>[];
      var light = 0, dark = 0;
      for (final p in AppTheme.presets) {
        final theme = AppTheme.fromId(p.id);
        theme.brightness == Brightness.light ? light++ : dark++;
        final colors = ConsoleLoader.colorsFor(theme);
        final c = theme.hermes;
        for (final (name, bg) in [
          ('background', c.background),
          ('surface', c.surface),
          ('surfaceVariant', c.surfaceVariant),
          ('scaffold', theme.scaffoldBackgroundColor),
        ]) {
          final mark = ThemeContrast.ratio(colors.mark, bg);
          final label = ThemeContrast.ratio(colors.label, bg);
          if (mark < 3) fails.add('${p.id} mark/$name $mark');
          if (label < 4.5) fails.add('${p.id} label/$name $label');
        }
      }
      expect(light, greaterThan(0));
      expect(dark, greaterThan(0));
      expect(fails, isEmpty, reason: fails.join('\n'));
    });

    test('mark follows the theme accent family, not a fixed brand colour', () {
      final marks = {
        for (final p in AppTheme.presets)
          ConsoleLoader.colorsFor(AppTheme.fromId(p.id)).mark.toARGB32(),
      };
      expect(marks.length, greaterThan(AppTheme.presets.length ~/ 2));
      for (final p in AppTheme.presets) {
        final theme = AppTheme.fromId(p.id);
        expect(
          ConsoleLoader.colorsFor(theme).mark,
          theme.hermes.accentText,
          reason: p.id,
        );
      }
    });

    for (final id in const ['hermes-console', 'github', 'phosphor', 'claude']) {
      testWidgets('painted mark and label use the theme colours ($id)', (
        tester,
      ) async {
        final theme = AppTheme.fromId(id);
        final expected = ConsoleLoader.colorsFor(theme);
        await tester.pumpWidget(
          _app(
            const RepaintBoundary(
              key: ValueKey('shot'),
              child: ConsoleLoader.large(),
            ),
            theme: theme,
            disableAnimations: true,
          ),
        );
        await tester.pump(const Duration(seconds: 1));

        final label = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byType(ConsoleLoader),
            matching: find.byType(RichText),
          ),
        );
        expect(label.text.style?.color, expected.label);

        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(ConsoleLoader.markKey),
        );
        final bytes = await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          );
          image.dispose();
          return data!;
        });
        var inked = 0;
        final want = expected.mark;
        int ch(double v) => (v * 255).round();
        for (var i = 0; i < bytes!.lengthInBytes; i += 4) {
          final a = bytes.getUint8(i + 3);
          if (a < 250) continue; // anti-aliased edges
          inked++;
          expect(
            (bytes.getUint8(i) - ch(want.r)).abs() <= 3 &&
                (bytes.getUint8(i + 1) - ch(want.g)).abs() <= 3 &&
                (bytes.getUint8(i + 2) - ch(want.b)).abs() <= 3,
            isTrue,
            reason: '$id pixel $i is not the mark colour',
          );
        }
        // The C plus the cursor cover a good part of the 128×128 box.
        expect(inked, greaterThan(3000), reason: '$id inked $inked');
      });
    }
  });
}
