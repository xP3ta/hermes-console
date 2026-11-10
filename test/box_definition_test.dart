// The definition of the boxes: cards, groups, panels, rows of a list, tab
// bars, fields and notices wear the grammar of the gel of the buttons at the
// scale of a box: a contour in two tones (lighter on top, darker below), the
// inner light of the top edge and the inner shade of the bottom one, and a
// short shadow outside the outline. Geometry and colour are checked on the
// painters, on pixels and on every preset, in both brightnesses.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/box_edge.dart';
import 'package:hermes_android/core/design/tokens.dart' show HermesGel;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/hermes_style.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';

import 'support/box_edge_probe.dart';

/// The first preset (dark or light) whose glass is visible on pixels: a dark
/// page that is not black, a light body that is not white.
(ThemeData, GlassMaterial) _wearing({required bool dark}) {
  for (final preset in AppTheme.presets) {
    final glass = GlassMaterial.resolve(preset.colors, GlassLevel.full);
    if (glass == null || glass.dark != dark) continue;
    final body = ThemeContrast.composite(glass.groupFill, glass.page);
    final room = dark
        ? ThemeContrast.luminance(glass.page) > 0.004
        : ThemeContrast.luminance(body) < 0.93;
    if (room) return (AppTheme.fromId(preset.id), glass);
  }
  throw StateError('no preset');
}

Widget _host(ThemeData theme, Widget child) => MaterialApp(
  theme: theme,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 360, child: child),
    ),
  ),
);

/// The box [fill] with its shadow, body and edge painted as the widget does,
/// on the page, with [margin] of page all round; returns the raw pixels.
Future<(List<int>, int)> _paint(
  GlassMaterial glass,
  Color fill, {
  required double margin,
  required Size box,
}) async {
  final radius = BorderRadius.circular(14);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final width = (box.width + margin * 2).round();
  final height = (box.height + margin * 2).round();
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = glass.page,
  );
  canvas.translate(margin, margin);
  HermesBoxShadow(
    radius: radius,
    color: glass.boxShadow,
    blur: HermesGel.boxShadowBlur,
    drop: HermesGel.boxShadowDrop,
  ).paint(canvas, box);
  canvas.drawRRect(radius.toRRect(Offset.zero & box), Paint()..color = fill);
  HermesBoxEdge.of(glass, radius).paint(canvas, box);
  final image = await recorder.endRecording().toImage(width, height);
  final data = (await image.toByteData())!.buffer.asUint8List();
  image.dispose();
  return (data, width);
}

Color _pixel((List<int>, int) image, int x, int y) {
  final (data, width) = image;
  final at = (y * width + x) * 4;
  return Color.fromARGB(data[at + 3], data[at], data[at + 1], data[at + 2]);
}

