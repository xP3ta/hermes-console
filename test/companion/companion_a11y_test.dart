import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/render/companion_view.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      CompanionPreferences.enabledKey: true,
    }),
  );

  testWidgets('CompanionView expone Semantics "Companion animado"', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: CompanionView()));
    expect(find.bySemanticsLabel('Companion animado'), findsOneWidget);
  });

  testWidgets('bajo disableAnimations no lanza ni deja timers pendientes', (
    tester,
  ) async {
    final prefs = await CompanionPreferences.load();
    final controller = CompanionController(CompanionRepository(), prefs);
    await controller.setEnabled(true);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: CompanionView(controller: controller),
        ),
      ),
    );
    // Etiqueta de accesibilidad presente y sin animación de bucle activa.
    expect(find.bySemanticsLabel('Companion animado'), findsOneWidget);
  });
}
