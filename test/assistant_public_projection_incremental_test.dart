import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/utils/assistant_content.dart';

/// Pieces chosen to hit every branch of the Harmony/think projection:
/// complete and split delimiters (ASCII and fullwidth bars), classic think
/// tags, case variants, length-changing lowercase (`İ`), the Kelvin sign that
/// lowercases to ASCII `k`, surrogate pairs and every whitespace class that
/// `String.trim` removes.
const _pieces = <String>[
  'a', 'Hola', ' ', '  ', '\n', '\t', '\u00a0', '\ufeff', '\u2028', //
  '<', '>', '|', '｜', '/', '<|', '<｜', '|>', '｜>', '</', //
  'start', 'channel', 'message', 'end', 'think', 'thinking', 'final',
  'analysis', 'commentary', 'THINK', 'Think', //
  '<think>', '</think>', '<thinking>', '</thinking>', '<THINK>',
  '<|channel|>', '<|message|>', '<|start|>', '<|end|>', '<｜think｜>',
  '<|/think|>', '<|channel|>final<|message|>', '<|channel|>analysis<|message|>',
  'İ', '\u212a', 'Σ', '😀', 'List<int>', '<div>', 'a < b', '```', '#',
  // Tag fragments that only join after an envelope is hidden.
  '<thi', '<th', 'in', 'n', 'k>', 'nk>', '<|think|>s<|/think|>',
];

String _randomChunk(Random random) {
  final count = 1 + random.nextInt(4);
  return List.generate(
    count,
    (_) => _pieces[random.nextInt(_pieces.length)],
  ).join();
}

/// Reference: the previous `_enqueueToken` contract, re-projecting the whole
/// raw answer for every delta.
final class _ReferenceStream {
  final StringBuffer raw = StringBuffer();
  String published = '';

  String? append(String token) {
    raw.write(token);
    final projected = streamingPublicAssistantText(raw.toString());
    if (!projected.startsWith(published)) return null;
    final delta = projected.substring(published.length);
    published = projected;
    return delta;
  }
}

