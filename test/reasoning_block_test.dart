import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/reasoning_block.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// Verifica que el razonamiento (`<think>…`) se renderiza como bloque discreto
/// y separado de la respuesta final, por la ruta real ([AssistantMarkdownView]).
void main() {
  Widget host(String data, {bool isStreaming = false}) {
    return MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('es'),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.hermesRedDark,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: AssistantMarkdownView(data: data, isStreaming: isStreaming),
          ),
        ),
      ),
    );
  }

  testWidgets('retira el razonamiento y conserva solo la respuesta pública', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        '<think>El usuario pregunta la hora. Calculo y respondo.</think>'
        'Son las tres de la tarde.',
      ),
    );
    expect(find.byType(ReasoningBlock), findsNothing);
    expect(find.text('Razonamiento'), findsNothing);
    expect(find.textContaining('Son las tres'), findsOneWidget);
    // La etiqueta cruda nunca debe verse y, plegado, tampoco el razonamiento.
    expect(find.textContaining('<think>'), findsNothing);
    expect(find.textContaining('El usuario pregunta'), findsNothing);
  });

  testWidgets('no ofrece disclosure para expandir razonamiento', (
    tester,
  ) async {
    await tester.pumpWidget(host('<think>Paso 1. Paso 2.</think>Hecho.'));
    expect(find.byType(ReasoningBlock), findsNothing);
    expect(find.textContaining('Paso 1. Paso 2.'), findsNothing);
    expect(find.textContaining('Hecho.'), findsOneWidget);
  });

  testWidgets('streaming de reasoning puro no expone estado ni texto', (
    tester,
  ) async {
    await tester.pumpWidget(
      host('<think>sigo razonando sobre la respuesta', isStreaming: true),
    );
    expect(find.byType(ReasoningBlock), findsNothing);
    expect(find.text('Pensando…'), findsNothing);
    expect(find.textContaining('sigo razonando'), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('razonamiento cerrado tampoco crea un control táctil', (
    tester,
  ) async {
    await tester.pumpWidget(
      host('<think>Paso publicado.</think>Respuesta final.'),
    );

    expect(find.byType(ReasoningBlock), findsNothing);
    expect(find.textContaining('Paso publicado.'), findsNothing);
    expect(find.textContaining('Respuesta final.'), findsOneWidget);
  });

  testWidgets('Markdown interno se descarta junto con el razonamiento', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        '<think>## Plan\n\n- **Paso** `uno`</think>'
        'Respuesta final.',
      ),
    );

    expect(find.byType(ReasoningBlock), findsNothing);
    expect(find.textContaining('Plan'), findsNothing);
    expect(find.textContaining('Paso'), findsNothing);
    expect(find.textContaining('uno'), findsNothing);
    expect(find.textContaining('##'), findsNothing);
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('`'), findsNothing);
    expect(find.textContaining('Respuesta final.'), findsOneWidget);
  });

  testWidgets('sin razonamiento no se renderiza el bloque', (tester) async {
    await tester.pumpWidget(host('Respuesta normal sin razonamiento.'));
    expect(find.byType(ReasoningBlock), findsNothing);
    expect(find.textContaining('Respuesta normal'), findsOneWidget);
  });
}
