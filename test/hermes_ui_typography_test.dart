import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';

void main() {
  testWidgets('settings switches use the selected theme font for both lines', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: HermesSwitchTile(
            title: 'Herramientas',
            subtitle: 'Descripción',
            value: true,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.text('Herramientas')).style!.fontFamily,
      'Inter',
    );
    expect(
      tester.widget<Text>(find.text('Descripción')).style!.fontFamily,
      'Inter',
    );
  });
  testWidgets('shared forms keep a readable and neutral type scale', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const HermesSectionHeader('Datos del bot'),
                  HermesField(
                    label: 'Nombre del bot',
                    controller: controller,
                    helperText: 'Se muestra en la lista de bots.',
                    errorText: 'Escribe un nombre.',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final section = tester.widget<Text>(find.text('Datos del bot'));
    expect(section.style?.fontSize, 13);
    expect(section.style?.fontWeight, FontWeight.w600);
    expect(section.style?.letterSpacing, 0);

    final label = tester.widget<Text>(find.text('Nombre del bot'));
    expect(label.style?.fontSize, 13);
    expect(label.style?.fontWeight, FontWeight.w500);
    expect(label.style?.letterSpacing, 0);
    expect(find.text('NOMBRE DEL BOT'), findsNothing);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.style?.fontSize, 14);
    expect(field.decoration?.helperStyle?.fontSize, 12.5);
    expect(field.decoration?.errorStyle?.fontSize, 12.5);
    expect(tester.takeException(), isNull);
  });
}