void main() {
  group('projectPublicAssistantText fast path', () {
    test('text without < projects to itself with identity offsets', () {
      final random = Random(7);
      for (var round = 0; round < 400; round++) {
        final raw = List.generate(
          random.nextInt(12),
          (_) => _randomChunk(random),
        ).join().replaceAll('<', '');
        for (final streaming in [true, false]) {
          final projection = projectPublicAssistantText(
            raw,
            streaming: streaming,
          );
          expect(projection.text, raw);
          for (var offset = -1; offset <= raw.length + 2; offset++) {
            expect(
              projection.publicOffsetAtRawOffset(offset),
              offset.clamp(0, raw.length),
            );
          }
        }
      }
    });
  });

  group('StreamingPublicAssistantText', () {
    test('matches whole-answer re-projection after every delta', () {
      var cuts = 0;
      var withheld = 0;
      for (var seed = 0; seed < 1200; seed++) {
        final random = Random(seed);
        final reference = _ReferenceStream();
        final incremental = StreamingPublicAssistantText();
        final steps = 1 + random.nextInt(90);
        // Delimiter density varies per answer: from prose with rare markup
        // to answers made almost only of envelopes and tags.
        final markupOdds = 1 + seed % 6;
        var committed = 0;
        for (var step = 0; step < steps; step++) {
          final token = random.nextInt(markupOdds) == 0
              ? _randomChunk(random)
              : List.generate(
                  1 + random.nextInt(6),
                  (_) => const [
                    'pal',
                    'abra',
                    ' ',
                    '\n',
                    'x',
                    '😀',
                    'ñ',
                    '  ',
                  ][random.nextInt(8)],
                ).join();
          final expected = reference.append(token);
          final actual = incremental.append(token);
          expect(actual, expected, reason: 'seed=$seed step=$step');
          expect(incremental.publicText, reference.published);
          expect(incremental.rawText, reference.raw.toString());
          expect(incremental.rawLength, reference.raw.length);
          if (expected == null) withheld++;
          if (incremental.committedRawLength != committed) cuts++;
          committed = incremental.committedRawLength;
        }
      }
      // The proof only means something if cuts were exercised. A withheld
      // (non prefix-stable) delta was not reachable in a 200k-sequence
      // search; it is compared whenever it happens.
      expect(cuts, greaterThan(2000));
      expect(withheld, greaterThanOrEqualTo(0));
    });

    test('every delimiter split at every offset matches the reference', () {
      const delimiters = [
        '<|channel|>',
        '<｜channel｜>',
        '<|message|>',
        '<|start|>',
        '<|end|>',
        '<|think|>',
        '<|/think|>',
        '<think>',
        '</think>',
        '<thinking>',
        '</thinking>',
        '<THINKING>',
      ];
      const continuations = [
        'final<|message|>público',
        'analysis<|message|>privado',
        'oculto',
        ' tras',
        '<|end|>fin',
        '</think>fin',
        '',
      ];
      const preludes = [
        'Texto público de prosa suficientemente largo. ',
        'Texto<|channel|>final<|message|>público y más prosa larga ',
        'Prosa con <think>nota</think> y luego bastante texto aquí ',
        '   ',
      ];
      for (final prelude in preludes) {
        for (final opener in [...delimiters, '']) {
          for (final delimiter in delimiters) {
            for (final continuation in continuations) {
              final whole = '$prelude$opener x $delimiter$continuation tail';
              final splitBase = prelude.length + opener.length + 3;
              for (var cut = 0; cut <= delimiter.length; cut++) {
                final head = whole.substring(splitBase, splitBase + cut);
                final rest = whole.substring(splitBase + cut);
                // The delimiter prefix arrives alone, or glued after public
                // text so the projection can settle in front of it.
                for (final splits in [
                  [prelude, '$opener x ', head, rest],
                  [prelude, '$opener x $head', rest],
                ]) {
                  final reference = _ReferenceStream();
                  final incremental = StreamingPublicAssistantText();
                  for (final token in splits) {
                    expect(
                      incremental.append(token),
                      reference.append(token),
                      reason: splits.map(jsonEncode).join(' + '),
                    );
                    expect(incremental.publicText, reference.published);
                  }
                }
              }
            }
          }
        }
      }
    });

    test('a think tag joined across a hidden envelope is never cut', () {
      // The raw tail `|/think|>n` holds no `<`, but hiding the envelope
      // turns `<thi` + `n` into a held `<thin` in the classic pass input.
      for (final splits in [
        ['Texto <thi<|think|>s<|/think|>n', 'k>oculto</think>fin'],
        ['Texto <thi<|think|>s<|/think|>n', 'k', '>oculto</think>fin'],
        ['Texto <th<|think|>s<|/think|>in', 'k>oculto</think> fin'],
      ]) {
        final reference = _ReferenceStream();
        final incremental = StreamingPublicAssistantText();
        for (final token in splits) {
          expect(incremental.append(token), reference.append(token));
          expect(incremental.publicText, reference.published);
        }
        expect(incremental.publicText, isNot(contains('oculto')));
      }
    });

    test('clear starts a fresh answer', () {
      final stream = StreamingPublicAssistantText()..append('  primero ');
      stream.clear();
      expect(stream.publicText, '');
      expect(stream.rawText, '');
      expect(stream.append('  segundo'), 'segundo');
    });

    test('markup-bearing deltas never re-read the whole answer', () {
      String run(String Function(String) feed, int chars) {
        final answer = StringBuffer();
        var i = 0;
        while (answer.length < chars) {
          answer.write(switch (i++ % 4) {
            0 => 'Palabra $i del párrafo.\n',
            1 => 'Si a < b entonces `List<int>` vale.\n',
            2 => '<div>bloque $i</div> y <think>nota</think> visible.\n',
            _ => '```dart\nfinal v = <String>[];\n```\n',
          });
        }
        final text = answer.toString();
        final out = StringBuffer();
        for (var offset = 0; offset < text.length; offset += 4) {
          out.write(feed(text.substring(offset, min(offset + 4, text.length))));
        }
        return out.toString();
      }

      int workFor(int chars) {
        final stream = StreamingPublicAssistantText();
        debugAssistantProjectionInputChars = 0;
        final published = run((token) => stream.append(token) ?? '', chars);
        expect(published, isNotEmpty);
        return debugAssistantProjectionInputChars;
      }

      // Linear: x4 answer costs ~x4 projection work, not x16, and stays
      // within a small constant of the answer length.
      final small = workFor(16000);
      final big = workFor(64000);
      expect(big, lessThanOrEqualTo(64000 * 8));
      expect(big / small, lessThan(5), reason: 'small=$small big=$big');
    });
  });

  group('codex_message_items', () {
    test('a Responses API row decodes its sidecar once per projection', () {
      final row = <String, dynamic>{
        'role': 'assistant',
        'content': '',
        'codex_message_items': jsonEncode([
          {
            'type': 'message',
            'role': 'assistant',
            'phase': 'commentary',
            'content': [
              {'type': 'output_text', 'text': 'Comentario'},
            ],
          },
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': 'Respuesta'},
            ],
          },
        ]),
      };
      debugCodexMessageItemDecodes = 0;
      final normalized = normalizeTranscriptMessageForDisplay(
        row,
        retainProjectionState: true,
      );
      expect(normalized?['content'], 'Respuesta');
      expect(normalized?['reasoning'], 'Comentario');
      expect(debugCodexMessageItemDecodes, 1);
    });

    test('decoded and raw sidecars project identically', () {
      final random = Random(3);
      for (var round = 0; round < 200; round++) {
        final items = [
          for (var i = 0; i < random.nextInt(4); i++)
            {
              'type': random.nextBool() ? 'message' : 'reasoning',
              'role': random.nextBool() ? 'assistant' : 'user',
              if (random.nextBool())
                'phase': const [
                  'commentary',
                  'analysis',
                  'final',
                ][random.nextInt(3)],
              'content': [
                {
                  'type': const [
                    'output_text',
                    'text',
                    'image',
                  ][random.nextInt(3)],
                  'text': _randomChunk(random),
                },
              ],
            },
        ];
        final encoded = random.nextInt(5) == 0
            ? '{not json'
            : jsonEncode(random.nextInt(6) == 0 ? {'x': items} : items);
        final structured = random.nextBool() ? 'Razón $round' : null;
        final message = <String, dynamic>{
          'role': 'assistant',
          'content': random.nextBool() ? '' : 'Visible $round',
          'codex_message_items': encoded,
          'reasoning': ?structured,
        };
        final decoded = <String, dynamic>{
          ...message,
          'codex_message_items': () {
            try {
              return jsonDecode(encoded);
            } on FormatException {
              return null;
            }
          }(),
        };
        expect(
          normalizeTranscriptMessageForDisplay(
            message,
            retainProjectionState: true,
          ),
          normalizeTranscriptMessageForDisplay(
            decoded,
            retainProjectionState: true,
          ),
        );
      }
    });
  });
}
