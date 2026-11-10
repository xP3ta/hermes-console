// QA9715: the liquid touch of the header glass
// (lib/core/design/liquid_glass.dart, shaders/liquid_glass.frag). Here,
// without Impeller (the gate's renderer): the AA rule of the adaptive veil
// in every theme and variant, the shader's uniforms, and that a strip
// asked to be liquid is the glass of before where the shader cannot run.
// What the shader paints is captured with Impeller
// (test/liquid_app_capture_test.dart, opt-in production-screen evidence).
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';

/// Pages of every kind a piece can pass over: a grey ramp and the colours
/// a page shows most.
final List<Color> _pages = [
  for (var v = 0; v <= 255; v += 15) Color.fromARGB(255, v, v, v),
  Colors.red,
  Colors.green,
  Colors.blue,
  Colors.yellow,
  Colors.cyan,
  Colors.purple,
  Colors.orange,
  Colors.teal,
  Colors.pink,
];

void main() {
  test('the weakest ink is the title badge\'s, over the same tint', () {
    expect(HermesLiquid.badgeTint, HermesTitleBadge.tintOpacity);
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      expect(
        HermesLiquid.weakestInk(colors),
        HermesTitleBadge.inkFor(colors),
        reason: preset.id,
      );
    }
  });

  test('icon-only dock keeps AA without a hypothetical title badge', () {
    final liquid = HermesLiquid.dock.withVeilFloor(.64);
    expect(liquid.badgeOpacity, 0);
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      final ink = colors.textPrimary;
      final veil = liquid.fallbackVeil(
        FrostedBackdrop.glassVeil(colors),
        ink: ink,
        weakInk: ink,
      );
      for (final page in _pages) {
        expect(
          ThemeContrast.ratio(ink, Color.alphaBlend(veil, page)),
          greaterThanOrEqualTo(4.5),
          reason: preset.id,
        );
        expect(
          ThemeContrast.ratio(
            ink,
            liquid.under(page, veil: veil, ink: ink, weakInk: ink),
          ),
          greaterThanOrEqualTo(4.5),
          reason: preset.id,
        );
      }
      expect(
        liquid.uniforms(
          const [],
          devicePixelRatio: 1,
          veil: veil,
          ink: ink,
          weakInk: ink,
        )[40],
        0,
      );
    }
  });

  test('every theme, every variant, over any page: the ink and the badge '
      'read at AA on the adaptive veil', () {
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      final chrome = HermesChrome.of(colors);
      final veil = FrostedBackdrop.glassVeil(colors);
      final weak = HermesLiquid.weakestInk(colors);
      for (final liquid in [...HermesLiquid.variants, HermesLiquid.overlay]) {
        for (final page in _pages) {
          final amount = liquid.veilOver(
            page,
            veil: veil,
            ink: chrome.ink,
            weakInk: weak,
          );
          expect(amount, inInclusiveRange(liquid.veilLeast, 1));
          final under = liquid.under(
            page,
            veil: veil,
            ink: chrome.ink,
            weakInk: weak,
          );
          final tinted = Color.lerp(under, chrome.ink, HermesLiquid.badgeTint)!;
          final what = '${preset.id} ${liquid.veilLeast} over $page';
          expect(
            ThemeContrast.ratio(chrome.ink, under),
            greaterThanOrEqualTo(HermesLiquid.target),
            reason: '$what: ink',
          );
          expect(
            ThemeContrast.ratio(weak, tinted),
            greaterThanOrEqualTo(HermesLiquid.target),
            reason: '$what: badge',
          );
        }
      }
    }
  });

  test('the veil is low where the page allows it: over its own page, the '
      'variant\'s least', () {
    for (final id in const ['classic-dark', 'classic']) {
      final colors = AppTheme.fromId(id).hermes;
      final chrome = HermesChrome.of(colors);
      for (final liquid in [...HermesLiquid.variants, HermesLiquid.overlay]) {
        expect(
          liquid.veilOver(
            colors.background,
            veil: FrostedBackdrop.glassVeil(colors),
            ink: chrome.ink,
            weakInk: HermesLiquid.weakestInk(colors),
          ),
          liquid.veilLeast,
          reason: '$id ${liquid.veilLeast}',
        );
      }
    }
    // The three variants go from a thicker to a thinner least veil, and
    // from a gentler to a stronger rim.
    final [soft, medium, strong] = HermesLiquid.variants;
    expect(soft.veilLeast, greaterThan(medium.veilLeast));
    expect(medium.veilLeast, greaterThan(strong.veilLeast));
    expect(soft.refraction, lessThan(strong.refraction));
    expect(soft.rim, lessThan(strong.rim));
  });

  test('the shader\'s uniforms: five pieces at most, in physical pixels', () {
    const veil = Color(0xFF3D3D3D);
    const ink = Color(0xFFE8E8E8);
    const weak = Color(0xFFBDBDBD);
    final rects = [
      for (var i = 0; i < 5; i++)
        RRect.fromRectAndRadius(
          Rect.fromLTWH(10.0 * i, 20, 44, 44),
          const Radius.circular(22),
        ),
    ];
    final values = HermesLiquid.medium.uniforms(
      rects,
      devicePixelRatio: 2,
      veil: veil,
      ink: ink,
      weakInk: weak,
    );
    // Five rects, five corner radii, then material/ink uniforms. The
    // engine owns two floats before these 44 values.
    expect(values, hasLength(44));
    expect(values.sublist(0, 4), [0, 20, 44, 44]);
    expect(values.sublist(16, 20), [40, 20, 44, 44]);
    expect(values.sublist(20, 25), List.filled(5, 22));
    expect(values[25], 5, reason: 'all registered pieces are represented');
    expect(values[26], HermesLiquid.medium.refraction * 2);
    expect(values[29], HermesLiquid.medium.fusion * 2);
    expect(values[33], HermesLiquid.medium.veilLeast);
    expect(values[40], HermesLiquid.badgeTint);
    expect(values[41], HermesLiquid.target);
    final none = HermesLiquid.soft.uniforms(
      const [],
      devicePixelRatio: 1,
      veil: veil,
      ink: ink,
      weakInk: weak,
    );
    expect(none[25], 0);
    expect(HermesLiquid.medium, isNot(HermesLiquid.strong));
    expect(HermesLiquid.medium, HermesLiquid.variants[1]);
  });

  testWidgets('without Impeller, a strip asked to be liquid is the glass of '
      'before: the composer\'s veil, one blur', (tester) async {
    expect(await tester.runAsync(HermesLiquidShader.load), isNull);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('classic-dark'),
        home: Align(
          alignment: Alignment.topLeft,
          child: HermesGlassStrip(
            liquid: HermesLiquid.strong,
            child: Builder(
              builder: (context) => HermesGlassPiece(
                key: const ValueKey('piece'),
                shape: const StadiumBorder(),
                child: ColoredBox(
                  color: HermesGlassStrip.of(context)!.veil,
                  child: const SizedBox(width: 160, height: 44),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final context = tester.element(find.byKey(const ValueKey('piece')));
    final original = FrostedBackdrop.glassVeil(
      AppTheme.fromId('classic-dark').hermes,
    );
    final veil = HermesGlassStrip.of(context)!.veil;
    expect(veil.withValues(alpha: 1), original.withValues(alpha: 1));
    expect(veil.a, greaterThanOrEqualTo(original.a));
    expect(tester.layers.whereType<BackdropFilterLayer>(), hasLength(1));
  }, skip: ui.ImageFilter.isShaderFilterSupported);

  test('native fallback veil protects both inks on black and white', () {
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      final chrome = HermesChrome.of(colors);
      final weak = HermesLiquid.weakestInk(colors);
      final veil = HermesLiquid.overlay.fallbackVeil(
        FrostedBackdrop.glassVeil(colors),
        ink: chrome.ink,
        weakInk: weak,
      );
      for (final behind in [Colors.white, Colors.black]) {
        final under = ThemeContrast.composite(veil, behind);
        final badge = ThemeContrast.composite(
          chrome.ink.withValues(alpha: HermesLiquid.badgeTint),
          under,
        );
        expect(
          ThemeContrast.ratio(chrome.ink, under),
          greaterThanOrEqualTo(4.5),
          reason: '${preset.id} primary',
        );
        expect(
          ThemeContrast.ratio(weak, badge),
          greaterThanOrEqualTo(4.5),
          reason: '${preset.id} badge',
        );
      }
    }
  });
}
