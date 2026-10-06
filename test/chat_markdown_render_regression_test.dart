import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/streaming_normalizer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

TextSpan _markdownSpanContaining(WidgetTester tester, String text) {
  for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
    if (widget.text.toPlainText().contains(text) && widget.text is TextSpan) {
      return widget.text as TextSpan;
    }
  }
  for (final widget in tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  )) {
    final span =
        widget.textSpan ??
        TextSpan(text: widget.data ?? '', style: widget.style);
    if (span.toPlainText().contains(text)) return span;
  }
  throw StateError('Markdown span not found: $text');
}

void main() {
  testWidgets(
    'strong y em dentro de un heading heredan el mismo tamaño efectivo',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.hermesRedDark,
          home: const Scaffold(
            body: AssistantMarkdownView(
              data: '## Título **importante** y *claro*',
              isStreaming: false,
            ),
          ),
        ),
      );

      final headingSpan = _markdownSpanContaining(tester, 'Título importante');
      final leaves = <TextStyle>[];

      void collect(InlineSpan span, TextStyle? inherited) {
        if (span is! TextSpan) return;
        final effective = inherited == null
            ? span.style
            : inherited.merge(span.style);
        if (span.text?.trim().isNotEmpty ?? false) {
          leaves.add(effective ?? const TextStyle());
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          collect(child, effective);
        }
      }

      collect(headingSpan, null);
      expect(headingSpan.toPlainText(), 'Título importante y claro');
      expect(leaves, isNotEmpty);
      final titleSize = leaves.first.fontSize;
      expect(titleSize, lessThanOrEqualTo(17));
      for (final style in leaves) {
        expect(style.fontSize, titleSize);
        expect(style.color, leaves.first.color);
        expect(style.fontWeight, FontWeight.w700);
      }
      expect(
        leaves.any((style) => style.fontStyle == FontStyle.italic),
        isTrue,
      );
    },
  );

  testWidgets('h1 a h6 tienen métricas móviles compactas y deterministas', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        home: const Scaffold(
          body: AssistantMarkdownView(
            data:
                '# Uno\n\n## Dos\n\n### Tres\n\n'
                '#### Cuatro\n\n##### Cinco\n\n###### Seis',
            isStreaming: false,
          ),
        ),
      ),
    );

    double? sizeOf(String text) {
      final headingSpan = _markdownSpanContaining(tester, text);
      TextStyle? leafStyle;

      void visit(InlineSpan span, TextStyle? inherited) {
        if (span is! TextSpan) return;
        final effective = inherited == null
            ? span.style
            : inherited.merge(span.style);
        if (span.text?.trim().isNotEmpty ?? false) leafStyle = effective;
        for (final child in span.children ?? const <InlineSpan>[]) {
          visit(child, effective);
        }
      }

      visit(headingSpan, null);
      return leafStyle?.fontSize;
    }

    expect(sizeOf('Uno'), 18);
    expect(sizeOf('Dos'), 16.5);
    expect(sizeOf('Tres'), 15.5);
    expect(sizeOf('Cuatro'), 15);
    expect(sizeOf('Cinco'), 15);
    expect(sizeOf('Seis'), 15);
  });

  testWidgets('código inline conserva el flujo con puntuación adyacente', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        home: const Scaffold(
          body: SizedBox(
            width: 360,
            child: AssistantMarkdownView(
              data:
                  '- Repo remoto `d50ImYR1` (`Backup_Hetzner_Box`) → '
                  '**954,665,924,489 bytes** '
                  '(`total_uncompressed_size`: 958,581,035,086, ~0.4%)',
              isStreaming: false,
            ),
          ),
        ),
      ),
    );

    final formerChipContainers = tester
        .widgetList<Container>(
          find.ancestor(
            of: find.byType(RichText),
            matching: find.byType(Container),
          ),
        )
        .where(
          (container) =>
              container.decoration is BoxDecoration &&
              (container.decoration! as BoxDecoration).borderRadius ==
                  BorderRadius.circular(5),
        )
        .toList();
    expect(formerChipContainers, isEmpty);
    expect(tester.takeException(), isNull);

    final span = _markdownSpanContaining(tester, 'Backup_Hetzner_Box');
    expect(span.toPlainText(), contains('(Backup_Hetzner_Box)'));
    final colors = Theme.of(
      tester.element(find.byType(AssistantMarkdownView)),
    ).hermes;
    final inlineStyles = <TextStyle>[];

    void collect(InlineSpan current, TextStyle? inherited) {
      if (current is! TextSpan) return;
      final effective = inherited == null
          ? current.style
          : inherited.merge(current.style);
      if (current.text?.contains('Backup_Hetzner_Box') ?? false) {
        inlineStyles.add(effective ?? const TextStyle());
      }
      for (final child in current.children ?? const <InlineSpan>[]) {
        collect(child, effective);
      }
    }

    collect(span, null);
    expect(inlineStyles, hasLength(1));
    expect(inlineStyles.single.fontFamily, 'JetBrainsMono');
    // Píldora sutil (fondo de texto en la propia línea), nunca un chip
    // contenedor que rompa el flujo: ver formerChipContainers arriba.
    expect(
      inlineStyles.single.backgroundColor,
      colors.surfaceVariant.withValues(alpha: 0.85),
    );
    expect(
      inlineStyles.single.color,
      colors.textPrimary.withValues(alpha: 0.92),
    );
  });

  testWidgets('aproximaciones y rutas adyacentes se componen sin bloques', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        home: const Scaffold(
          body: SizedBox(
            width: 360,
            child: AssistantMarkdownView(
              data:
                  'Ocupa ~955 GB y `~/backups` mantiene '
                  '`/home/backups/keys`,`locks`.',
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('aprox. 955 GB'), findsOneWidget);
    final span = _markdownSpanContaining(tester, '/home/backups/keys');
    expect(span.toPlainText(), contains('/home/backups/keys, locks'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('listas anidadas conservan una sangría móvil contenida', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        home: const Scaffold(
          body: SizedBox(
            width: 360,
            child: AssistantMarkdownView(
              data: '- Elemento padre\n  - Elemento hijo',
              isStreaming: false,
            ),
          ),
        ),
      ),
    );

    final parent = find.text('Elemento padre');
    final child = find.text('Elemento hijo');
    expect(parent, findsOneWidget);
    expect(child, findsOneWidget);
    final nestingOffset =
        tester.getTopLeft(child).dx - tester.getTopLeft(parent).dx;
    expect(nestingOffset, greaterThan(0));
    expect(nestingOffset, lessThanOrEqualTo(24));
  });

  testWidgets(
    'resumen de subagentes oculta IDs y conserva detalle técnico plegado',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.hermesRedDark,
          home: const Scaffold(
            body: AssistantMarkdownView(
              data:
                  '- Batch `deleg_339f13db`\n'
                  '  - `{"result": 4}`\n'
                  '- Batch `deleg_4f2cd174`\n'
                  '  - `{"result": 6}`',
            ),
          ),
        ),
      );

      expect(find.textContaining('Subagente 1'), findsOneWidget);
      expect(find.textContaining('Resultado: 4'), findsOneWidget);
      expect(find.textContaining('deleg_'), findsNothing);
      expect(find.text('Detalles técnicos'), findsOneWidget);

      final disclosure = tester
          .widgetList<Semantics>(
            find.ancestor(
              of: find.text('Detalles técnicos'),
              matching: find.byType(Semantics),
            ),
          )
          .firstWhere(
            (widget) => widget.properties.label == 'Detalles técnicos',
          );
      expect(disclosure.properties.expanded, isFalse);

      await tester.tap(find.text('Detalles técnicos'));
      await tester.pumpAndSettle();

      expect(find.textContaining('deleg_339f13db'), findsOneWidget);
      final expanded = tester
          .widgetList<Semantics>(
            find.ancestor(
              of: find.text('Detalles técnicos'),
              matching: find.byType(Semantics),
            ),
          )
          .firstWhere(
            (widget) => widget.properties.label == 'Detalles técnicos',
          );
      expect(expanded.properties.expanded, isTrue);
    },
  );

  test('el chat no inventa headings ni listas a partir de prosa', () {
    for (final source in [
      'Estado:\nTodo correcto.',
      'algo previo.\n\nResumen honesto\n\nEl cuerpo va aquí.',
      'Opciones:\nuno\ndos',
      'clave: uno\notra: dos',
    ]) {
      expect(prepareAssistantAnswerStructure(source), source, reason: source);
    }

    const explicit = '## Estado\n\n- uno\n- dos';
    expect(prepareAssistantAnswerStructure(explicit), explicit);
  });

  testWidgets('prosa y rutas no se convierten en tarjetas ni chips', (
    tester,
  ) async {
    final markdownInputs = <String>[];
    var calloutBuilds = 0;

    buildAssistantAnswerBlocks(
      'Problema: sigue intacto en /home/demo/.hermes/memory/.',
      isStreaming: false,
      markdown: (data) {
        markdownInputs.add(data);
        return const SizedBox();
      },
      callout: (_) {
        calloutBuilds++;
        return const SizedBox();
      },
    );

    expect(calloutBuilds, 0);
    expect(markdownInputs, [
      'Problema: sigue intacto en /home/demo/.hermes/memory/.',
    ]);
  });

  test('streaming oculta marcadores de bloque sin contenido', () {
    for (final marker in ['-', '+', '1.', '#', '##', '>']) {
      expect(
        normalizeStreamingMarkdown(marker, isStreaming: true),
        '',
        reason: marker,
      );
    }
    expect(
      normalizeStreamingMarkdown('Texto previo\n\n1.', isStreaming: true),
      'Texto previo\n\n',
    );
    expect(normalizeStreamingMarkdown('---', isStreaming: true), '---');
  });

  test(
    'partes de texto consecutivas no rompen Markdown con saltos inventados',
    () {
      final text = desktopSessionDisplayText([
        {'type': 'text', 'text': '## Títu'},
        {'type': 'text', 'text': 'lo **importante**'},
      ]);

      expect(text, '## Título **importante**');
    },
  );
}
