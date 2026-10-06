import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/callout_card.dart';
import 'package:hermes_android/core/widgets/hermes_file_tree.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

String _visibleMarkdownText(WidgetTester tester) {
  final richText = tester
      .widgetList<RichText>(find.byType(RichText))
      .map((widget) => widget.text.toPlainText());
  final selectableText = tester
      .widgetList<SelectableText>(find.byType(SelectableText))
      .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '');
  return [
    ...richText,
    ...selectableText,
  ].where((text) => text.isNotEmpty).join('\n');
}

/// Golden / widget tests del render del asistente.
///
/// Cubren la ruta real ([AssistantMarkdownView] usa la misma hoja de estilo,
/// los mismos code blocks y el normalizador de streaming que el chat) sin
/// depender de un modelo ni de un servidor. Para regenerar las imágenes:
///   flutter test --update-goldens test/assistant_markdown_golden_test.dart
void main() {
  Widget host(String data, {bool isStreaming = false}) {
    return MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('es'),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: const TextScaler.linear(FontSizeService.fixedScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: 360,
              child: AssistantMarkdownView(
                data: data,
                isStreaming: isStreaming,
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('AssistantMarkdownView golden', () {
    testWidgets('párrafos + lista + énfasis', (tester) async {
      const md = '''
Hermes está **listo**. Esto es un párrafo breve con *énfasis* y `código inline`.

Pasos:

1. Preparar el entorno
2. Lanzar el agente
3. Verificar la salida

- viñeta uno
- viñeta dos
''';
      await tester.pumpWidget(host(md));
      await expectLater(
        find.byType(AssistantMarkdownView),
        matchesGoldenFile('goldens/assistant_text_list.png'),
      );
    });

    testWidgets('bloque de código bash con cabecera', (tester) async {
      const md = '''
Ejecuta:

```bash
echo hola
ls -la /tmp
```
''';
      await tester.pumpWidget(host(md));
      // La cabecera del code block muestra el lenguaje y el botón copiar.
      expect(find.text('bash'), findsOneWidget);
      expect(find.byTooltip('Copiar código'), findsOneWidget);
      await expectLater(
        find.byType(AssistantMarkdownView),
        matchesGoldenFile('goldens/assistant_code_bash.png'),
      );
    });

    testWidgets('bloque filetree usa la jerarquía expandible', (tester) async {
      const md = '''
```filetree
lib/
├── core/
│   └── app.dart
└── main.dart
```
''';
      await tester.pumpWidget(host(md));

      expect(find.byType(HermesFileTree), findsOneWidget);
      expect(find.text('app.dart'), findsOneWidget);
      expect(find.byTooltip('Copiar código'), findsNothing);
    });

    testWidgets('tabla + blockquote', (tester) async {
      const md = '''
> Nota importante sobre la instancia.

| Clave | Valor |
| ----- | ----- |
| host  | local |
| port  | 9119  |
''';
      await tester.pumpWidget(host(md));
      expect(find.byType(Table), findsOneWidget);
      await expectLater(
        find.byType(AssistantMarkdownView),
        matchesGoldenFile('goldens/assistant_table_quote.png'),
      );
    });

    testWidgets('streaming: valla de código sin cerrar se renderiza estable', (
      tester,
    ) async {
      // Bloque abierto a mitad de stream: el normalizador lo cierra solo para
      // visualización, así que el contenido se ve como código, no como texto.
      const md = '''
Generando script:

```dart
void main() {
  print('hola''';
      await tester.pumpWidget(host(md, isStreaming: true));
      expect(find.text('dart'), findsOneWidget);
      await expectLater(
        find.byType(AssistantMarkdownView),
        matchesGoldenFile('goldens/assistant_streaming_open_fence.png'),
      );
    });

    testWidgets(
      'énfasis incompleto no filtra asteriscos en streaming; el terminal se pinta tal cual',
      (tester) async {
        String visibleText() => _visibleMarkdownText(tester);

        await tester.pumpWidget(
          host('Respuesta **importante', isStreaming: true),
        );
        expect(visibleText(), contains('Respuesta importante'));
        expect(visibleText(), isNot(contains('*')));

        // El mensaje terminal NO se repara: se renderiza como llegó del
        // servidor, así que el marcador sin cerrar queda visible en crudo.
        await tester.pumpWidget(host('Respuesta *terminal'));
        await tester.pump();
        expect(visibleText(), contains('Respuesta *terminal'));

        for (final marker in ['*', '**', '`', '[', 'Respuesta **']) {
          await tester.pumpWidget(host(marker, isStreaming: true));
          await tester.pump();
          expect(visibleText(), isNot(contains(marker.trim())));
        }
      },
    );

    testWidgets(
      'un delimitador huérfano en un mensaje terminal se pinta tal cual',
      (tester) async {
        const source = '''
Resumen **incompleto

Problema: el bloque intermedio separa el Markdown.

Final limpio.''';
        await tester.pumpWidget(host(source));

        final visible = _visibleMarkdownText(tester);
        // Contrato terminal: texto intacto, sin reparar ni ocultar marcadores.
        expect(visible, contains('Resumen **incompleto'));
        expect(
          visible,
          contains('Problema: el bloque intermedio separa el Markdown.'),
        );
        expect(visible, contains('Final limpio'));
        expect(find.byType(CalloutCard), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'énfasis con barras no se confunde con globs en ningún formato',
      (tester) async {
        String visibleText() => _visibleMarkdownText(tester);

        const corpus = '''
1. **Salud/ciencia**
2. **Economía/política**
3. *entrada/salida*
4. ***A/B***
5. **categoría/subcategoría con espacios**
''';
        await tester.pumpWidget(host(corpus));

        expect(visibleText(), contains('Salud/ciencia'));
        expect(visibleText(), contains('Economía/política'));
        expect(visibleText(), contains('entrada/salida'));
        expect(visibleText(), contains('categoría/subcategoría con espacios'));
        expect(visibleText(), isNot(contains('*')));

        await tester.pumpWidget(host('6. **Salud/ciencia', isStreaming: true));
        await tester.pump();
        expect(visibleText(), contains('Salud/ciencia'));
        expect(visibleText(), isNot(contains('*')));
      },
    );

    testWidgets(
      'caso real Modelo recomendado no muestra delimitadores en ningún frame',
      (tester) async {
        String visibleText() => _visibleMarkdownText(tester);

        const corpus = '''
**Modelo recomendado (simple y limpio)**

- **App base:** **Gratuita**
- **Pago opcional in-app:** **Pack de temas/personalización**
''';

        await tester.pumpWidget(host(corpus));
        expect(visibleText(), contains('Modelo recomendado (simple y limpio)'));
        expect(visibleText(), contains('App base: Gratuita'));
        expect(
          visibleText(),
          contains('Pago opcional in-app: Pack de temas/personalización'),
        );
        expect(visibleText(), isNot(contains('*')));

        for (var end = 1; end <= corpus.length; end++) {
          await tester.pumpWidget(
            host(corpus.substring(0, end), isStreaming: true),
          );
          await tester.pump();
          expect(
            visibleText(),
            isNot(contains('*')),
            reason: 'prefijo de streaming $end',
          );
        }
      },
    );

    testWidgets('prosa en ```text se muestra legible, no como code block', (
      tester,
    ) async {
      const md = '''
Resumen del estado:

```text
Todo OK
Sin incidencias importantes hoy
```
''';
      await tester.pumpWidget(host(md));
      // No debe tener la cabecera de code block (botón copiar).
      expect(find.byTooltip('Copiar código'), findsNothing);
      expect(find.textContaining('Sin incidencias'), findsOneWidget);
      await expectLater(
        find.byType(AssistantMarkdownView),
        matchesGoldenFile('goldens/assistant_prose_text.png'),
      );
    });

    testWidgets(
      'código real en ```text (con señales) sigue siendo code block',
      (tester) async {
        const md = '''
```text
export API_KEY=abc; run --now
```
''';
        await tester.pumpWidget(host(md));
        // Tiene `;`/`=` → se trata como código (con cabecera y copiar).
        expect(find.byTooltip('Copiar código'), findsOneWidget);
      },
    );

    testWidgets('estructura explícita sin callouts ni evidencia inferida', (
      tester,
    ) async {
      const md = '''
## Estado
Revisé la instancia local.

Problema: el venv de cryptography está roto y el agente no arranca.

Error: faltan símbolos de Python en _rust.abi3.so.

## Conclusión
La config sigue intacta en /home/demo/.hermes/memory/ y se puede reparar.''';
      await tester.pumpWidget(host(md));
      // Encabezados Markdown explícitos.
      expect(find.text('Estado'), findsOneWidget);
      expect(find.text('Conclusión'), findsOneWidget);
      expect(find.byType(CalloutCard), findsNothing);
      final visible = _visibleMarkdownText(tester);
      expect(visible, contains('Problema: el venv'));
      expect(visible, contains('Error: faltan símbolos'));
      expect(visible, contains('/home/demo/.hermes/memory/'));
      // Contrato terminal: el `_` sin cerrar de `_rust.abi3.so` se pinta
      // literal; ya no se cierra como cursiva inventada.
      expect(visible, contains('_rust.abi3.so'));
      await expectLater(
        find.byType(AssistantMarkdownView),
        matchesGoldenFile('goldens/assistant_semantic_layer.png'),
      );
    });

    testWidgets(
      'los saltos simples no parten frases ni paréntesis como en Desktop',
      (tester) async {
        const source =
            'Esto es una frase (\nejemplo...) que continúa\nen la misma línea.';
        await tester.pumpWidget(host(source));

        final visible = _visibleMarkdownText(tester);
        expect(
          visible,
          contains(
            'Esto es una frase ( ejemplo...) que continúa en la misma línea.',
          ),
        );
        expect(visible, isNot(contains('(\nejemplo')));
      },
    );
  });
}
