// The "Apple light" pass of groups, panels and cards where the glass layer
// is not worn: a SOLID body derived from the page (HermesBoxFill: lifted
// towards white on a light page, mixed with white on a dark one), a soft
// shadow on a light page and generous radii. Outlined profiles stay flat.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/box_fill.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';

Future<void> _pump(
  WidgetTester tester,
  String themeId,
  Widget child, {
  bool highContrast = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.fromId(themeId),
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

double _radius(BoxDecoration d) => (d.borderRadius! as BorderRadius).topLeft.x;

void main() {
  // These tests are about the light page's own look; the glass layer that
  // replaces it by default has its own tests (glass_look_test.dart).
  setUp(() => GlassLookPrefs.debugUse(GlassLookPrefs.inMemory(GlassLevel.off)));
  tearDown(() => GlassLookPrefs.debugUse(null));

  testWidgets('a group on a light page: white body, soft shadow, generous '
      'radius, no hard border', (tester) async {
    await _pump(
      tester,
      'classic',
      const HermesGroup(children: [SizedBox(height: 40)]),
    );
    final decoration = _decoration(tester, HermesGroup);
    final theme = AppTheme.fromId('classic');
    expect(decoration.color, HermesBoxFill.of(theme.hermes).group);
    expect(decoration.color!.a, 1);
    expect(decoration.boxShadow, isNotEmpty);
    expect(decoration.border, isNull);
    expect(_radius(decoration), greaterThanOrEqualTo(HermesRadius.row));
    // The ink reads better on the new body than on the tint it replaces.
    final colors = theme.hermes;
    final before = ThemeContrast.composite(
      colors.surfaceVariant.withValues(alpha: 0.3),
      colors.background,
    );
    final now = ThemeContrast.composite(decoration.color!, colors.background);
    expect(
      ThemeContrast.ratio(colors.textSecondary, now),
      greaterThanOrEqualTo(ThemeContrast.ratio(colors.textSecondary, before)),
    );
  });

  testWidgets('a panel on a light page wears the same look', (tester) async {
    await _pump(
      tester,
      'classic',
      const HermesPanel(child: SizedBox(height: 40, width: 100)),
    );
    final decoration = _decoration(tester, HermesPanel);
    expect(decoration.boxShadow, isNotEmpty);
    final colors = AppTheme.fromId('classic').hermes;
    expect(decoration.color, HermesBoxFill.of(colors).group);
  });

  testWidgets('a card on a light page: solid body, softer hairline, no shadow '
      '(a list never pays a blur per row)', (tester) async {
    await _pump(
      tester,
      'classic',
      const HermesCard(child: SizedBox(height: 40, width: 100)),
    );
    final decoration = _decoration(tester, HermesCard);
    final colors = AppTheme.fromId('classic').hermes;
    expect(decoration.color, HermesBoxFill.of(colors).card);
    expect(decoration.color!.a, 1);
    expect(decoration.boxShadow, isNull);
    expect(_radius(decoration), greaterThanOrEqualTo(HermesRadius.row));
    expect(
      (decoration.border! as Border).top.color,
      colors.divider.withValues(alpha: HermesSoftLight.cardLine),
    );
  });

  testWidgets('dark pages: the group is a solid body a step above the page', (
    tester,
  ) async {
    await _pump(
      tester,
      'classic-dark',
      const HermesGroup(children: [SizedBox(height: 40)]),
    );
    final decoration = _decoration(tester, HermesGroup);
    final colors = AppTheme.fromId('classic-dark').hermes;
    expect(decoration.color, HermesBoxFill.of(colors).group);
    expect(decoration.color!.a, 1);
    expect(
      ThemeContrast.ratio(decoration.color!, colors.background),
      greaterThanOrEqualTo(HermesBoxFill.darkStep - 0.01),
    );
    expect(decoration.boxShadow, isNull);
  });

  testWidgets('high contrast: the group is the same solid body, light too', (
    tester,
  ) async {
    await _pump(
      tester,
      'classic',
      const HermesGroup(children: [SizedBox(height: 40)]),
      highContrast: true,
    );
    final decoration = _decoration(tester, HermesGroup);
    final colors = AppTheme.fromId('classic').hermes;
    expect(decoration.color, HermesBoxFill.of(colors).group);
    expect(decoration.color!.a, 1);
    expect(decoration.boxShadow, isNull);
  });

  test('every light preset: the soft body is not darker than the old tint', () {
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      final chrome = HermesChrome.of(colors);
      if (chrome.dark) continue;
      final old = ThemeContrast.composite(
        colors.surfaceVariant.withValues(alpha: 0.3),
        colors.background,
      );
      final now = ThemeContrast.composite(
        HermesBoxFill.of(colors).group,
        colors.background,
      );
      for (final ink in [colors.textPrimary, colors.textSecondary]) {
        expect(
          ThemeContrast.ratio(ink, now),
          greaterThanOrEqualTo(ThemeContrast.ratio(ink, old) - 0.001),
          reason: '${preset.id}: ink on the soft body',
        );
      }
    }
  });
}
