// The glass layer over any theme: its three levels, the clouds derived from
// the active theme, the material on groups and cards, the contrast guard that
// lowers a theme's level instead of the threshold, and the setting.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/ambient_backdrop.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/box_fill.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/hermes_style.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/box_edge_probe.dart';
import 'support/theme_profile_fixtures.dart';

Future<void> _pump(
  WidgetTester tester,
  ThemeData theme,
  Widget child, {
  bool highContrast = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: theme,
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    builder: (context, home) => MediaQuery(
      data: MediaQuery.of(context).copyWith(highContrast: highContrast),
      child: home!,
    ),
    home: Scaffold(body: Center(child: child)),
  ),
);

BoxDecoration _decoration(WidgetTester tester, Type owner) {
  final container = find.descendant(
    of: find.byType(owner),
    matching: find.byType(Container),
  );
  return tester.widget<Container>(container.first).decoration! as BoxDecoration;
}

/// The glass of the first preset with a light page that wears one.
GlassMaterial _firstLight() {
  for (final preset in AppTheme.presets) {
    final glass = GlassMaterial.resolve(preset.colors, GlassLevel.full);
    if (glass != null && !glass.dark) return glass;
  }
  throw StateError('no light preset wears the glass');
}

void main() {
  tearDown(() {
    GlassLookPrefs.debugUse(null);
    HermesStylePrefs.debugUse(null);
  });

  void level(GlassLevel value) =>
      GlassLookPrefs.debugUse(GlassLookPrefs.inMemory(value));

  group('contrast over the real range of the backdrop', () {
    test('42 presets x 3 levels: every ink reads (4.5:1) on the composite '
        'surface, or the theme drops a level', () {
      expect(AppTheme.presets.length, 42); // 40 + the two Indigo glass presets
      final fails = <String>[];
      final lowered = <String>[];
      for (final preset in AppTheme.presets) {
        final colors = preset.colors;
        for (final requested in GlassLevel.values) {
          final material = GlassMaterial.resolve(colors, requested);
          if (requested == GlassLevel.off) {
            expect(material, isNull, reason: preset.id);
            continue;
          }
          if (material == null) {
            lowered.add('${preset.id}:${requested.name}->off');
            continue;
          }
          if (material.level != requested) {
            lowered.add(
              '${preset.id}:${requested.name}->${material.level.name}',
            );
          }
          // Recomputed here from the public fields, with the page and the
          // glow at its strongest; the guard's own check is not used.
          final page = ThemeContrast.composite(
            colors.background,
            const Color(0xFF000000),
          );
          final backs = [page, material.glow];
          final inks = {
            'textPrimary': colors.textPrimary,
            'textSecondary': colors.textSecondary,
          };
          for (final MapEntry(key: name, value: ink) in inks.entries) {
            for (final back in backs) {
              for (final fill in [material.groupFill, material.cardFill]) {
                final surface = ThemeContrast.composite(fill, back);
                // The glint is part of the body under the ink, so a first
                // row reads through it too.
                final glint = ThemeContrast.composite(material.sheen, surface);
                for (final s in [back, surface, glint]) {
                  final r = ThemeContrast.ratio(ink, s);
                  if (r + 1e-9 < 4.5) {
                    fails.add(
                      '${preset.id} ${material.level.name} $name '
                      '${r.toStringAsFixed(2)}',
                    );
                  }
                }
              }
            }
          }
        }
      }
      expect(fails, isEmpty, reason: fails.join('\n'));
      // ignore: avoid_print
      print('GLASS lowered (${lowered.length}): $lowered');
    });

    test('a lower request never gives more than was asked', () {
      for (final preset in AppTheme.presets) {
        final soft = GlassMaterial.effective(preset.colors, GlassLevel.soft);
        expect(soft.index, lessThanOrEqualTo(GlassLevel.soft.index));
        final full = GlassMaterial.effective(preset.colors, GlassLevel.full);
        expect(full.index, greaterThanOrEqualTo(soft.index), reason: preset.id);
      }
    });

    test('a theme whose ink cannot read on the glass drops a level instead '
        'of lowering the threshold', () {
      final base = AppTheme.fromId('console').hermes;
      // Secondary ink at about 3:1 on the page: not even the bare page reads.
      final weak = base.copyWith(textSecondary: const Color(0xFF77777D));
      expect(
        ThemeContrast.ratio(weak.textSecondary, weak.background),
        lessThan(4.5),
      );
      expect(GlassMaterial.resolve(weak, GlassLevel.full), isNull);
      expect(GlassMaterial.effective(weak, GlassLevel.full), GlassLevel.off);
      // An ink that reads on the page but not under the glow drops to soft
      // or off, never stays on full.
      final tight = base.copyWith(textSecondary: const Color(0xFFA0A0A8));
      final material = GlassMaterial.resolve(tight, GlassLevel.full);
      if (material != null) {
        expect(
          ThemeContrast.ratio(tight.textSecondary, material.glow),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('the default theme keeps the full level', () {
      final console = AppTheme.presets.firstWhere((p) => p.id == 'console');
      expect(
        GlassMaterial.effective(console.colors, GlassLevel.full),
        GlassLevel.full,
      );
    });

    test('the terminal looks wear the glass; only Outline is flat', () {
      final terminal = AppTheme.presets.where((p) => p.uppercaseTitles);
      expect(terminal, isNotEmpty);
      var wearing = 0;
      for (final preset in terminal) {
        final colors = AppTheme.fromId(preset.id).hermes;
        expect(colors.uppercaseTitles, isTrue, reason: preset.id);
        if (GlassMaterial.resolve(colors, GlassLevel.full) != null) wearing++;
        expect(
          GlassMaterial.resolve(
            colors.copyWith(outlined: true),
            GlassLevel.full,
          ),
          isNull,
          reason: preset.id,
        );
      }
      expect(wearing, greaterThan(0));
    });

    // The pieces of the light glass are cut out of the page, not just painted
    // white on it, and the selected piece is not a subtle change of white.
    test('every preset, both brightnesses: border, body and selected piece '
        'are defined and the ink reads on them', () {
      final fails = <String>[];
      var lights = 0;
      var darks = 0;
      for (final preset in AppTheme.presets) {
        final colors = preset.colors;
        for (final requested in [GlassLevel.soft, GlassLevel.full]) {
          final glass = GlassMaterial.resolve(colors, requested);
          if (glass == null) continue;
          final id = '${preset.id}/${glass.level.name}';
          glass.dark ? darks++ : lights++;
          final page = glass.page;
          final group = ThemeContrast.composite(glass.groupFill, page);
          final card = ThemeContrast.composite(glass.cardFill, page);
          final selected = ThemeContrast.composite(glass.selected, group);
          if (!glass.dark) {
            for (final fill in [group, card]) {
              final border = ThemeContrast.composite(glass.line, fill);
              final r = ThemeContrast.ratio(border, page);
              if (r < GlassMaterial.borderRatio) {
                fails.add('$id border ${r.toStringAsFixed(2)}');
              }
              // The piece is never darker than the page it sits on, and on a
              // page that is not already white it is lighter by a small,
              // checkable step, never near-white: at most about 45 % of the
              // way from the page to white.
              final lift =
                  ThemeContrast.luminance(fill) - ThemeContrast.luminance(page);
              if (lift < -1e-9) fails.add('$id piece darker than page');
              if (ThemeContrast.luminance(page) < 0.9 && lift <= 0.002) {
                fails.add('$id piece not lighter than page');
              }
              for (final (piece, back) in [
                (fill.r, page.r),
                (fill.g, page.g),
                (fill.b, page.b),
              ]) {
                if (back < 0.9 && (piece - back) / (1 - back) > 0.48) {
                  fails.add('$id piece near-white');
                }
              }
              // Opaque: the short shadow under it never shows through.
              if (fill.a != 1) fails.add('$id translucent light piece');
            }
            if (glass.shadow == null) fails.add('$id no shadow');
            if (glass.shadow != null && glass.shadow!.a > 0.15) {
              fails.add('$id shadow too strong');
            }
            if (glass.rim.a < 0.3 || glass.rim.a > 0.7) {
              fails.add('$id rim not discreet');
            }
          }
          // Selected vs not: a visible change of colour, never only of white.
          final dr = (selected.r - group.r).abs();
          final dg = (selected.g - group.g).abs();
          final db = (selected.b - group.b).abs();
          if ([dr, dg, db].reduce((a, b) => a > b ? a : b) < 12 / 255) {
            fails.add('$id selected too close to unselected');
          }
          final line = ThemeContrast.ratio(glass.selectedLine, selected);
          if (line < 1.4) {
            fails.add('$id selected line ${line.toStringAsFixed(2)}');
          }
          // The label of a selected piece is the main ink, in bold.
          final r = ThemeContrast.ratio(colors.textPrimary, selected);
          if (r < GlassMaterial.minimumRatio) {
            fails.add('$id ink on selected ${r.toStringAsFixed(2)}');
          }
        }
      }
      expect(lights, greaterThan(10));
      expect(darks, greaterThan(10));
      expect(fails.toSet(), isEmpty, reason: fails.toSet().join(', '));
    });

    test('light glass is warm: the shadow and the border lean to ochre', () {
      final glass = _firstLight();
      expect(glass.dark, isFalse);
      for (final tone in [glass.shadow!, glass.line]) {
        final hue = HSLColor.fromColor(tone).hue;
        expect(hue <= 70 || hue >= 345, isTrue, reason: '$hue');
      }
    });
  });

  group('reading calm: where long text is read', () {
    test('42 presets x 3 levels: the main ink reaches 7:1 and the secondary '
        '4.5:1 on the worst point of base + glow + veil', () {
      final fails = <String>[];
      final veils = <String, double>{};
      for (final preset in AppTheme.presets) {
        final colors = preset.colors;
        for (final requested in GlassLevel.values) {
          final material = GlassMaterial.resolve(colors, requested);
          if (material == null) continue;
          final page = ThemeContrast.composite(
            colors.background,
            const Color(0xFF000000),
          );
          final clouds = [page, material.glow];
          final bubble = colors.surfaceVariant.withValues(
            alpha: GlassMaterial.bubbleOpacity,
          );
          veils['${preset.id}:${material.level.name}'] = material.readingVeil;
          for (final cloud in clouds) {
            final back = material.readingBack(page, cloud);
            for (final fill in [
              null,
              material.groupFill,
              material.cardFill,
              bubble,
            ]) {
              final surface = fill == null
                  ? back
                  : ThemeContrast.composite(fill, back);
              final primary = ThemeContrast.ratio(colors.textPrimary, surface);
              final secondary = ThemeContrast.ratio(
                colors.textSecondary,
                surface,
              );
              if (primary + 1e-9 < 7.0 || secondary + 1e-9 < 4.5) {
                fails.add(
                  '${preset.id} ${material.level.name} '
                  '${primary.toStringAsFixed(2)}/${secondary.toStringAsFixed(2)}',
                );
              }
            }
          }
        }
      }
      expect(fails, isEmpty, reason: fails.join('\n'));
      for (final veil in veils.values) {
        expect(veil, inInclusiveRange(0.55, 1.0));
      }
      // ignore: avoid_print
      print('GLASS veils: $veils');
    });

    test('the veil is one flat value under the text and fades only at the '
        'edges', () {
      for (
        var t = GlassMaterial.calmEdge;
        t <= 1 - GlassMaterial.calmEdge;
        t += 0.01
      ) {
        expect(GlassMaterial.calmAt(t), 1);
      }
      expect(GlassMaterial.calmAt(0), 0);
      expect(GlassMaterial.calmAt(1), 0);
      expect(
        GlassMaterial.calmAt(GlassMaterial.calmEdge / 2),
        closeTo(0.5, 1e-9),
      );
    });

    testWidgets('a reading zone calms the backdrop and gives it back', (
      tester,
    ) async {
      level(GlassLevel.full);
      final theme = AppTheme.fromId('console');
      Widget app({required bool reading}) => MaterialApp(
        theme: theme,
        home: HermesAmbientBackdrop(
          child: reading
              ? const HermesReadingZone(child: Text('texto largo'))
              : const Text('texto largo'),
        ),
      );
      double calm() {
        final paint = tester.widget<CustomPaint>(
          find
              .descendant(
                of: find.byType(HermesAmbientBackdrop),
                matching: find.byType(CustomPaint),
              )
              .first,
        );
        // ignore: avoid_dynamic_calls
        return (paint.painter! as dynamic).readingCalm as double;
      }

      await tester.pumpWidget(app(reading: false));
      expect(calm(), 0);
      await tester.pumpWidget(app(reading: true));
      await tester.pump();
      expect(calm(), 1);
      // Nothing is painted behind the text: no box, no gradient, no shadow.
      expect(
        find.descendant(
          of: find.byType(HermesReadingZone),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
      expect(tester.widget<Text>(find.text('texto largo')).style, isNull);
      await tester.pumpWidget(app(reading: false));
      await tester.pump();
      expect(calm(), 0);
    });

    testWidgets("the user's bubble is opaque enough with glass, as before "
        'without it', (tester) async {
      late BuildContext captured;
      Future<void> pump() => tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId('console'),
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      const variant = Color(0xFF39393F);
      level(GlassLevel.full);
      await pump();
      expect(
        HermesGlassLook.bubbleFill(captured, variant).a,
        closeTo(GlassMaterial.bubbleOpacity, 0.01),
      );
      level(GlassLevel.off);
      await pump();
      expect(
        HermesGlassLook.bubbleFill(captured, variant).a,
        closeTo(0.6, 0.01),
      );
    });
  });

  group('the glow is the page\'s own colour', () {
    double gap(double a, double b) {
      final d = (a - b).abs() % 360;
      return d > 180 ? 360 - d : d;
    }

    test('one glow of the same hue and saturation, a few per cent lighter on '
        'a dark page and darker on a light one', () {
      var checked = 0;
      for (final preset in AppTheme.presets) {
        for (final requested in [GlassLevel.soft, GlassLevel.full]) {
          final material = GlassMaterial.resolve(preset.colors, requested);
          if (material == null) continue;
          checked++;
          final page = HSLColor.fromColor(material.page);
          final glow = HSLColor.fromColor(material.glow);
          final id = '${preset.id}/${material.level.name}';
          // Same hue where the page has one, same saturation (rounding aside).
          if (page.saturation > 0.15 && page.lightness > 0.1) {
            expect(gap(glow.hue, page.hue), lessThan(8), reason: id);
            expect(glow.saturation, closeTo(page.saturation, 0.1), reason: id);
          }
          final step = glow.lightness - page.lightness;
          final expected = GlassMaterial.glowStep(
            dark: material.dark,
            full: material.isFull,
          );
          expect(step.abs(), closeTo(expected, 0.03), reason: '$id step $step');
          expect(step.abs(), lessThanOrEqualTo(0.06), reason: id);
          if (material.dark) {
            expect(step, greaterThan(0), reason: id);
          } else {
            expect(step, lessThan(0), reason: id);
          }
        }
      }
      expect(checked, greaterThan(40));
    });

    test('the glow is faint: soft less than full', () {
      for (final id in ['console', 'console-light']) {
        final colors = AppTheme.fromId(id).hermes;
        final full = GlassMaterial.resolve(colors, GlassLevel.full);
        final soft = GlassMaterial.resolve(colors, GlassLevel.soft);
        if (full == null || soft == null) continue;
        double lightness(Color c) => HSLColor.fromColor(c).lightness;
        expect(
          (lightness(full.glow) - lightness(full.page)).abs(),
          greaterThan((lightness(soft.glow) - lightness(soft.page)).abs()),
          reason: id,
        );
      }
    });

    test('a light theme gets the page as its own opaque colour', () {
      final material = _firstLight();
      expect(material.page.a, 1);
    });

    testWidgets('the backdrop follows the level at once: off is flat, soft '
        'and full paint the glow', (tester) async {
      final prefs = GlassLookPrefs.inMemory(GlassLevel.full);
      final theme = AppTheme.fromId('console');
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: GlassLookScope(
            prefs: prefs,
            child: const HermesAmbientBackdrop(child: SizedBox.expand()),
          ),
        ),
      );
      dynamic painter() => tester
          .widget<CustomPaint>(
            find
                .descendant(
                  of: find.byType(HermesAmbientBackdrop),
                  matching: find.byType(CustomPaint),
                )
                .first,
          )
          .painter;
      // ignore: avoid_dynamic_calls
      expect(painter().glass, isNotNull);
      await prefs.setLevel(GlassLevel.off);
      await tester.pump();
      // ignore: avoid_dynamic_calls
      expect(painter().glass, isNull, reason: 'off paints a flat page');
      await prefs.setLevel(GlassLevel.soft);
      await tester.pump();
      // ignore: avoid_dynamic_calls
      expect(painter().glass, isNotNull);
      // ignore: avoid_dynamic_calls
      expect((painter().glass as GlassMaterial).level, GlassLevel.soft);
    });

    test('intensity follows the level and the brightness of the theme', () {
      final dark = AppTheme.fromId('console').hermes;
      final light = AppTheme.fromId('console-light').hermes;
      final darkFull = GlassMaterial.resolve(dark, GlassLevel.full)!;
      final darkSoft = GlassMaterial.resolve(dark, GlassLevel.soft)!;
      final lightFull = GlassMaterial.resolve(light, GlassLevel.full);
      expect(
        GlassMaterial.glowStep(dark: true, full: true),
        greaterThan(GlassMaterial.glowStep(dark: true, full: false)),
      );
      expect(darkFull.dark, isTrue);
      expect(darkSoft.isFull, isFalse);
      if (lightFull != null) {
        expect(lightFull.dark, isFalse);
        expect(
          GlassMaterial.glowStep(dark: false, full: true),
          lessThanOrEqualTo(GlassMaterial.glowStep(dark: true, full: true)),
        );
      }
    });

    test('a custom theme of the Studio gets the same layer', () {
      final theme = AppTheme.fromProfile(validCustomTheme());
      final material = GlassMaterial.resolve(theme.hermes, GlassLevel.soft);
      expect(material, isNotNull);
    });
  });

  group('the material on surfaces', () {
    testWidgets('a group on a dark page: solid body a step above the page, '
        'two-tone contour and rims, glint, a short shadow painted outside '
        'only', (tester) async {
      level(GlassLevel.full);
      final theme = AppTheme.fromId('console');
      await _pump(
        tester,
        theme,
        const HermesGroup(children: [SizedBox(height: 40)]),
      );
      final glass = GlassMaterial.resolve(theme.hermes, GlassLevel.full)!;
      final decoration = _decoration(tester, HermesGroup);
      expect(decoration.color, glass.groupFill);
      // Solid, derived from the page alone, and clearly apart from it.
      expect(decoration.color!.a, 1);
      expect(
        ThemeContrast.ratio(decoration.color!, glass.page),
        greaterThanOrEqualTo(1.25),
      );
      // The contour, the rims and the shadow are painted by the box's edge
      // (outside a translucent body, so it never shows through).
      expect(decoration.border, isNull);
      expect(decoration.boxShadow, isNull);
      final boxes = boxEdgesUnder(find.byType(HermesGroup));
      final edge = edgeOf(tester, boxes);
      expect(edge.top, glass.lineTop);
      expect(edge.bottom, glass.lineBottom);
      expect(shadowOf(tester, boxes)!.color, glass.boxShadow);
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(HermesGroup),
              matching: find.byType(Container),
            )
            .first,
      );
      // The glint is in the body, under the ink: nothing is painted over it.
      expect(container.foregroundDecoration, isNull);
      // A BoxDecoration paints its gradient INSTEAD of its colour: the
      // gradient carries the body, so the body is really painted all over
      // and the glint is the only thing that changes along it.
      final gradient = decoration.gradient! as LinearGradient;
      expect(gradient.colors.last, glass.groupFill);
      expect(
        gradient.colors.first,
        Color.alphaBlend(glass.sheen, glass.groupFill),
      );
    });

    testWidgets('a card is a step lighter than the page, with a hairline', (
      tester,
    ) async {
      level(GlassLevel.full);
      final theme = AppTheme.fromId('console');
      await _pump(
        tester,
        theme,
        const HermesCard(child: SizedBox(height: 40, width: 100)),
      );
      final glass = GlassMaterial.resolve(theme.hermes, GlassLevel.full)!;
      final decoration = _decoration(tester, HermesCard);
      expect(decoration.color, glass.cardFill);
      final edge = edgeOf(tester, boxEdgesUnder(find.byType(HermesCard)));
      expect(edge.top, glass.lineTop);
      expect(edge.bottom, glass.lineBottom);
    });

    testWidgets('a light page: white body more opaque than on a dark one, '
        'soft shadow kept', (tester) async {
      level(GlassLevel.full);
      final theme = AppTheme.fromId('classic');
      await _pump(
        tester,
        theme,
        const HermesPanel(child: SizedBox(height: 40, width: 100)),
      );
      final glass = GlassMaterial.resolve(theme.hermes, GlassLevel.full);
      final decoration = _decoration(tester, HermesPanel);
      if (glass == null) {
        expect(decoration.boxShadow, isNotEmpty);
      } else {
        expect(decoration.color!.a, greaterThan(0.5));
        // The short shadow is painted under the piece, outside its outline.
        final shadow = shadowOf(
          tester,
          boxEdgesUnder(find.byType(HermesPanel)),
        );
        expect(shadow, isNotNull);
        expect(shadow!.color, glass.boxShadow);
        // The painted body (the gradient's) is the opaque one, lit at the
        // top: the short shadow never shows through the piece.
        final gradient = decoration.gradient! as LinearGradient;
        expect(gradient.colors.last, glass.groupFill);
        expect(gradient.colors.last.a, 1);
        expect(gradient.colors.first.a, 1);
      }
    });

    testWidgets('off: the surfaces are what they were', (tester) async {
      level(GlassLevel.off);
      final theme = AppTheme.fromId('console');
      await _pump(
        tester,
        theme,
        const HermesGroup(children: [SizedBox(height: 40)]),
      );
      // No glass: no contour, rims or glint; the body is the same solid one
      // (derived from the page), never a transparency.
      final decoration = _decoration(tester, HermesGroup);
      expect(decoration.color, HermesBoxFill.of(theme.hermes).group);
      expect(decoration.color!.a, 1);
      expect(decoration.gradient, isNull);
      expect(decoration.border, isNull);
    });

    testWidgets('high contrast leaves the surfaces flat', (tester) async {
      level(GlassLevel.full);
      final theme = AppTheme.fromId('console');
      await _pump(
        tester,
        theme,
        const HermesGroup(children: [SizedBox(height: 40)]),
        highContrast: true,
      );
      final decoration = _decoration(tester, HermesGroup);
      expect(decoration.color, HermesBoxFill.of(theme.hermes).group);
      expect(decoration.gradient, isNull);
    });

    testWidgets(
      'the section label is small and tracked on the full level only',
      (tester) async {
        final theme = AppTheme.fromId('console');
        level(GlassLevel.full);
        await _pump(tester, theme, const HermesSectionHeader('Aspecto'));
        var style = tester.widget<Text>(find.text('Aspecto')).style!;
        expect(style.letterSpacing, greaterThan(0));
        expect(style.fontSize, lessThan(13));
        level(GlassLevel.soft);
        await _pump(tester, theme, const HermesSectionHeader('Aspecto'));
        style = tester.widget<Text>(find.text('Aspecto')).style!;
        expect(style.letterSpacing, 0);
      },
    );
  });

  group('the primary button', () {
    test('gets the accent gradient on the full level only', () {
      final base = AppTheme.fromId('console');
      final full = hermesAmbientTheme(base, level: GlassLevel.full);
      final soft = hermesAmbientTheme(base, level: GlassLevel.soft);
      expect(full.filledButtonTheme.style?.backgroundBuilder, isNotNull);
      expect(soft.filledButtonTheme.style?.backgroundBuilder, isNull);
      final end = GlassMaterial.resolve(
        base.hermes,
        GlassLevel.full,
      )!.buttonEnd!;
      expect(
        ThemeContrast.ratio(base.hermes.onAccent, end),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets('only the plain primary button wears the gradient: a '
        'destructive and a tonal one keep their own paint', (tester) async {
      level(GlassLevel.full);
      final base = AppTheme.fromId('console');
      final theme = hermesAmbientTheme(base, level: GlassLevel.full);
      final colors = base.hermes;
      await _pump(
        tester,
        theme,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              key: const ValueKey('plain'),
              onPressed: () {},
              child: const Text('Save'),
            ),
            FilledButton(
              key: const ValueKey('danger'),
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onAccent,
              ),
              onPressed: () {},
              child: const Text('Delete'),
            ),
            FilledButton.tonal(
              key: const ValueKey('tonal'),
              style: hermesTonalButtonStyle,
              onPressed: () {},
              child: const Text('Retry'),
            ),
            FilledButton.tonalIcon(
              key: const ValueKey('tonal-icon'),
              style: hermesTonalButtonStyle,
              onPressed: () {},
              icon: const Icon(Icons.refresh),
              label: const Text('Again'),
            ),
          ],
        ),
      );
      Finder gradient(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Ink),
      );
      expect(gradient('plain'), findsOneWidget);
      expect(gradient('danger'), findsNothing);
      expect(gradient('tonal'), findsNothing);
      expect(gradient('tonal-icon'), findsNothing);
      final danger = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(const ValueKey('danger')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(danger.color, colors.error);
    });

    test('every preset keeps its label readable on both ends', () {
      for (final preset in AppTheme.presets) {
        final end = GlassMaterial.resolve(
          preset.colors,
          GlassLevel.full,
        )?.buttonEnd;
        if (end == null) continue;
        expect(
          ThemeContrast.ratio(preset.colors.onAccent, end),
          greaterThanOrEqualTo(4.5),
          reason: preset.id,
        );
      }
    });
  });

  group('the setting', () {
    test('the real store is fixed on full and cannot be changed', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = await GlassLookPrefs.load(prefs);
      expect(store.level, GlassLevel.full);
      expect(GlassLookPrefs.shared, same(store));
      var notified = 0;
      store.addListener(() => notified++);
      await store.setLevel(GlassLevel.off);
      await store.setLevel(GlassLevel.soft);
      expect(store.level, GlassLevel.full);
      expect(notified, 0);
      expect(prefs.getString(GlassLookPrefs.levelKey), isNull);
    });

    for (final saved in ['off', 'soft', 'full', 'nonsense']) {
      test('a "$saved" saved by an older install does not count', () async {
        SharedPreferences.setMockInitialValues({
          GlassLookPrefs.levelKey: saved,
        });
        final store = await GlassLookPrefs.load(
          await SharedPreferences.getInstance(),
        );
        expect(store.level, GlassLevel.full);
      });
    }

    test('without a loaded store the shared one is full too', () {
      GlassLookPrefs.debugUse(null);
      expect(GlassLookPrefs.shared.level, GlassLevel.full);
    });

    test('a test store can still hold and change any level', () async {
      final store = GlassLookPrefs.inMemory(GlassLevel.off);
      expect(store.level, GlassLevel.off);
      await store.setLevel(GlassLevel.soft);
      expect(store.level, GlassLevel.soft);
    });
  });
}
