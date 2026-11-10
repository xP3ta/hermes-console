// States that read without colour, and the small layout faults of the
// legibility pass: the active dock item is the theme's accent (never the
// «ok» green) and also changes its glyph; the chosen segment is a bordered
// pill and a heavier label; a row's ink stays inside its rounded group; a
// navigation row's value sits by its chevron; the floating pieces keep a 3:1
// edge on every page.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesListGroup, HermesListRow;
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/lines.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/dock_style.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart'
    show HermesSegment, HermesSegmentedControl;
import 'package:hermes_android/core/widgets/hermes_ui.dart'
    show HermesGroup, HermesNavRow;

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  String id = 'console',
}) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.fromId(id),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(HermesSpace.x4),
        child: child,
      ),
    ),
  ),
);

void main() {
  testWidgets('the active dock item is the accent (terracotta on Console), '
      'not the success green, and changes its glyph', (tester) async {
    await _pump(
      tester,
      const Row(
        children: [
          DockItemTile(
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            label: 'Ajustes',
            innerRadius: 16,
            selected: true,
          ),
          DockItemTile(
            icon: Icons.home_outlined,
            selectedIcon: Icons.home,
            label: 'Inicio',
            innerRadius: 16,
          ),
        ],
      ),
    );
    final colors = AppTheme.fromId('console').hermes;
    final active = tester.widget<Icon>(find.byIcon(Icons.settings));
    expect(active.color, colors.accentText);
    expect(active.color, isNot(colors.success));
    // Terracotta: a warm hue, far from the green of «ok».
    final hue = HSLColor.fromColor(active.color!).hue;
    expect(hue < 40 || hue > 340, isTrue, reason: 'hue $hue');
    // Without colour: the active item wears its filled glyph, the idle one
    // the outlined one.
    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(find.byIcon(Icons.home_outlined), findsOneWidget);
  });

  testWidgets('the chosen segment is a bordered pill with a heavier label', (
    tester,
  ) async {
    await _pump(
      tester,
      HermesSegmentedControl<int>(
        value: 0,
        onChanged: (_) {},
        segments: const [
          HermesSegment(value: 0, label: 'Directo'),
          HermesSegment(value: 1, label: 'SSH'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final indicator = find.byKey(const ValueKey('hermes-segmented-indicator'));
    expect(indicator, findsOneWidget);
    final boxes = tester
        .widgetList<DecoratedBox>(
          find.descendant(of: indicator, matching: find.byType(DecoratedBox)),
        )
        .map((b) => b.decoration)
        .whereType<BoxDecoration>();
    final containers = tester
        .widgetList<Container>(
          find.descendant(of: indicator, matching: find.byType(Container)),
        )
        .map((c) => c.decoration)
        .whereType<BoxDecoration>();
    expect(
      [...boxes, ...containers].any((d) => d.border != null),
      isTrue,
      reason: 'the selected pill has an outline, not only a fill',
    );
    FontWeight? weightOf(String label) {
      final text = tester.widget<Text>(find.text(label));
      return text.style?.fontWeight ??
          DefaultTextStyle.of(
            tester.element(find.text(label)),
          ).style.fontWeight;
    }

    final chosen = weightOf('Directo');
    final other = weightOf('SSH');
    expect(chosen, isNotNull);
    expect(other, isNotNull);
    expect(chosen!.value, greaterThan(other!.value));
  });

  testWidgets('a pressed row paints its ink inside the rounded group', (
    tester,
  ) async {
    await _pump(
      tester,
      HermesListGroup(
        children: [
          HermesListRow(title: 'Modelo', value: 'gpt', onTap: () {}),
          HermesListRow(title: 'Razonamiento', value: 'Alto', onTap: () {}),
        ],
      ),
    );
    final row = find.widgetWithText(InkWell, 'Modelo');
    final ink = Material.of(tester.element(row));
    // The Material the ink lands on is the group's own (transparent, inside
    // its clip), not the page's under the opaque body.
    final groupMaterial = find.descendant(
      of: find.byType(HermesListGroup),
      matching: find.byType(Material),
    );
    expect(groupMaterial, findsWidgets);
    final pageMaterial = Material.of(
      tester.element(find.byType(HermesListGroup)),
    );
    expect(identical(ink, pageMaterial), isFalse);
  });

  testWidgets('a navigation row keeps its value by the chevron', (
    tester,
  ) async {
    await _pump(
      tester,
      HermesGroup(
        children: [
          HermesNavRow(
            icon: Icons.lan_outlined,
            title: 'Gestionar instancias',
            value: '0',
            onTap: () {},
          ),
        ],
      ),
    );
    final value = tester.getRect(find.text('0'));
    final chevron = tester.getRect(find.byIcon(Icons.chevron_right));
    expect(chevron.left - value.right, lessThanOrEqualTo(8 + 0.5));
    // The title has the room it needs: one line.
    final title = tester.getSize(find.text('Gestionar instancias'));
    expect(title.height, lessThan(2 * 14.5));
  });

  test('the floating pieces keep a 3:1 edge on every page', () {
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      final chrome = HermesChrome.of(colors);
      final page = ThemeContrast.composite(
        colors.background,
        const Color(0xFF000000),
      );
      final edge = ThemeContrast.composite(chrome.line, chrome.opaque);
      expect(
        ThemeContrast.ratio(edge, page),
        greaterThanOrEqualTo(HermesLines.edgeRatio),
        reason: preset.id,
      );
    }
  });
}
