import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/scroll_behavior.dart';

/// Regresión de #48: los logs largos dentro de una hoja flotante no
/// respondían al arrastre. `SelectableText` reclama el gesto vertical para
/// extender la selección, así que el `SingleChildScrollView` que lo contiene
/// nunca recibía el drag y el contenido se quedaba clavado arriba.
/// La selección de texto la aporta ahora `SelectionArea`, que no compite por
/// el gesto de arrastre.
void main() {
  testWidgets('un log largo se puede desplazar con el dedo', (tester) async {
    final log = List.generate(400, (i) => 'linea de log $i').join('\n');
    await tester.binding.setSurfaceSize(const Size(411, 866));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const MomentumScrollBehavior(),
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: SingleChildScrollView(
                child: SelectionArea(
                  child: Text(
                    log,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(
      position.maxScrollExtent,
      greaterThan(0),
      reason: 'el log debe desbordar el viewport',
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SingleChildScrollView)),
    );
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      greaterThan(0),
      reason: 'el arrastre debe mover el log, no rebotar al principio',
    );
  });
}
