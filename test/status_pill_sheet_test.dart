import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/status_pill_sheet.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _surface = ValueKey('status-sheet-test');
const _handle = ValueKey('status-sheet-handle');

void main() {
  Future<void> openSheet(
    WidgetTester tester, {
    int rows = 3,
    bool reduceMotion = false,
    double textScale = 1,
    Widget? field,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('amber'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduceMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                ?field,
                TextButton(
                  key: const ValueKey('open'),
                  onPressed: () => showStatusPillSheet<void>(
                    context: context,
                    surfaceKey: _surface,
                    title: 'Uso de contexto',
                    subtitle: 'Esta sesión',
                    builder: (_) => Column(
                      children: [
                        for (var i = 0; i < rows; i++)
                          SizedBox(
                            height: 60,
                            child: Text(
                              'Fila $i con un texto largo que debe partirse '
                              'en varias líneas',
                            ),
                          ),
                      ],
                    ),
                  ),
                  child: const Text('abrir'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsOneWidget);
  }

  testWidgets('opens anchored at the bottom with title and closes on X', (
    tester,
  ) async {
    await openSheet(tester);
    expect(find.text('Uso de contexto'), findsOneWidget);
    expect(find.text('Esta sesión'), findsOneWidget);
    final rect = tester.getRect(find.byKey(_surface));
    expect(rect.bottom, closeTo(800 - 10, 1));
    expect(rect.left, closeTo(10, 1));
    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('a tap outside closes it', (tester) async {
    await openSheet(tester);
    await tester.tapAt(const Offset(180, 40));
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('system Back closes it', (tester) async {
    await openSheet(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('a short slow drag springs back; past 100 px it closes', (
    tester,
  ) async {
    await openSheet(tester);
    final rest = tester.getRect(find.byKey(_surface));

    // 60 px, slowly: below both thresholds.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_handle)),
    );
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 100));
    }
    // It follows the finger while dragged.
    expect(tester.getRect(find.byKey(_surface)).top, greaterThan(rest.top));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsOneWidget);
    expect(tester.getRect(find.byKey(_surface)).top, closeTo(rest.top, 0.5));

    // 130 px, slowly: past the distance threshold.
    final far = await tester.startGesture(
      tester.getCenter(find.byKey(_handle)),
    );
    for (var i = 0; i < 13; i++) {
      await far.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await far.up();
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('a quick downward flick closes it under 100 px', (tester) async {
    await openSheet(tester);
    await tester.fling(find.byKey(_handle), const Offset(0, 60), 1200);
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('an upward drag never moves or closes it', (tester) async {
    await openSheet(tester);
    final rest = tester.getRect(find.byKey(_surface));
    await tester.fling(find.byKey(_handle), const Offset(0, -150), 1500);
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsOneWidget);
    expect(tester.getRect(find.byKey(_surface)).top, closeTo(rest.top, 0.5));
  });

  testWidgets('long content scrolls inside; it only closes from the top', (
    tester,
  ) async {
    await openSheet(tester, rows: 30);
    final scroll = find.byKey(const ValueKey('status-sheet-scroll'));
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)),
        )
        .position;
    expect(position.maxScrollExtent, greaterThan(0));

    // Scroll the content down first.
    await tester.drag(scroll, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(300));

    // A downward drag from the middle scrolls back up; it does not close.
    await tester.drag(scroll, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsOneWidget);
    expect(position.pixels, greaterThan(0));

    // Back at the top, the same pull closes the sheet.
    position.jumpTo(0);
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(scroll));
    for (var i = 0; i < 16; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('content that fits can also be dragged closed', (tester) async {
    await openSheet(tester, rows: 2);
    await tester.fling(
      find.text('Fila 1 con un texto largo que debe partirse en varias líneas'),
      const Offset(0, 60),
      1200,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('reduced motion: visible on the first frame, no spring', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    await openSheet(tester, reduceMotion: true);
    final rest = tester.getRect(find.byKey(_surface));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_handle)),
    );
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    // One frame, no animation: back in place immediately.
    await tester.pump();
    expect(tester.getRect(find.byKey(_surface)).top, closeTo(rest.top, 0.5));

    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pump();
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('fits at 360 dp with text at 200 %', (tester) async {
    await openSheet(tester, rows: 12, textScale: 2);
    expect(tester.takeException(), isNull);
    final rect = tester.getRect(find.byKey(_surface));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(800));
  });

  group('keyboard', () {
    Future<FocusNode> focusField(WidgetTester tester) async {
      final field = find.byKey(const ValueKey('field'));
      await tester.tap(field);
      await tester.pump();
      return tester.widget<TextField>(field).focusNode!;
    }

    testWidgets('closing with the keyboard hidden never reopens it', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      // Prepare the field, focus it, then hide the keyboard (system Back).
      await openSheet(
        tester,
        field: TextField(key: const ValueKey('field'), focusNode: node),
      );
      await tester.tap(find.byTooltip('Cerrar'));
      await tester.pumpAndSettle();
      final focus = await focusField(tester);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      tester.testTextInput.log.clear();
      for (final close in <Future<void> Function()>[
        () => tester.fling(find.byKey(_handle), const Offset(0, 160), 1500),
      ]) {
        await close();
        await tester.pumpAndSettle();
      }
      expect(find.byKey(_surface), findsNothing);
      expect(
        tester.testTextInput.log.where((c) => c.method == 'TextInput.show'),
        isEmpty,
      );
      expect(focus.hasFocus, isFalse);
    });

    testWidgets('with the keyboard visible the field gets its focus back', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await openSheet(
        tester,
        field: TextField(key: const ValueKey('field'), focusNode: node),
      );
      await tester.tap(find.byTooltip('Cerrar'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      final focus = await focusField(tester);
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      // Sits above the keyboard.
      expect(
        tester.getRect(find.byKey(_surface)).bottom,
        lessThanOrEqualTo(800 - 300),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(_surface), findsNothing);
      expect(focus.hasFocus, isTrue);
    });
  });
}
