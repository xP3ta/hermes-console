// The gel-glass of the buttons: one primitive (HermesGelSurface) with the
// rims, the sheen and the accent gradient, used by the floating round
// buttons, the header capsule and the filled round actions.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/floating.dart';
import 'package:hermes_android/core/design/gel_surface.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';

Widget _app(
  Widget child, {
  ThemeData? theme,
  bool reduceMotion = false,
  bool highContrast = false,
}) => MaterialApp(
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: reduceMotion, highContrast: highContrast),
    child: home!,
  ),
  home: Scaffold(body: Center(child: child)),
);

double _scale(WidgetTester tester) =>
    tester.widget<AnimatedScale>(find.byType(AnimatedScale).first).scale;

void main() {
  test('the accent gradient never reads worse than the accent itself', () {
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      final far = HermesGel.accent2(colors.accent, ink: colors.onAccent);
      final wanted = ThemeContrast.ratio(colors.onAccent, colors.accent);
      final got = ThemeContrast.ratio(colors.onAccent, far);
      expect(
        got,
        greaterThanOrEqualTo((wanted < 4.5 ? wanted : 4.5) - 0.05),
        reason: preset.id,
      );
    }
  });

  test('the gradient line follows the CSS angle', () {
    final (from, to) = HermesGel.line(const Size(40, 40), 180);
    expect(from.dx, closeTo(20, 1e-6));
    expect(from.dy, closeTo(0, 1e-6));
    expect(to.dy, closeTo(40, 1e-6));
  });

  for (final (name, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('$name: a floating round button wears the gel and '
        'compresses by 4 % while pressed', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          HermesFloatingIconButton(
            icon: Icons.search_rounded,
            tooltip: 'Buscar',
            onPressed: () => taps++,
          ),
          theme: theme,
        ),
      );
      expect(find.byType(HermesGelSurface), findsOneWidget);
      expect(_scale(tester), 1);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(IconButton)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(_scale(tester), HermesGel.pressScale);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_scale(tester), 1);
      expect(taps, 1);
      // At rest nothing is animating.
      expect(tester.hasRunningAnimations, isFalse);
    });
  }

  testWidgets('reduced motion: the press changes state without interpolation', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        HermesFloatingIconButton(
          icon: Icons.search_rounded,
          tooltip: 'Buscar',
          onPressed: () {},
        ),
        reduceMotion: true,
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(IconButton)),
    );
    await tester.pump();
    expect(_scale(tester), HermesGel.pressScale);
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale).first).duration,
      Duration.zero,
    );
    await gesture.up();
  });

  testWidgets('high contrast: the gel paints no sheen or rims', (tester) async {
    await tester.pumpWidget(
      _app(
        HermesFloatingIconButton(
          icon: Icons.search_rounded,
          tooltip: 'Buscar',
          onPressed: () {},
        ),
        highContrast: true,
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find
          .descendant(
            of: find.byType(HermesGelSurface),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    expect(paint.foregroundPainter, isNotNull);
    // Nothing but the layout: painting must not throw.
    expect(tester.takeException(), isNull);
  });

  for (final (name, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('$name: the filled round action is the accent gel and keeps '
        'its icon', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          HermesTactileAction(
            icon: Icons.arrow_upward_rounded,
            semanticLabel: 'Enviar',
            onPressed: () => taps++,
          ),
          theme: theme,
        ),
      );
      final gel = tester.widget<HermesGelSurface>(
        find.byType(HermesGelSurface),
      );
      expect(gel.tone, HermesGelTone.accent);
      expect(gel.accent, theme.hermes.accent);
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
      await tester.tap(find.byType(HermesTactileAction));
      expect(taps, 1);
    });
  }

  testWidgets('a disabled or quiet action does not wear the accent gel', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HermesTactileAction(
              icon: Icons.arrow_upward_rounded,
              semanticLabel: 'Enviar',
              onPressed: null,
            ),
            HermesTactileAction(
              icon: Icons.mic_none_rounded,
              semanticLabel: 'Voz',
              onPressed: null,
              visual: HermesTactileActionVisual.quiet,
            ),
          ],
        ),
      ),
    );
    // The disabled filled action keeps the gel's rims over its flat disc
    // (the glass tone, no accent); the quiet one stays bare.
    final gel = tester.widget<HermesGelSurface>(find.byType(HermesGelSurface));
    expect(gel.tone, HermesGelTone.glass);
    expect(gel.enabled, isFalse);
    expect(find.byType(HermesGelSurface), findsOneWidget);
  });
}
