import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/assistant_content.dart';

void main() {
  group('splitReasoning', () {
    test('sin etiquetas devuelve la respuesta intacta (cero cambios)', () {
      const input = 'Hola, esta es una respuesta normal con `código`.';
      final r = splitReasoning(input);
      expect(r.reasoning, isEmpty);
      expect(r.answer, input);
      expect(r.reasoningInProgress, isFalse);
      expect(r.hasReasoning, isFalse);
    });

    test('extrae un bloque <think> cerrado y deja la respuesta limpia', () {
      const input =
          '<think>El usuario quiere X. Debo responder Y.</think>La respuesta es Y.';
      final r = splitReasoning(input);
      expect(r.reasoning, 'El usuario quiere X. Debo responder Y.');
      expect(r.answer, 'La respuesta es Y.');
      expect(r.reasoningInProgress, isFalse);
      expect(r.hasReasoning, isTrue);
    });

    test('soporta la variante <thinking>', () {
      const input = '<thinking>razono</thinking>respuesta';
      final r = splitReasoning(input);
      expect(r.reasoning, 'razono');
      expect(r.answer, 'respuesta');
    });

    test('es insensible a mayúsculas en las etiquetas', () {
      const input = '<THINK>razono</THINK>respuesta';
      final r = splitReasoning(input);
      expect(r.reasoning, 'razono');
      expect(r.answer, 'respuesta');
    });

    test('concatena varios bloques de razonamiento', () {
      const input = '<think>uno</think>texto<think>dos</think> final';
      final r = splitReasoning(input);
      expect(r.reasoning, 'uno\n\ndos');
      expect(r.answer, 'texto final');
    });

    test('apertura sin cierre (streaming) → razonamiento en curso', () {
      const input = '<think>aún estoy pensando en la respuesta';
      final r = splitReasoning(input);
      expect(r.reasoning, 'aún estoy pensando en la respuesta');
      expect(r.answer, isEmpty);
      expect(r.reasoningInProgress, isTrue);
      expect(r.hasReasoning, isTrue);
    });

    test('respuesta antes de un <think> abierto se conserva', () {
      const input = 'Avance parcial.<think>sigo pensando';
      final r = splitReasoning(input);
      expect(r.answer, 'Avance parcial.');
      expect(r.reasoning, 'sigo pensando');
      expect(r.reasoningInProgress, isTrue);
    });

    test('bloque vacío no produce razonamiento pero limpia la etiqueta', () {
      const input = '<think></think>solo respuesta';
      final r = splitReasoning(input);
      expect(r.reasoning, isEmpty);
      expect(r.answer, 'solo respuesta');
      expect(r.hasReasoning, isFalse);
    });

    test('cierre huérfano sin apertura no se muestra en la respuesta', () {
      const input = 'respuesta</think> visible';
      final r = splitReasoning(input);
      expect(r.answer.contains('</think>'), isFalse);
      expect(r.answer, 'respuesta visible');
    });

    test('no confunde texto que solo menciona "think" sin etiqueta', () {
      const input = 'Deberías pensar (think) antes de actuar.';
      final r = splitReasoning(input);
      expect(r.reasoning, isEmpty);
      expect(r.answer, input);
    });
  });

  group('tidyAssistantMarkdown', () {
    test('inserta el espacio que falta tras los # de un encabezado', () {
      expect(tidyAssistantMarkdown('##Resumen'), '## Resumen');
      expect(tidyAssistantMarkdown('#Título'), '# Título');
      expect(tidyAssistantMarkdown('###Sección final'), '### Sección final');
    });

    test('no toca encabezados ya correctos', () {
      const ok = '## Ya correcto';
      expect(tidyAssistantMarkdown(ok), ok);
    });

    test('no toca # a mitad de línea ni hashtags numéricos al inicio', () {
      expect(tidyAssistantMarkdown('issue #42 abierto'), 'issue #42 abierto');
      expect(tidyAssistantMarkdown('#1 de la lista'), '#1 de la lista');
    });

    test('no toca # dentro de bloques de código', () {
      const code = '```bash\n#!/bin/bash\n#comentario\n```';
      expect(tidyAssistantMarkdown(code), code);
    });

    test('respeta más de 6 # (no es encabezado ATX)', () {
      expect(tidyAssistantMarkdown('#######Siete'), '#######Siete');
    });

    test('texto sin # se devuelve intacto', () {
      const t = 'Una respuesta sin encabezados.';
      expect(tidyAssistantMarkdown(t), t);
    });

    test('corrige encabezados pegados en un documento multilínea', () {
      const input = 'Intro.\n\n##Pasos\n\n- uno\n- dos';
      const expected = 'Intro.\n\n## Pasos\n\n- uno\n- dos';
      expect(tidyAssistantMarkdown(input), expected);
    });

    test('separa una línea de código inline del encabezado anterior', () {
      const input =
          '**2) Ruta y estructura real del storagebox**\n'
          '`/home/backups`\n'
          'Con SFTP listé:';
      const expected =
          '**2) Ruta y estructura real del storagebox**\n\n'
          '`/home/backups`\n\n'
          'Con SFTP listé:';
      expect(tidyAssistantMarkdown(input), expected);
    });

    test('separa código pegado a un encabezado numerado en negrita', () {
      const input =
          '**2) Ruta y estructura real del storagebox** `/home/backups`\n'
          'Con SFTP listé:';
      const expected =
          '**2) Ruta y estructura real del storagebox**\n\n'
          '`/home/backups`\n\n'
          'Con SFTP listé:';
      expect(tidyAssistantMarkdown(input), expected);
    });

    test('separa código pegado a un encabezado ATX', () {
      const input =
          '## 2) Ruta y estructura real del storagebox `/home/backups`\n'
          'Con SFTP listé:';
      const expected =
          '## 2) Ruta y estructura real del storagebox\n\n'
          '`/home/backups`\n\n'
          'Con SFTP listé:';
      expect(tidyAssistantMarkdown(input), expected);
    });

    test('no separa código inline que forma parte de una lista', () {
      const input = '- Ruta `~/backups` lista.';
      expect(tidyAssistantMarkdown(input), input);
    });

    test('presenta aproximaciones sin alterar rutas ni código', () {
      const input =
          'Ocupa ~955 GB, ≈ 889.1 GiB, ~0.4% del total y vive en '
          '`~/backups/~123`.';
      const expected =
          'Ocupa aprox. 955 GB, aprox. 889.1 GiB, aprox. 0.4% del total y vive en '
          '`~/backups/~123`.';
      expect(tidyAssistantMarkdown(input), expected);
    });

    test('no confunde el tachado con una aproximación', () {
      const input = 'Esto es ~~obsoleto~~ y aquello ronda ~ 12 GB.';
      const expected = 'Esto es ~~obsoleto~~ y aquello ronda aprox. 12 GB.';
      expect(tidyAssistantMarkdown(input), expected);
    });

    test('separa spans de código unidos por coma o punto y coma', () {
      const input = '`/home/backups/keys`,`locks`;`snapshots`';
      const expected = '`/home/backups/keys`, `locks`; `snapshots`';
      expect(tidyAssistantMarkdown(input), expected);
    });

    test('no altera aproximaciones dentro de bloques de código', () {
      const input = '```bash\nprintf "~123"\n```';
      expect(tidyAssistantMarkdown(input), input);
    });

    test('no altera bloques de código CommonMark con sangría', () {
      const spaces = 'Comando:\n\n    printf "~123"\n    echo "≈ 456"';
      const tab = 'Comando:\n\n\tprintf "~123"';
      expect(tidyAssistantMarkdown(spaces), spaces);
      expect(tidyAssistantMarkdown(tab), tab);
    });

    test('respeta código inline con delimitadores de varios backticks', () {
      const input =
          'Ronda ~12 GB; ejecuta ``printf "~123"`` y conserva `≈ 456`.';
      const expected =
          'Ronda aprox. 12 GB; ejecuta ``printf "~123"`` y conserva `≈ 456`.';
      expect(tidyAssistantMarkdown(input), expected);
    });

    test('un delimitador inline sin cerrar falla cerrado', () {
      const input = 'Ronda ~12 GB; comando abierto `printf "~123"';
      const expected = 'Ronda aprox. 12 GB; comando abierto `printf "~123"';
      expect(tidyAssistantMarkdown(input), expected);
    });
  });

  group('splitReasoning · delimitadores Harmony (gpt-oss)', () {
    test('el canal analysis es razonamiento y los tokens no se pintan', () {
      const input =
          '<|start|>assistant<|channel|>analysis<|message|>'
          'Debo comprobar los logs antes de responder.'
          '<|end|><|start|>assistant<|channel|>final<|message|>'
          'Los logs están limpios.<|end|>';
      final r = splitReasoning(input);
      expect(r.reasoning, 'Debo comprobar los logs antes de responder.');
      expect(r.answer, 'Los logs están limpios.');
      expect(r.answer.contains('<|'), isFalse);
      expect(r.reasoningInProgress, isFalse);
    });

    test('canal analysis abierto en streaming → razonamiento en curso', () {
      const input =
          '<|start|>assistant<|channel|>analysis<|message|>Aún analizo';
      final r = splitReasoning(input);
      expect(r.reasoning, 'Aún analizo');
      expect(r.answer, isEmpty);
      expect(r.reasoningInProgress, isTrue);
    });

    test('la variante <|think|> se trata como bloque de razonamiento', () {
      const input = '<|think|>razono<|/think|>respuesta';
      final r = splitReasoning(input);
      expect(r.reasoning, 'razono');
      expect(r.answer, 'respuesta');
    });

    test('tokens sueltos sin canal analysis se sanean a texto limpio', () {
      const input = '<|start|>assistant<|channel|>final<|message|>Hola.<|end|>';
      final r = splitReasoning(input);
      expect(r.reasoning, isEmpty);
      expect(r.answer, 'Hola.');
    });

    test('streaming retiene prefijos Harmony incompletos', () {
      expect(streamingPublicAssistantText('<|chan'), isEmpty);
      expect(
        streamingPublicAssistantText(
          '<|channel|>analysis<|message|>PRIVATE_HARMONY',
        ),
        isEmpty,
      );
    });

    test('texto sin delimitadores Harmony sigue intacto', () {
      const input = 'Respuesta normal <| sin tokens de control.';
      final r = splitReasoning(input);
      expect(r.reasoning, isEmpty);
      expect(r.answer, input);
    });

    test('parser secuencial acepta cada combinación de barras por token', () {
      const bars = ['|', '｜'];
      for (final left in bars) {
        for (final right in bars) {
          String token(String name) => '<$left$name$right>';
          final raw =
              '${token('channel')}analysis${token('message')}PRIVATE_MIXED'
              '${token('end')}${token('channel')}final${token('message')}'
              'PUBLIC ｜ tip${token('end')}';
          for (var boundary = 0; boundary <= raw.length; boundary++) {
            expect(
              streamingPublicAssistantText(raw.substring(0, boundary)),
              isNot(contains('PRIVATE_MIXED')),
              reason: '$left/$right boundary=$boundary',
            );
          }
          expect(streamingPublicAssistantText(raw), 'PUBLIC ｜ tip');
        }
      }
    });

    test('start y channel anidados cambian autoridad sin perder límites', () {
      const cases = <String, String>{
        '<｜start｜>assistant<｜channel｜>final<｜message｜>PUBLIC'
                '<｜start｜>assistant<｜channel｜>analysis<｜message｜>PRIVATE<｜end｜>':
            'PUBLIC',
        '<｜start｜>assistant<｜channel｜>analysis<｜message｜>PRIVATE'
                '<｜start｜>assistant<｜channel｜>final<｜message｜>PUBLIC<｜end｜>':
            'PUBLIC',
        '<｜channel｜>final<｜message｜>PUBLIC'
                '<｜channel｜>analysis<｜message｜>PRIVATE<｜end｜>':
            'PUBLIC',
        '<｜channel｜>analysis<｜message｜>PRIVATE'
                '<｜channel｜>final<｜message｜>PUBLIC<｜end｜>':
            'PUBLIC',
      };
      for (final entry in cases.entries) {
        for (var boundary = 0; boundary <= entry.key.length; boundary++) {
          expect(
            streamingPublicAssistantText(entry.key.substring(0, boundary)),
            isNot(contains('PRIVATE')),
            reason: 'boundary=$boundary',
          );
        }
        expect(streamingPublicAssistantText(entry.key), entry.value);
      }
    });

    test(
      'streaming retiene candidato pero finalizado libera literal inválido',
      () {
        const unterminated = 'PUBLIC <｜start｜>not an envelope';
        const terminated = 'PUBLIC <｜start｜>not an envelope<｜end｜>';
        expect(streamingPublicAssistantText(unterminated), 'PUBLIC');
        expect(finalizedPublicAssistantText(unterminated), unterminated);
        expect(finalizedPublicAssistantText(terminated), terminated);
        expect(
          finalizedPublicAssistantText(
            'PUBLIC<｜channel｜>analysis<｜message｜>PRIVATE_UNCLOSED',
          ),
          'PUBLIC',
        );
      },
    );

    test('commentary público conserva tips y bytes de prosa', () {
      const raw =
          '<|channel｜> CoMmEnTaRy <｜message|>Tip: usa PUBLIC ｜ literalmente.'
          '<｜end|>';
      expect(
        finalizedPublicAssistantText(raw),
        'Tip: usa PUBLIC ｜ literalmente.',
      );
    });
  });

  group('structuredReasoningText / mergeStructuredReasoning', () {
    test('extrae reasoning_content estilo DeepSeek-reasoner', () {
      expect(
        structuredReasoningText(const {'reasoning_content': 'paso a paso'}),
        'paso a paso',
      );
    });

    test('usa precedencia Desktop y solo reasoning_details string', () {
      expect(
        structuredReasoningText(const {
          'reasoning': 'resumen',
          'reasoning_content': 'fallback',
          'reasoning_details': 'otro fallback',
        }),
        'resumen',
      );
      expect(
        structuredReasoningText(const {
          'reasoning_details': [
            {'type': 'reasoning.text', 'text': 'privado'},
          ],
        }),
        isEmpty,
      );
      expect(
        structuredReasoningText(const {
          'reasoning_details': 'detalle durable',
        }),
        'detalle durable',
      );
    });

    test('sin campos de razonamiento devuelve vacío', () {
      expect(structuredReasoningText(const {'role': 'assistant'}), isEmpty);
      expect(
        structuredReasoningText(const {'reasoning_content': '  '}),
        isEmpty,
      );
    });

    test('sin razonamiento estructurado conserva el split intacto', () {
      const base = ReasoningSplit(reasoning: 'inline', answer: 'respuesta');
      expect(mergeStructuredReasoning(base, const {}), same(base));
    });

    test('compone estructurado + inline sin perder ninguno', () {
      const base = ReasoningSplit(reasoning: 'inline', answer: 'respuesta');
      final merged = mergeStructuredReasoning(base, const {
        'reasoning_content': 'estructurado',
      });
      expect(merged.reasoning, 'estructurado\n\ninline');
      expect(merged.answer, 'respuesta');
    });

    test('content vacío con razonamiento estructurado sigue visible', () {
      const base = ReasoningSplit(reasoning: '', answer: '');
      final merged = mergeStructuredReasoning(base, const {
        'reasoning_content': 'pensé esto',
      });
      expect(merged.hasReasoning, isTrue);
      expect(merged.reasoning, 'pensé esto');
      expect(merged.answer, isEmpty);
    });
  });

  group('flattenInlineHtml', () {
    test('<br> se convierte en salto de línea', () {
      expect(
        flattenInlineHtml('línea uno<br>línea dos'),
        'línea uno\nlínea dos',
      );
      expect(flattenInlineHtml('a<br />b'), 'a\nb');
    });

    test('<details> se desenvuelve conservando su contenido', () {
      const input =
          '<details>\n<summary>Ver más</summary>\nDetalle oculto.\n</details>';
      final out = flattenInlineHtml(input);
      expect(out.contains('<details>'), isFalse);
      expect(out.contains('<summary>'), isFalse);
      expect(out.contains('Ver más'), isTrue);
      expect(out.contains('Detalle oculto.'), isTrue);
    });

    test('no toca tags dentro de código inline ni vallas', () {
      const inline = 'usa `<br>` en HTML';
      expect(flattenInlineHtml(inline), inline);
      const fence = '```html\n<p>x</p>\n```';
      expect(flattenInlineHtml(fence), fence);
    });

    test('texto sin < se devuelve intacto', () {
      const t = 'Respuesta normal sin HTML.';
      expect(flattenInlineHtml(t), t);
    });
  });
}
