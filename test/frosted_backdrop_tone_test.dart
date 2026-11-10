// OPUS-CRISTAL: FrostedBackdrop hands the smoked tone to its band, so the
// dock (dock_style.dart) can wear the same glass as the chat's foot: one
// blur, never the shader, the user's transparency as a floor, and the
// fallback of before where the policy says no blur. The dock's wiring and
// which inks it guards are Terminal's; this pins the shared API it uses,
// with inks that read on the tone (the bar's), so the band gets it.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show BackdropFilterLayer;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/design/smoked_glass.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';

const _fill = ValueKey('tone-fill');

Widget _app({
  required HermesSmokedGlass? tone,
  required Color tint,
  bool reducedMotion = false,
}) {
  final theme = AppTheme.fromId('classic-dark');
  final colors = theme.hermes;
  return MaterialApp(
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
      child: child!,
    ),
    home: Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              children: [
                for (var i = 0; i < 30; i++)
                  Container(
                    height: 36,
                    color: i.isEven ? Colors.white : colors.accent,
                  ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: FrostedBackdrop(
              liquid: HermesLiquid.dock,
              tone: tone,
              toneInks: HermesSmokedGlass.barInks(colors),
              zone: FrostedZone.bottom,
              sigma: 18,
              tint: tint,
              borderRadius: BorderRadius.circular(28),
              builder: (context, fill) => ColoredBox(
                key: _fill,
                color: fill,
                child: const SizedBox(width: 300, height: 56),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

Color _fillOf(WidgetTester tester) =>
    tester.widget<ColoredBox>(find.byKey(_fill)).color;

int _filters(WidgetTester tester) =>
    tester.layers.whereType<BackdropFilterLayer>().length;

void main() {
  void resetPolicy() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
    FrostedBackdropPolicy.knownHighEnd.value = false;
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
  }

  setUp(() {
    resetPolicy();
    FrostedBackdropPolicy.knownHighEnd.value = true;
  });
  tearDown(resetPolicy);

  final colors = AppTheme.fromId('classic-dark').hermes;
  final chrome = HermesChrome.of(colors);
  // The dock's default veil (transparency 0.6 → alpha 0.592) as the floor.
  final tint = const Color(0xFF363636).withValues(alpha: 0.592);
  final tone = HermesSmokedGlass.of(chrome).withVeilFloor(tint.a);

  testWidgets('the tone reaches the band: its veil, one blur, its tone', (
    tester,
  ) async {
    await tester.pumpWidget(_app(tone: tone, tint: tint));
    await tester.pumpAndSettle();
    expect(_fillOf(tester), tone.veilOf(chrome));
    expect(tone.veil, tint.a);
    expect(_filters(tester), 1);
    final glass = HermesGlassStrip.of(tester.element(find.byKey(_fill)));
    expect(glass?.tone, tone);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a validated GPU still never loads the shader for a tone', (
    tester,
  ) async {
    FrostedBackdropPolicy.liquidGpuValidated.value = true;
    final attempts = HermesLiquidShader.loadAttempts;
    await tester.pumpWidget(_app(tone: tone, tint: tint));
    await tester.pumpAndSettle();
    expect(HermesLiquidShader.loadAttempts, attempts);
    expect(
      HermesGlassStrip.debugShaderActive(tester.element(find.byKey(_fill))),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('no blur: the fallback of before, no filter', (tester) async {
    await tester.pumpWidget(_app(tone: tone, tint: tint, reducedMotion: true));
    await tester.pumpAndSettle();
    expect(_filters(tester), 0);
    expect(_fillOf(tester), Color.alphaBlend(tint, colors.background));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('without a tone the band is exactly the one of before', (
    tester,
  ) async {
    await tester.pumpWidget(_app(tone: null, tint: tint));
    await tester.pumpAndSettle();
    final glass = HermesGlassStrip.of(tester.element(find.byKey(_fill)));
    expect(glass?.tone, isNull);
    expect(_fillOf(tester), isNot(tone.veilOf(chrome)));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
