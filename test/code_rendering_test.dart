import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// Render de código/comandos/salida: monoespaciado real y `markdown` prosa que
/// NO debe verse como bloque de código.
void main() {
  Widget host(Widget child) => MaterialApp(
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    locale: const Locale('es'),
    debugShowCheckedModeBanner: false,
    theme: AppTheme.hermesRedDark,
    home: Scaffold(
      body: Center(child: SizedBox(width: 360, child: child)),
    ),
  );

  // Verdadero si algún Text con el texto buscado se pinta en 'monospace'.
  // Soporta Text plano (estilo en el widget) y Text.rich del resaltado de
  // sintaxis (estilo en el TextSpan raíz).
  bool hasMonoText(WidgetTester tester, Pattern contains) {
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      final span = t.textSpan;
      final plain = t.data ?? span?.toPlainText() ?? '';
      if (!plain.contains(contains)) continue;
      final family =
          t.style?.fontFamily ??
          (span is TextSpan ? span.style?.fontFamily : null);
      if (family == 'monospace') return true;
    }
    return false;
  }

  void expectAbsentFromPublicProjection(WidgetTester tester, String sentinel) {
    final plainText = tester
        .widgetList<Text>(find.byType(Text, skipOffstage: false))
        .map((widget) => widget.data ?? '')
        .join('\n');
    final textSpans = tester
        .widgetList<Text>(find.byType(Text, skipOffstage: false))
        .map((widget) => widget.textSpan?.toPlainText() ?? '')
        .join('\n');
    final selectableText = tester
        .widgetList<SelectableText>(
          find.byType(SelectableText, skipOffstage: false),
        )
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .join('\n');

    expect(plainText, isNot(contains(sentinel)));
    expect(textSpans, isNot(contains(sentinel)));
    expect(selectableText, isNot(contains(sentinel)));
    expect(
      find.textContaining(sentinel, findRichText: true, skipOffstage: false),
      findsNothing,
    );
    expect(
      find.bySemanticsLabel(RegExp(RegExp.escape(sentinel))),
      findsNothing,
    );
  }

  Future<void> expectFailClosedRender(
    WidgetTester tester,
    Map<String, dynamic> message,
    List<String> sentinels,
  ) async {
    final info = ChatEventInfo.classify(message);
    final semantics = tester.ensureSemantics();
    try {
      expect(info.kind, ChatEventKind.toolEvent);
      await tester.pumpWidget(host(ToolEventCard(info: info)));

      final card = find.byType(ToolEventCard);
      final expander = find.descendant(
        of: card,
        matching: find.byType(InkWell),
      );
      final rotation = find.descendant(
        of: card,
        matching: find.byType(AnimatedRotation),
      );
      expect(card, findsOneWidget);
      expect(find.text('herramienta'), findsOneWidget);
      expect(find.text('completado'), findsOneWidget);
      expect(expander, findsOneWidget);
      expect(tester.widget<AnimatedRotation>(rotation).turns, 0);
      for (final sentinel in sentinels) {
        expectAbsentFromPublicProjection(tester, sentinel);
      }

      await tester.tap(expander);
      await tester.pumpAndSettle();

      expect(tester.widget<AnimatedRotation>(rotation).turns, 0.5);
      expect(find.text('herramienta'), findsOneWidget);
      expect(find.text('completado'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.byType(SelectionArea), findsNothing);
      expect(find.byIcon(Icons.content_copy), findsNothing);
      final diagnostics = tester.allWidgets
          .map((widget) => widget.toStringDeep())
          .join('\n');
      final semanticsTree = tester
          .binding
          .rootPipelineOwner
          .semanticsOwner
          ?.rootSemanticsNode
          ?.toStringDeep();
      for (final sentinel in sentinels) {
        expectAbsentFromPublicProjection(tester, sentinel);
        expect(diagnostics, isNot(contains(sentinel)));
        expect(semanticsTree, isNot(contains(sentinel)));
      }
      expect(info.command, isNull);
      expect(info.description, isNull);
      expect(info.output, isNull);
      expect(info.exitCode, isNull);
      expect(info.runId, isNull);
      expect(info.patternKey, isNull);
    } finally {
      semantics.dispose();
    }
  }

  group('code blocks', () {
    testWidgets('comando Windows plano obtiene bloque y botón copiar', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const AssistantMarkdownView(data: 'Para listar:\ndir')),
      );
      expect(hasMonoText(tester, 'dir'), isTrue);
      expect(find.text('copiar'), findsOneWidget);
      final copyTarget = find
          .ancestor(
            of: find.text('copiar'),
            matching: find.byType(GestureDetector),
          )
          .first;
      expect(tester.getSize(copyTarget).height, greaterThanOrEqualTo(48));
    });

    testWidgets('el cuerpo del code block es monoespaciado', (tester) async {
      await tester.pumpWidget(
        host(
          const AssistantMarkdownView(
            data: '```bash\nsudo pacman -S android-tools\n```',
          ),
        ),
      );
      expect(hasMonoText(tester, 'pacman'), isTrue);
    });

    testWidgets('```markdown con prosa NO se trata como código', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AssistantMarkdownView(
            data: '```markdown\nResumen del día\nTodo ha ido bien hoy.\n```',
          ),
        ),
      );
      // Sin cabecera de code block (no hay botón copiar) y la prosa es visible.
      expect(find.text('copiar'), findsNothing);
      expect(find.textContaining('Todo ha ido bien'), findsOneWidget);
    });

    testWidgets('```markdown con señales de código sigue siendo bloque', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AssistantMarkdownView(
            data: '```markdown\nexport KEY=abc; run --now && echo ok\n```',
          ),
        ),
      );
      // Tiene `;`/`=`/`&&` → se mantiene como código (cabecera + copiar).
      expect(find.text('copiar'), findsOneWidget);
    });
  });

  group('chat event cards', () {
    testWidgets('CommandPreviewCard muestra el comando en monoespaciado', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const CommandPreviewCard(
            command: 'curl -s http://127.0.0.1:9119/api',
          ),
        ),
      );
      expect(hasMonoText(tester, 'curl'), isTrue);
    });

    testWidgets('el resultado remoto no se expone al expandir', (tester) async {
      const sentinels = [
        'REMOTE_TOOL_NAME_7f91',
        'REMOTE_BEGIN_7f91',
        'REMOTE_PATH_config.yaml',
        'REMOTE_END_7f91',
      ];
      await expectFailClosedRender(tester, {
        'role': 'tool',
        'tool_name': sentinels[0],
        'content': jsonEncode({
          'exit_code': 0,
          'output': '${sentinels[1]} ${sentinels[2]} ${sentinels[3]}',
        }),
      }, sentinels);
    });

    final adversarialRenderCarriers = <(String, String, Object, List<String>)>[
      ('texto plano', 'tool', 'PRIVATE_RENDER_PLAIN', ['PRIVATE_RENDER_PLAIN']),
      (
        'JSON secreto path',
        'tool_result',
        jsonEncode({'output': 'sk-render-A91 /home/render/private.json'}),
        ['sk-render-A91', '/home/render/private.json'],
      ),
      (
        'Map opaco',
        'tool_use',
        {'output': 'mango-render-2049'},
        ['mango-render-2049'],
      ),
      (
        'JSON sufijo',
        'function',
        '{"output":"PRIVATE_JSON"}\nPRIVATE_SUFFIX',
        ['PRIVATE_JSON', 'PRIVATE_SUFFIX'],
      ),
      (
        'reasoning logs',
        'function_call',
        jsonEncode({'reasoning': 'PRIVATE_REASONING', 'logs': 'PRIVATE_LOGS'}),
        ['PRIVATE_REASONING', 'PRIVATE_LOGS'],
      ),
      (
        'Harmony ASCII',
        'tool_call',
        '<\x7Cchannel\x7C>analysis PRIVATE_HARMONY_ASCII',
        ['PRIVATE_HARMONY_ASCII'],
      ),
      (
        'Harmony fullwidth',
        'tool',
        '＜｜channel｜＞ PRIVATE_HARMONY_FULLWIDTH',
        ['PRIVATE_HARMONY_FULLWIDTH'],
      ),
      (
        'Harmony incompleto',
        'tool',
        '<|channel| PRIVATE_HARMONY_INCOMPLETE',
        ['PRIVATE_HARMONY_INCOMPLETE'],
      ),
      (
        'Harmony fragmentado',
        'tool',
        {
          'chunks': ['<|chan', 'nel|>', 'PRIVATE_FRAGMENT'],
        },
        ['PRIVATE_FRAGMENT'],
      ),
      (
        'delegate_task anidado',
        'tool',
        {
          'goal': 'PRIVATE_GOAL',
          'context': 'PRIVATE_CONTEXT',
          'result': {'id': 'PRIVATE_RESULT_ID'},
        },
        ['PRIVATE_GOAL', 'PRIVATE_CONTEXT', 'PRIVATE_RESULT_ID'],
      ),
      (
        'safe public largo',
        'tool',
        'PRIVATE_LONG_BEGIN${List.filled(4096, 'x').join()}PRIVATE_LONG_END',
        ['PRIVATE_LONG_BEGIN', 'PRIVATE_LONG_END'],
      ),
    ];
    for (final (name, role, content, payloadSentinels)
        in adversarialRenderCarriers) {
      testWidgets('render tool fail-closed: $name', (tester) async {
        final metadata = 'PRIVATE_META_${name.toUpperCase()}';
        await expectFailClosedRender(
          tester,
          {
            'role': role,
            'content': content,
            'command': '${metadata}_COMMAND',
            'description': '${metadata}_DESCRIPTION',
            'arguments': {'reasoning': '${metadata}_ARGUMENT'},
            'exit_code': 0,
            'run_id': '${metadata}_RUN',
            'pattern_key': '${metadata}_PATTERN',
            'safe': true,
            'public': true,
          },
          [metadata, ...payloadSentinels],
        );
      });
    }
  });
}
