import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart'
    show showHermesFloatingSurface;
import 'package:hermes_android/l10n/app_localizations.dart';

Future<BuildContext> _host(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  EdgeInsets viewInsets = EdgeInsets.zero,
  GlobalKey? anchor,
  Alignment anchorAlign = Alignment.topRight,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (viewInsets != EdgeInsets.zero) {
    tester.view.viewInsets = FakeViewPadding(bottom: viewInsets.bottom);
    addTearDown(tester.view.resetViewInsets);
  }
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context),
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Builder(
              builder: (c) {
                ctx = c;
                return Align(
                  alignment: anchorAlign,
                  child: SizedBox(key: anchor, width: 48, height: 48),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  return ctx;
}

List<HermesOption<int>> _options(int n) => [
  for (var i = 0; i < n; i++)
    HermesOption(
      value: i,
      label: 'Option $i',
      group: i < n / 2 ? 'First' : 'Second',
      key: ValueKey('opt-$i'),
    ),
];

void main() {
  testWidgets('centred surface is content-sized and rounded 22', (
    tester,
  ) async {
    final ctx = await _host(tester);
    showHermesOptions<int>(context: ctx, options: _options(3), selected: 1);
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('hermes-option-surface'));
    final rect = tester.getRect(surface);
    expect(rect.height, lessThan(844 * 0.5));
    expect((rect.center.dx - 195).abs(), lessThan(1));
    final material = tester.widget<Material>(surface);
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(22));
    // Selected option shows a check; no search under the threshold.
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('hermes-option-search')), findsNothing);
    expect(find.text('FIRST'), findsOneWidget);
  });

  testWidgets('long lists cap at 70% and offer search', (tester) async {
    final ctx = await _host(tester, size: const Size(360, 800));
    showHermesOptions<int>(context: ctx, options: _options(40));
    await tester.pumpAndSettle();
    final rect = tester.getRect(
      find.byKey(const ValueKey('hermes-option-surface')),
    );
    expect(rect.height, lessThanOrEqualTo(800 * 0.7));
    expect(find.byKey(const ValueKey('hermes-option-search')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('hermes-option-search')),
      'Option 3',
    );
    await tester.pumpAndSettle();
    // Option 3, 30..39
    expect(find.byKey(const ValueKey('opt-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('opt-4')), findsNothing);
  });

  testWidgets('inner option list clamps (never bounces)', (tester) async {
    final ctx = await _host(tester);
    showHermesOptions<int>(context: ctx, options: _options(3));
    await tester.pumpAndSettle();
    final state = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('hermes-option-list')),
        matching: find.byType(Scrollable),
      ),
    );
    ScrollPhysics? p = state.position.physics;
    var bounces = false;
    while (p != null) {
      bounces |= p is BouncingScrollPhysics;
      p = p.parent;
    }
    expect(bounces, isFalse);
  });

  testWidgets('anchored popover sits by its origin, inside the screen', (
    tester,
  ) async {
    final anchor = GlobalKey();
    final ctx = await _host(tester, anchor: anchor);
    showHermesMenu<String>(
      context: ctx,
      anchorKey: anchor,
      actions: const [
        HermesAction(value: 'delete', label: 'Delete', destructive: true),
        HermesAction(value: 'edit', label: 'Edit'),
      ],
    );
    await tester.pumpAndSettle();
    final origin = tester.getRect(find.byKey(anchor));
    final rect = tester.getRect(find.byKey(const ValueKey('hermes-menu')));
    expect(rect.top, greaterThanOrEqualTo(origin.bottom));
    expect(rect.right, lessThanOrEqualTo(390 - 12 + 0.1));
    // Destructive action rendered last.
    expect(
      tester.getTopLeft(find.text('Delete')).dy,
      greaterThan(tester.getTopLeft(find.text('Edit')).dy),
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hermes-menu')), findsNothing);
  });

  testWidgets('anchor near the bottom flips above', (tester) async {
    final anchor = GlobalKey();
    final ctx = await _host(
      tester,
      anchor: anchor,
      anchorAlign: Alignment.bottomCenter,
    );
    showHermesMenu<String>(
      context: ctx,
      anchorKey: anchor,
      actions: const [
        HermesAction(value: 'a', label: 'A'),
        HermesAction(value: 'b', label: 'B'),
        HermesAction(value: 'c', label: 'C'),
      ],
    );
    await tester.pumpAndSettle();
    final origin = tester.getRect(find.byKey(anchor));
    final rect = tester.getRect(find.byKey(const ValueKey('hermes-menu')));
    expect(rect.bottom, lessThanOrEqualTo(origin.top));
  });

  test('anchored geometry respects the keyboard', () {
    final rect = hermesAnchoredSurfaceRect(
      screen: const Size(390, 844),
      safe: const EdgeInsets.only(top: 24, bottom: 24),
      keyboard: 320,
      origin: const Rect.fromLTWH(20, 400, 350, 52),
      width: 300,
      height: 260,
    );
    expect(rect.bottom, lessThanOrEqualTo(844 - 320 - 12 + 0.1));
    expect(rect.top, greaterThanOrEqualTo(24 + 12 - 0.1));
  });

  testWidgets('centred surface stays above the IME', (tester) async {
    final ctx = await _host(
      tester,
      viewInsets: const EdgeInsets.only(bottom: 300),
    );
    showHermesOptions<int>(context: ctx, options: _options(20));
    await tester.pumpAndSettle();
    final rect = tester.getRect(
      find.byKey(const ValueKey('hermes-option-surface')),
    );
    expect(rect.bottom, lessThanOrEqualTo(844 - 300));
  });

  testWidgets('dialog: pill actions of 48 dp, destructive returns value', (
    tester,
  ) async {
    final ctx = await _host(tester);
    final result = showHermesDialog<bool>(
      context: ctx,
      title: 'Delete task',
      message: 'Delete "News"?',
      actions: const [
        HermesDialogAction(
          label: 'Cancel',
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: ValueKey('confirm'),
          label: 'Delete',
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('confirm'))).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.byKey(const ValueKey('confirm')));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets('model picker groups providers, default row and check', (
    tester,
  ) async {
    final ctx = await _host(tester);
    final result = showHermesModelPicker(
      context: ctx,
      defaultLabel: 'Default',
      current: const HermesModelChoice('openai', 'gpt-5.5'),
      groups: const [
        HermesModelGroup(
          slug: 'openai',
          name: 'OpenAI',
          models: ['gpt-5.5', 'gpt-5.5-mini'],
        ),
        HermesModelGroup(slug: 'local', name: 'Local · GPU', models: ['qwen']),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('OPENAI'), findsOneWidget);
    expect(find.text('LOCAL · GPU'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hermes-model-local-qwen')));
    await tester.pumpAndSettle();
    expect(await result, const HermesModelChoice('local', 'qwen'));
  });

  testWidgets('legacy showHermesFloatingSurface uses the new container', (
    tester,
  ) async {
    final ctx = await _host(tester);
    showHermesFloatingSurface<void>(
      context: ctx,
      surfaceKey: const ValueKey('legacy'),
      builder: (_) => const SizedBox(height: 2000, width: 300),
    );
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const ValueKey('legacy')));
    expect(rect.height, lessThanOrEqualTo(844 * 0.88));
  });
}
