// QA 9709: the dock is a pill, like the rest of Console («todo en
// píldoras»). The capsule and the selected destination round half of their
// short side, along the bottom and as the tablet rail, in light and dark,
// and every destination keeps its 48 dp target.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart' show HermesRadius;
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock_style.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _bar(
  String themeId,
  Axis axis, {
  DockStyle style = const DockStyle(),
}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId(themeId),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: axis == Axis.horizontal ? 360 : null,
        child: DockBar(
          key: const ValueKey('q9-dock'),
          axis: axis,
          style: style,
          selectedIndex: 1,
          children: [
            for (final icon in const [
              Icons.home_outlined,
              Icons.add,
              Icons.smart_toy_outlined,
              Icons.settings_outlined,
            ])
              DockItemTile(
                icon: icon,
                label: 'x',
                compact: true,
                selected: icon == Icons.add,
                selectionBackground: false,
                innerRadius: resolveDockVisual(
                  AppTheme.fromId(themeId).hermes,
                  style,
                ).innerRadius,
                onTap: () {},
              ),
          ],
        ),
      ),
    ),
  ),
);

/// The capsule: the first box of the bar that draws its border.
Finder _capsule() => find
    .descendant(
      of: find.byKey(const ValueKey('q9-dock')),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border != null,
      ),
    )
    .first;

/// The sliding indicator's own box.
Finder _indicator() => find.descendant(
  of: find.byKey(const ValueKey('dock-active-indicator')),
  matching: find.byType(DecoratedBox),
);

void _expectPill(WidgetTester tester, Finder box, String what) {
  final decoration =
      tester.widget<DecoratedBox>(box).decoration as BoxDecoration;
  final radius = decoration.borderRadius! as BorderRadius;
  final size = tester.getSize(box);
  for (final corner in [
    radius.topLeft,
    radius.topRight,
    radius.bottomLeft,
    radius.bottomRight,
  ]) {
    // Painted, a radius past half the short side is cut to it: a pill.
    expect(
      corner.x,
      greaterThanOrEqualTo(size.shortestSide / 2),
      reason: '$what $size',
    );
    expect(corner.x, corner.y, reason: what);
  }
}

void main() {
  test('the pill is the default; a saved v1 default reads as it', () {
    expect(const DockStyle().borderShape, DockBorderShape.rounded);
    expect(DockBorderShape.parse('nope'), DockBorderShape.rounded);
    expect(DockBorderShape.rounded.outerRadius, HermesRadius.tag);
    expect(DockBorderShape.rounded.innerRadius, HermesRadius.tag);
    // Before v2, `soft` was what every untouched dock saved.
    expect(
      DockStyle.fromJson({
        'schema_version': 1,
        'border_shape': 'soft',
      }).borderShape,
      DockBorderShape.rounded,
    );
    // A shape chosen by hand stays.
    expect(
      DockStyle.fromJson({
        'schema_version': 1,
        'border_shape': 'square',
      }).borderShape,
      DockBorderShape.square,
    );
    expect(
      DockStyle.fromJson({
        'schema_version': DockStyle.schemaVersion,
        'border_shape': 'soft',
      }).borderShape,
      DockBorderShape.soft,
    );
  });

  for (final themeId in const ['dark', 'console-light']) {
    testWidgets('$themeId: the bottom bar and its indicator are pills', (
      tester,
    ) async {
      await tester.pumpWidget(_bar(themeId, Axis.horizontal));
      await tester.pumpAndSettle();

      _expectPill(tester, _capsule(), 'bar');
      expect(tester.getSize(_capsule()).height, DockBar.barHeight);
      _expectPill(tester, _indicator(), 'indicator');

      // The top light stays inside the rounded ends.
      final hairline = tester.getRect(
        find.byKey(const ValueKey('dock-top-hairline')),
      );
      final bar = tester.getRect(_capsule());
      expect(hairline.left - bar.left, DockBar.barHeight / 4);
      expect(bar.right - hairline.right, DockBar.barHeight / 4);

      for (final element in find.byType(InkWell).evaluate()) {
        final size = (element.renderObject! as RenderBox).size;
        expect(size.height, greaterThanOrEqualTo(48));
        expect(size.width, greaterThanOrEqualTo(48));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('$themeId: the rail and its indicator are pills', (
      tester,
    ) async {
      await tester.pumpWidget(_bar(themeId, Axis.vertical));
      await tester.pumpAndSettle();

      _expectPill(tester, _capsule(), 'rail');
      expect(tester.getSize(_capsule()).width, DockBar.railWidth);
      _expectPill(tester, _indicator(), 'rail indicator');
      for (final element in find.byType(InkWell).evaluate()) {
        final size = (element.renderObject! as RenderBox).size;
        expect(size.height, greaterThanOrEqualTo(48));
        expect(size.width, greaterThanOrEqualTo(48));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a square dock chosen by hand stays square', (tester) async {
    const style = DockStyle(borderShape: DockBorderShape.square);
    await tester.pumpWidget(_bar('dark', Axis.horizontal, style: style));
    await tester.pumpAndSettle();
    final decoration =
        tester.widget<DecoratedBox>(_capsule()).decoration as BoxDecoration;
    expect(
      (decoration.borderRadius! as BorderRadius).topLeft.x,
      DockBorderShape.square.outerRadius,
    );
  });
}
