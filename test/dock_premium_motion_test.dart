import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/core/widgets/dock_style.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// One theme instance, so rebuilding the host never starts a theme lerp.
final _theme = AppTheme.fromId('dark');

// General profile defaults: home, create, bots, settings (4 equal slots).
Widget _host({
  required DockItemId selected,
  bool disableAnimations = false,
  VoidCallback? onCreate,
}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: _theme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: child!,
  ),
  home: Scaffold(
    body: Dock(
      profileId: DockProfileId.general,
      bottomInset: 10,
      actions: {
        DockItemId.home: DockItemAction(
          onTap: () {},
          selected: selected == DockItemId.home,
        ),
        DockItemId.create: DockItemAction(onTap: onCreate ?? () {}),
        DockItemId.bots: DockItemAction(
          onTap: () {},
          selected: selected == DockItemId.bots,
        ),
        DockItemId.settings: DockItemAction(
          onTap: () {},
          selected: selected == DockItemId.settings,
        ),
      },
    ),
  ),
);

final _indicator = find.byKey(const ValueKey('dock-active-indicator'));

double _indicatorCenterX(WidgetTester tester) =>
    tester.getCenter(_indicator).dx;

double _tileCenterX(WidgetTester tester, String id) =>
    tester.getCenter(find.byKey(ValueKey('general-mode-dock-$id'))).dx;

double _pressScaleOf(WidgetTester tester, String id) => tester
    .widget<AnimatedScale>(
      find.ancestor(
        of: find.byKey(ValueKey('general-mode-dock-$id')),
        matching: find.byKey(const ValueKey('dock-press-scale')),
      ),
    )
    .scale;

// Painted width over laid-out width: includes every ancestor transform.
double _renderedScaleOf(WidgetTester tester, String id) {
  final finder = find.byKey(ValueKey('general-mode-dock-$id'));
  return tester.getRect(finder).width / tester.getSize(finder).width;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('single indicator sits under the selected destination', (
    tester,
  ) async {
    await tester.pumpWidget(_host(selected: DockItemId.bots));
    await tester.pumpAndSettle();

    expect(_indicator, findsOneWidget);
    expect(
      _indicatorCenterX(tester),
      closeTo(_tileCenterX(tester, 'bots'), 0.5),
    );
    expect(find.byKey(const ValueKey('dock-top-hairline')), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('general-mode-floating-dock')),
        matching: find.byType(RepaintBoundary),
      ),
      findsWidgets,
    );
  });

  testWidgets('indicator slides between slots and then settles idle', (
    tester,
  ) async {
    await tester.pumpWidget(_host(selected: DockItemId.home));
    await tester.pumpAndSettle();
    final from = _tileCenterX(tester, 'home');
    final to = _tileCenterX(tester, 'settings');
    expect(_indicatorCenterX(tester), closeTo(from, 0.5));

    await tester.pumpWidget(_host(selected: DockItemId.settings));
    await tester.pump();
    await tester.pump(DockBar.indicatorDuration ~/ 2);
    final mid = _indicatorCenterX(tester);
    expect(mid, greaterThan(from + 1));
    expect(mid, lessThan(to - 1));

    await tester.pumpAndSettle();
    expect(_indicatorCenterX(tester), closeTo(to, 0.5));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('reduced motion snaps the indicator in one frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(selected: DockItemId.home, disableAnimations: true),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(selected: DockItemId.settings, disableAnimations: true),
    );
    // No pumpAndSettle: the very first frame already shows the final slot.
    expect(
      _indicatorCenterX(tester),
      closeTo(_tileCenterX(tester, 'settings'), 0.5),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('press shrinks a tile and it springs back on release', (
    tester,
  ) async {
    await tester.pumpWidget(_host(selected: DockItemId.home));
    await tester.pumpAndSettle();
    expect(_pressScaleOf(tester, 'bots'), 1);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('general-mode-dock-bots'))),
    );
    await tester.pump();
    expect(_pressScaleOf(tester, 'bots'), dockPressedScale);
    await tester.pumpAndSettle();
    expect(_renderedScaleOf(tester, 'bots'), closeTo(dockPressedScale, 0.001));
    // Only the pressed tile reacts.
    expect(_pressScaleOf(tester, 'home'), 1);

    await gesture.up();
    await tester.pump();
    expect(_pressScaleOf(tester, 'bots'), 1);
    await tester.pumpAndSettle();
    expect(_renderedScaleOf(tester, 'bots'), closeTo(1, 0.001));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('reduced motion never scales a pressed tile', (tester) async {
    await tester.pumpWidget(
      _host(selected: DockItemId.home, disableAnimations: true),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('general-mode-dock-bots'))),
    );
    await tester.pump();
    expect(_pressScaleOf(tester, 'bots'), 1);
    expect(_renderedScaleOf(tester, 'bots'), closeTo(1, 0.001));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('"+" is a compact accent tile as wide as a destination', (
    tester,
  ) async {
    var created = 0;
    await tester.pumpWidget(
      _host(selected: DockItemId.home, onCreate: () => created++),
    );
    await tester.pumpAndSettle();

    final plus = find.byKey(const ValueKey('general-mode-dock-create'));
    final home = find.byKey(const ValueKey('general-mode-dock-home'));
    expect(
      tester.getSize(plus).width,
      closeTo(tester.getSize(home).width, 0.01),
    );
    expect(tester.getSize(plus).height, tester.getSize(home).height);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('general-mode-floating-dock')))
          .height,
      48,
    );

    final colors = AppTheme.fromId('dark').hermes;
    final pill = tester
        .widgetList<DecoratedBox>(
          find.descendant(of: plus, matching: find.byType(DecoratedBox)),
        )
        .map((box) => (box.decoration as BoxDecoration).color)
        .whereType<Color>();
    expect(pill, isNotEmpty);
    expect(pill.first.r, closeTo(colors.accent.r, 0.01));
    expect(pill.first.a, lessThan(0.5));

    // The indicator never jumps onto the "+" and the tap still works.
    expect(
      _indicatorCenterX(tester),
      closeTo(_tileCenterX(tester, 'home'), 0.5),
    );
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(created, 1);
  });
}
