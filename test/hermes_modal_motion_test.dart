// Floating surfaces (menus, sheets, dialogs): the chrome's opaque tone, a
// scrim per kind, an exit that recedes towards where the surface came from,
// and a finger drag that takes a dismissible one away in one motion.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

const _surface = ValueKey('hermes-floating-surface');
const _dialog = ValueKey('hermes-dialog');
const _menu = ValueKey('hermes-menu');
const _open = ValueKey('open');

Future<void> _pump(
  WidgetTester tester,
  Future<Object?> Function(BuildContext context) show, {
  Alignment button = Alignment.center,
  String themeId = 'classic-dark',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.fromId(themeId),
      home: Scaffold(
        body: Align(
          alignment: button,
          child: Builder(
            builder: (context) => TextButton(
              key: _open,
              onPressed: () => show(context),
              child: const Text('Abrir'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_open));
  await tester.pumpAndSettle();
}

Color _scrim(WidgetTester tester) =>
    tester.widget<ModalBarrier>(find.byType(ModalBarrier).last).color!;

/// How far the surface under [key] has been dragged (0 at rest).
double _dragged(WidgetTester tester, Key key, Rect rest) =>
    tester.getRect(find.byKey(key)).top - rest.top;

Future<Object?> _confirm(BuildContext context, {bool dismissible = true}) =>
    showHermesDialog<bool>(
      context: context,
      title: '¿Borrar esta conversación?',
      message: 'Se borra de este móvil y del servidor.',
      barrierDismissible: dismissible,
      actions: const [
        HermesDialogAction(
          label: 'Cancelar',
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: 'Borrar',
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );

Future<Object?> _actions(BuildContext context) => showHermesMenu<String>(
  context: context,
  actions: const [
    HermesAction(value: 'a', label: 'Actualizar', icon: Icons.refresh),
    HermesAction(value: 'b', label: 'Ordenar', icon: Icons.sort),
  ],
);

Future<Object?> _sheet(BuildContext context, {int rows = 4}) =>
    showHermesSurface<void>(
      context: context,
      builder: (_) => ListView(
        key: const ValueKey('sheet-list'),
        shrinkWrap: true,
        children: [
          for (var i = 0; i < rows; i++)
            SizedBox(height: 56, child: Center(child: Text('Perfil $i'))),
        ],
      ),
    );

void main() {
  group('tone and scrim', () {
    testWidgets('a menu dims little, a sheet more, a dialog most', (
      tester,
    ) async {
      await _pump(tester, _actions);
      expect(_scrim(tester).a, closeTo(HermesChrome.scrimMenu, 0.005));
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await _pump(tester, _sheet);
      expect(_scrim(tester).a, closeTo(HermesChrome.scrimSheet, 0.005));
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await _pump(tester, _confirm);
      expect(_scrim(tester).a, closeTo(HermesChrome.scrimDialog, 0.005));
    });

    for (final id in const ['classic-dark', 'classic']) {
      testWidgets('$id: the surface is the chrome, opaque, with its hairline', (
        tester,
      ) async {
        await _pump(tester, _sheet, themeId: id);
        final chrome = HermesChrome.of(AppTheme.fromId(id).hermes);
        final surface = tester.widget<HermesFloatingSurface>(
          find.byKey(_surface),
        );
        expect(surface.modal, isTrue);
        final material = tester.widget<Material>(
          find
              .descendant(
                of: find.byKey(_surface),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(material.color, chrome.opaque);
        expect(
          (material.shape! as RoundedRectangleBorder).side.color,
          chrome.line,
        );
        expect(find.byType(BackdropFilter), findsNothing);
      });
    }
  });

  group('leaving', () {
    ScaleTransition scaleOf(WidgetTester tester, Key key) =>
        tester.widget<ScaleTransition>(
          find
              .ancestor(
                of: find.byKey(key),
                matching: find.byType(ScaleTransition),
              )
              .first,
        );

    testWidgets('a centred surface recedes: it shrinks and fades in place', (
      tester,
    ) async {
      await _pump(tester, _confirm);
      final rest = tester.getRect(find.byKey(_dialog));
      await tester.tap(find.text('Cancelar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final mid = tester.getRect(find.byKey(_dialog));
      expect(mid.width, lessThan(rest.width));
      expect(mid.center.dx, moreOrLessEquals(rest.center.dx, epsilon: 0.5));
      expect(mid.center.dy, moreOrLessEquals(rest.center.dy, epsilon: 0.5));
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byKey(_dialog),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(fade.opacity.value, lessThan(1));
      expect(fade.opacity.value, greaterThan(0));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
    });

    testWidgets('a menu recedes towards the button it came from', (
      tester,
    ) async {
      await _pump(tester, _actions, button: Alignment.topRight);
      final origin = tester.getRect(find.byKey(_open));
      final rest = tester.getRect(find.byKey(_menu));
      // The scale is anchored on the button, so the menu's centre moves
      // towards it as it shrinks.
      final alignment = scaleOf(tester, _menu).alignment;
      expect(alignment.x, greaterThan(0.5));
      expect(alignment.y, lessThan(-0.5));
      await tester.tapAt(const Offset(5, 590));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final mid = tester.getRect(find.byKey(_menu));
      expect(mid.width, lessThan(rest.width));
      expect(
        (mid.center - origin.center).distance,
        lessThan((rest.center - origin.center).distance),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_menu), findsNothing);
    });

    testWidgets('with reduced motion it just goes', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _pump(tester, _confirm);
      await tester.tap(find.text('Cancelar'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_dialog), findsNothing);
    });
  });

  group('dragging it away', () {
    testWidgets('a dialog follows the finger down; short of the threshold it '
        'settles back', (tester) async {
      await _pump(tester, _confirm);
      final rest = tester.getRect(find.byKey(_dialog));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('¿Borrar esta conversación?')),
      );
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      // (The first 18 px or so go to the touch slop.)
      final pulled = _dragged(tester, _dialog, rest);
      expect(pulled, greaterThan(20));
      expect(pulled, lessThanOrEqualTo(50));
      // Upwards is not a way out: it does not go above its place.
      await gesture.moveBy(const Offset(0, -200));
      await tester.pump();
      expect(_dragged(tester, _dialog, rest), 0);
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOneWidget);
      expect(_dragged(tester, _dialog, rest), moreOrLessEquals(0, epsilon: 1));
    });

    testWidgets('past the threshold it goes on from where the finger left it', (
      tester,
    ) async {
      await _pump(tester, _confirm);
      final rest = tester.getRect(find.byKey(_dialog));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('¿Borrar esta conversación?')),
      );
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      final left = tester.getRect(find.byKey(_dialog));
      expect(left.top - rest.top, greaterThan(80));
      await gesture.up();
      await tester.pump();
      // No snap back: on the first frames of the exit it is still down
      // there, already receding.
      await tester.pump(const Duration(milliseconds: 40));
      final leaving = tester.getRect(find.byKey(_dialog));
      expect(leaving.center.dy, greaterThan(rest.center.dy + 60));
      expect(leaving.width, lessThan(rest.width));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
    });

    testWidgets('a quick flick is enough', (tester) async {
      await _pump(tester, _sheet);
      await tester.fling(find.byKey(_surface), const Offset(0, 60), 1500);
      await tester.pumpAndSettle();
      expect(find.byKey(_surface), findsNothing);
    });

    testWidgets('a menu hanging from the top is pushed back up, not down', (
      tester,
    ) async {
      await _pump(tester, _actions, button: Alignment.topRight);
      final rest = tester.getRect(find.byKey(_menu));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Ordenar')),
      );
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();
      expect(_dragged(tester, _menu, rest), 0, reason: 'down is not its way');
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -130));
      await tester.pump();
      expect(_dragged(tester, _menu, rest), lessThan(-80));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(_menu), findsNothing);
    });

    testWidgets('a list at its top hands the pull over to the sheet', (
      tester,
    ) async {
      await _pump(tester, (context) => _sheet(context, rows: 30));
      final rest = tester.getRect(find.byKey(_surface));
      final list = find.byKey(const ValueKey('sheet-list'));
      // Scrolling down in the list moves the rows, not the sheet.
      await tester.drag(list, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(_dragged(tester, _surface, rest), 0);
      expect(find.text('Perfil 0'), findsNothing);
      await tester.drag(list, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(find.text('Perfil 0'), findsOneWidget);
      expect(find.byKey(_surface), findsOneWidget);
      // Back at the top, the same pull takes the sheet away.
      await tester.drag(list, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(find.byKey(_surface), findsNothing);
    });

    testWidgets('one that needs an answer does not move', (tester) async {
      await _pump(tester, (context) => _confirm(context, dismissible: false));
      final rest = tester.getRect(find.byKey(_dialog));
      expect(find.byKey(const ValueKey('hermes-surface-drag')), findsNothing);
      await tester.drag(
        find.text('¿Borrar esta conversación?'),
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(_dialog)), rest);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOneWidget);
      await tester.tap(find.text('Borrar'));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
    });
  });

  group('a dialog the caller builds', () {
    Future<Object?> raw(BuildContext context, {bool dismissible = true}) =>
        showHermesDialogRoute<bool>(
          context: context,
          barrierDismissible: dismissible,
          builder: (context) => AlertDialog(
            title: const Text('Clave del servidor'),
            content: const Text('La huella ha cambiado.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Aceptar'),
              ),
            ],
          ),
        );

    testWidgets('gets the dialog scrim, the tone and the drag down', (
      tester,
    ) async {
      await _pump(tester, raw);
      final chrome = HermesChrome.of(AppTheme.fromId('classic-dark').hermes);
      expect(_scrim(tester).a, closeTo(HermesChrome.scrimDialog, 0.005));
      expect(
        Theme.of(
          tester.element(find.byType(AlertDialog)),
        ).dialogTheme.backgroundColor,
        chrome.opaque,
      );
      await tester.drag(find.text('Clave del servidor'), const Offset(0, 180));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('and stays put when it needs an answer', (tester) async {
      await _pump(tester, (context) => raw(context, dismissible: false));
      await tester.drag(find.text('Clave del servidor'), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Aceptar'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
