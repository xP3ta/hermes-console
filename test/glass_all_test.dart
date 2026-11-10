// The glass on the shared pieces: the selected segment is an accent piece with
// its own border and a bold label; the chips, the segmented buttons, the
// dialogs, menus and sheets of the theme wear the glass border; Outline keeps
// all of it flat.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/ambient_backdrop.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/hermes_style.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';

import 'support/box_edge_probe.dart';

/// The first preset (dark or light, as asked) that wears the full glass.
(ThemeData, GlassMaterial) _wearing({required bool dark}) {
  for (final preset in AppTheme.presets) {
    final glass = GlassMaterial.resolve(preset.colors, GlassLevel.full);
    if (glass != null && glass.dark == dark) {
      return (AppTheme.fromId(preset.id), glass);
    }
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

void main() {
  setUp(() {
    GlassLookPrefs.debugUse(GlassLookPrefs.inMemory(GlassLevel.full));
    HermesStylePrefs.debugUse(HermesStylePrefs.inMemory());
  });
  tearDown(() {
    GlassLookPrefs.debugUse(null);
    HermesStylePrefs.debugUse(null);
  });

  for (final dark in [false, true]) {
    final name = dark ? 'dark' : 'light';

    testWidgets('$name: the selected segment is an accent piece, bold, with '
        'its own border; the others are plain', (tester) async {
      final (theme, glass) = _wearing(dark: dark);
      await tester.pumpWidget(
        _host(
          theme,
          HermesSegmentedControl<int>(
            value: 1,
            onChanged: (_) {},
            segments: const [
              HermesSegment(value: 0, label: 'Alpha'),
              HermesSegment(value: 1, label: 'Beta'),
            ],
          ),
        ),
      );
      // The selected pill is the one under the track (it slides), the
      // segments themselves are plain.
      BoxDecoration of(String label) =>
          tester
                  .widget<AnimatedContainer>(
                    find.ancestor(
                      of: find.text(label),
                      matching: find.byType(AnimatedContainer),
                    ),
                  )
                  .decoration!
              as BoxDecoration;
      final on =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: find.byKey(
                        const ValueKey('hermes-segmented-indicator'),
                      ),
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      final off = of('Alpha');
      expect(on.color, glass.selected);
      expect((on.border! as Border).top.color, glass.selectedLine);
      expect(on.borderRadius, BorderRadius.circular(999));
      expect(of('Beta').color, Colors.transparent);
      expect(off.color, Colors.transparent);
      expect(off.border, isNull);
      expect(
        tester.widget<Text>(find.text('Beta')).style!.fontWeight,
        FontWeight.w700,
      );
      expect(
        tester.widget<Text>(find.text('Alpha')).style!.fontWeight,
        FontWeight.w500,
      );
    });

    testWidgets('$name: the info banner and the group take the border of '
        'the glass', (tester) async {
      final (theme, glass) = _wearing(dark: dark);
      await tester.pumpWidget(
        _host(
          theme,
          const Column(
            children: [
              HermesInfoBanner('Aviso'),
              HermesGroup(children: [SizedBox(height: 30)]),
            ],
          ),
        ),
      );
      final banner = tester.widget<Material>(
        find.byKey(const ValueKey('hermes-info-banner-surface')),
      );
      // The contour is the box's edge, in two tones; the Material keeps its
      // elevation's shadow and no border of its own.
      expect((banner.shape! as RoundedRectangleBorder).side, BorderSide.none);
      final edge = edgeOf(tester, boxEdgesUnder(find.byType(HermesInfoBanner)));
      expect(edge.top, glass.lineTop);
      expect(edge.bottom, glass.lineBottom);
      expect(banner.shadowColor, glass.shadow ?? banner.shadowColor);
    });

    test('$name: the theme gives chips, segmented buttons, dialogs, menus '
        'and sheets the glass', () {
      final (base, glass) = _wearing(dark: dark);
      final theme = hermesAmbientTheme(base, level: GlassLevel.full);
      expect(theme.chipTheme.side!.color, glass.line);
      final style = theme.segmentedButtonTheme.style!;
      expect(
        style.side!.resolve({WidgetState.selected})!.color,
        glass.selectedLine,
      );
      expect(style.side!.resolve({})!.color, glass.line);
      expect(
        style.textStyle!.resolve({WidgetState.selected})!.fontWeight,
        FontWeight.w700,
      );
      for (final shape in [
        theme.dialogTheme.shape,
        theme.popupMenuTheme.shape,
        theme.bottomSheetTheme.shape,
      ]) {
        expect((shape! as RoundedRectangleBorder).side.color, glass.line);
      }
    });
  }

  test('Outline keeps the shared pieces as the theme made them', () {
    final (base, glass) = _wearing(dark: false);
    final flat = hermesAmbientTheme(
      applyHermesStyle(base, HermesStyle.contour),
      level: GlassLevel.full,
    );
    expect(flat.chipTheme.side!.color, isNot(glass.line));
    expect(
      flat.segmentedButtonTheme.style!.side!.resolve({})!.color,
      isNot(glass.line),
    );
  });

  testWidgets('a group on light glass lifts with a warm shadow and lights '
      'its top edge', (tester) async {
    final (theme, glass) = _wearing(dark: false);
    await tester.pumpWidget(
      _host(theme, const HermesGroup(children: [SizedBox(height: 30)])),
    );
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(HermesGroup),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = container.decoration! as BoxDecoration;
    final shadow = shadowOf(tester, boxEdgesUnder(find.byType(HermesGroup)))!;
    expect(shadow.color, glass.shadow);
    // Short and soft: a small blur, 1 to 3 dp down, a low alpha. Never the
    // wide halo that showed through the body.
    expect(shadow.blur, lessThanOrEqualTo(8));
    expect(shadow.drop, inInclusiveRange(1, 3));
    expect(shadow.color.a, lessThanOrEqualTo(0.15));
    expect(decoration.color, glass.groupFill);
    expect(decoration.color!.a, 1, reason: 'the shadow must not show through');
    expect(container.foregroundDecoration, isNull);
    // The top edge is lit from inside, painted with the box.
    expect(
      edgeOf(tester, boxEdgesUnder(find.byType(HermesGroup))).light,
      glass.rim,
    );
  });

  testWidgets('a card in a list keeps a short shadow', (tester) async {
    final (theme, glass) = _wearing(dark: false);
    await tester.pumpWidget(
      _host(theme, const HermesCard(child: SizedBox(height: 30))),
    );
    final shadow = shadowOf(tester, boxEdgesUnder(find.byType(HermesCard)))!;
    expect(shadow.blur, lessThanOrEqualTo(8));
    expect(shadow.drop, inInclusiveRange(1, 3));
    expect(shadow.color, glass.shadow);
  });
}