void main() {
  setUp(() {
    GlassLookPrefs.debugUse(GlassLookPrefs.inMemory(GlassLevel.full));
    HermesStylePrefs.debugUse(HermesStylePrefs.inMemory());
  });
  tearDown(() {
    GlassLookPrefs.debugUse(null);
    HermesStylePrefs.debugUse(null);
  });

  group('the contour of a box, every preset and level', () {
    test('both tones keep 1.5:1 against the page and its glow, over each '
        'body; the top is the lighter one; the shadow is short', () {
      final fails = <String>[];
      var lights = 0;
      var darks = 0;
      for (final preset in AppTheme.presets) {
        for (final requested in [GlassLevel.soft, GlassLevel.full]) {
          final glass = GlassMaterial.resolve(preset.colors, requested);
          if (glass == null) continue;
          glass.dark ? darks++ : lights++;
          final id = '${preset.id}/${glass.level.name}';
          for (final back in [glass.page, glass.glow]) {
            for (final fill in [glass.groupFill, glass.cardFill]) {
              final under = ThemeContrast.composite(fill, back);
              for (final (tone, line) in [
                ('top', glass.lineTop),
                ('bottom', glass.lineBottom),
                ('line', glass.line),
              ]) {
                final pixel = ThemeContrast.composite(line, under);
                final ratio = ThemeContrast.ratio(pixel, back);
                if (ratio < GlassMaterial.borderRatio) {
                  fails.add('$id $tone ${ratio.toStringAsFixed(2)}');
                }
              }
              final top = ThemeContrast.composite(glass.lineTop, under);
              final bottom = ThemeContrast.composite(glass.lineBottom, under);
              if (ThemeContrast.luminance(top) <=
                  ThemeContrast.luminance(bottom)) {
                fails.add('$id top not lighter than bottom');
              }
            }
          }
          // The one-colour line is the weakest of the two tones.
          final weakest = glass.dark ? glass.lineBottom : glass.lineTop;
          if (glass.line != weakest) fails.add('$id line is not the weakest');
          // The shadow: black on dark, the warm one on light; short and with
          // an alpha, never a halo.
          final shadow = glass.boxShadow;
          if (shadow.a <= 0 || shadow.a > HermesGel.boxShadowDarkAlpha) {
            fails.add('$id shadow alpha ${shadow.a}');
          }
          if (!glass.dark && shadow.a > 0.15) fails.add('$id light shadow');
          if (glass.rim.a <= 0 || glass.rimShade.a <= 0) {
            fails.add('$id no rims');
          }
        }
      }
      expect(lights, greaterThan(10));
      expect(darks, greaterThan(10));
      expect(fails.toSet(), isEmpty, reason: fails.toSet().join(', '));
    });

    test('the shadow tokens are short', () {
      expect(
        HermesGel.boxShadowBlur,
        lessThanOrEqualTo(HermesGel.boxShadowBlurMax),
      );
      expect(
        HermesGel.boxShadowCompactBlur,
        lessThanOrEqualTo(HermesGel.boxShadowBlur),
      );
      expect(
        HermesGel.boxShadowDrop,
        lessThanOrEqualTo(HermesGel.boxShadowDropMax),
      );
      expect(HermesGel.boxShadowCompactDrop, greaterThanOrEqualTo(1));
    });
  });

  for (final dark in [false, true]) {
    final name = dark ? 'dark' : 'light';

    testWidgets('$name: on pixels, the top edge is lighter than the bottom '
        'one, both cut out of the page, the light rim and the shade are '
        'inside, and the shadow stays outside', (tester) async {
      final (_, glass) = _wearing(dark: dark);
      const margin = 12.0;
      const box = Size(96, 56);
      final fill = ThemeContrast.composite(glass.groupFill, glass.page);
      final image = (await tester.runAsync(
        () => _paint(glass, glass.groupFill, margin: margin, box: box),
      ))!;
      const cx = 12 + 48;
      final top = _pixel(image, cx, 12);
      final bottom = _pixel(image, cx, 12 + 55);
      expect(
        ThemeContrast.luminance(top),
        greaterThan(ThemeContrast.luminance(bottom)),
        reason: 'the light comes from above',
      );
      for (final edge in [top, bottom]) {
        expect(
          ThemeContrast.ratio(edge, glass.page),
          greaterThanOrEqualTo(GlassMaterial.borderRatio),
        );
      }
      // Just inside the contour: the light rim over the body at the top, the
      // shade under it at the bottom.
      final rim = _pixel(image, cx, 13);
      final shade = _pixel(image, cx, 12 + 54);
      final centre = _pixel(image, cx, 12 + 28);
      expect(
        ThemeContrast.luminance(rim),
        greaterThan(ThemeContrast.luminance(centre)),
      );
      expect(
        ThemeContrast.luminance(shade),
        lessThan(ThemeContrast.luminance(centre)),
      );
      // The body is the body: the shadow is clipped away inside the outline,
      // even under a translucent fill.
      for (final (got, want) in [
        (centre.r, fill.r),
        (centre.g, fill.g),
        (centre.b, fill.b),
      ]) {
        expect((got - want).abs(), lessThan(2 / 255));
      }
      // Under the box the page is darker (the short shadow), well above it
      // it is the page.
      final below = _pixel(image, cx, 12 + 56 + 1);
      expect(
        ThemeContrast.luminance(below),
        lessThan(ThemeContrast.luminance(glass.page)),
      );
      final away = _pixel(image, cx, 0);
      expect(
        ThemeContrast.luminance(away),
        closeTo(ThemeContrast.luminance(glass.page), 0.002),
      );
    });

    testWidgets('$name: a card, a group, a panel, a list section, a tab bar '
        'and a field share the edge and a short shadow', (tester) async {
      final (theme, glass) = _wearing(dark: dark);
      final pieces = <(String, Widget, bool)>[
        (
          'HermesCard',
          const HermesCard(child: SizedBox(height: 30, width: 100)),
          true,
        ),
        (
          'HermesGroup',
          const HermesGroup(children: [SizedBox(height: 30)]),
          true,
        ),
        (
          'HermesPanel',
          const HermesPanel(child: SizedBox(height: 30, width: 100)),
          true,
        ),
        (
          'HermesListSection',
          const HermesListSection(
            title: 'Aspecto',
            children: [SizedBox(height: 30)],
          ),
          true,
        ),
        (
          'HermesSegmentedControl',
          HermesSegmentedControl<int>(
            value: 0,
            onChanged: (_) {},
            segments: const [
              HermesSegment(value: 0, label: 'Alpha'),
              HermesSegment(value: 1, label: 'Beta'),
            ],
          ),
          true,
        ),
        (
          'HermesSearchField',
          const HermesSearchField(hintText: 'Buscar', clearTooltip: 'Borrar'),
          true,
        ),
        ('HermesInfoBanner', const HermesInfoBanner('Aviso'), false),
      ];
      for (final (label, piece, shadowed) in pieces) {
        await tester.pumpWidget(_host(theme, piece));
        final boxes = boxEdgesUnder(find.byWidget(piece));
        expect(boxes, findsWidgets, reason: label);
        final edge = edgeOf(tester, boxes);
        expect(edge.top, glass.lineTop, reason: label);
        expect(edge.bottom, glass.lineBottom, reason: label);
        expect(edge.light, glass.rim, reason: label);
        expect(edge.shade, glass.rimShade, reason: label);
        final under = ThemeContrast.composite(glass.groupFill, glass.page);
        expect(
          ThemeContrast.luminance(ThemeContrast.composite(edge.top, under)),
          greaterThan(
            ThemeContrast.luminance(
              ThemeContrast.composite(edge.bottom, under),
            ),
          ),
          reason: '$label: top lighter than bottom',
        );
        final shadow = shadowOf(tester, boxes);
        if (!shadowed) {
          expect(shadow, isNull, reason: label);
          continue;
        }
        expect(shadow, isNotNull, reason: label);
        expect(shadow!.color, glass.boxShadow, reason: label);
        expect(shadow.color.a, greaterThan(0), reason: label);
        expect(shadow.blur, inInclusiveRange(1, HermesGel.boxShadowBlurMax));
        expect(shadow.drop, inInclusiveRange(1, HermesGel.boxShadowDropMax));
      }
    });
  }

  testWidgets('a card in a list takes the shorter shadow', (tester) async {
    final (theme, _) = _wearing(dark: true);
    await tester.pumpWidget(
      _host(theme, const HermesCard(child: SizedBox(height: 30))),
    );
    final shadow = shadowOf(tester, boxEdgesUnder(find.byType(HermesCard)))!;
    expect(shadow.blur, HermesGel.boxShadowCompactBlur);
    expect(shadow.drop, HermesGel.boxShadowCompactDrop);
  });

  testWidgets('without the glass the boxes keep what they were: no edge', (
    tester,
  ) async {
    GlassLookPrefs.debugUse(GlassLookPrefs.inMemory(GlassLevel.off));
    final (theme, _) = _wearing(dark: true);
    await tester.pumpWidget(
      _host(theme, const HermesGroup(children: [SizedBox(height: 30)])),
    );
    expect(boxEdgesUnder(find.byType(HermesGroup)), findsNothing);
  });
}
