// `showDockAnchoredPopover` no tenía tests propios. Cubre tres hallazgos de
// la revisión exhaustiva del dock:
//
//  - A1 [alta, MEDIDO]: el popover nunca leía `MediaQuery.viewInsets`, así
//    que con el teclado abierto (Tareas/Cron, `TextField(autofocus: true)`)
//    quedaba casi entero tapado.
//  - A6 [media, MEDIDO]: mezclaba coordenadas globales (la posición del
//    ancla) con un `Positioned(bottom:)` que vivía dentro de un `SafeArea`
//    ya restado, desalineando el popover del botón por el inset inferior
//    del sistema.
//  - El caso borde de `GlobalKey` no montado (o cuyo `RenderBox` no está
//    disponible): debe caer a una posición por defecto sin fallar.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/dock_anchored_popover.dart';

const _popoverContentKey = ValueKey('popover-content');

Widget _harness({
  required GlobalKey anchorKey,
  EdgeInsets viewInsets = EdgeInsets.zero,
  EdgeInsets padding = EdgeInsets.zero,
  bool attachAnchor = true,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      viewInsets: viewInsets,
      padding: padding,
      disableAnimations: true,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: Stack(
      children: [
        // Ancla realista: un botón de 48x48 cerca del centro inferior,
        // igual que el "+" del dock flotante.
        if (attachAnchor)
          Positioned(
            left: 150,
            bottom: 48,
            child: SizedBox(key: anchorKey, width: 48, height: 48),
          ),
        Align(
          alignment: Alignment.topCenter,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDockAnchoredPopover<void>(
                context: context,
                anchorKey: anchorKey,
                builder: (_) => const ColoredBox(
                  key: _popoverContentKey,
                  color: Colors.black,
                  child: SizedBox(width: 260, height: 220),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ],
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'stays anchored to the button by a small, constant gap regardless of '
    'the system bottom inset (A6: no more mixing global/SafeArea-local space)',
    (tester) async {
      final anchorKey = GlobalKey();
      // Inset inferior de sistema (gesto/nav bar) considerable: antes de la
      // corrección, el `SafeArea` que envolvía el popover restaba este
      // inset una segunda vez sobre coordenadas ya globales, midiendo un
      // hueco de ~44dp en vez de los ~10dp buscados.
      await tester.pumpWidget(
        _harness(anchorKey: anchorKey, padding: const EdgeInsets.only(bottom: 24)),
      );
      await tester.pumpAndSettle();

      final anchorRectBefore = tester.getRect(find.byKey(anchorKey));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final popoverRect = tester.getRect(find.byKey(_popoverContentKey));
      final gap = anchorRectBefore.top - popoverRect.bottom;

      // El hueco pretendido es de 10dp por encima del ancla,
      // independientemente del padding inferior del sistema.
      expect(gap, closeTo(10, 1));
    },
  );

  testWidgets(
    'never lands under the on-screen keyboard (A1: viewInsets.bottom is '
    'now the popover floor)',
    (tester) async {
      final anchorKey = GlobalKey();
      const keyboardHeight = 300.0;
      await tester.pumpWidget(
        _harness(
          anchorKey: anchorKey,
          viewInsets: const EdgeInsets.only(bottom: keyboardHeight),
        ),
      );
      await tester.pumpAndSettle();

      final screenHeight = tester.view.physicalSize.height /
          tester.view.devicePixelRatio;

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final popoverRect = tester.getRect(find.byKey(_popoverContentKey));
      final distanceFromBottom = screenHeight - popoverRect.bottom;

      // Antes del fix, el ancla (cerca del suelo real de la pantalla) fijaba
      // un `bottom` pequeño sin mirar el teclado en absoluto, dejando el
      // popover casi entero bajo los 300dp del teclado simulado (medido en
      // dispositivo real: 216 de 220px tapados). Ahora el suelo nunca cae
      // por debajo del teclado.
      expect(distanceFromBottom, greaterThanOrEqualTo(keyboardHeight));
    },
  );

  testWidgets(
    'falls back to a default position instead of failing when the anchor '
    'GlobalKey is not attached to anything',
    (tester) async {
      final unattachedKey = GlobalKey();
      await tester.pumpWidget(
        _harness(anchorKey: unattachedKey, attachAnchor: false),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(_popoverContentKey), findsOneWidget);
    },
  );
}
