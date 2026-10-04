import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_protocol.dart';

Map<String, dynamic> _msg(String role, String content, {Object? extra}) => {
  'role': role,
  'content': content,
  if (extra != null) ...(extra as Map<String, dynamic>),
};

VoiceLiveFragment _frag(
  VoiceLiveSpeaker speaker,
  String text, {
  int start = 0,
  int end = 0,
}) =>
    VoiceLiveFragment(speaker: speaker, text: text, startMs: start, endMs: end);

void main() {
  group('toLiveHistory', () {
    test('maps roles and content types, oldest first', () {
      final history = toLiveHistory([
        _msg('user', 'hola'),
        _msg('assistant', 'dime'),
      ]);
      expect(history, [
        {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'hola'},
          ],
        },
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'dime'},
          ],
        },
      ]);
    });

    test('keeps only user/assistant, non-hidden, non-empty turns', () {
      final history = toLiveHistory([
        _msg('system', 'sistema'),
        _msg('tool', 'salida'),
        _msg('user', 'oculto', extra: {'_pipeline': true}),
        _msg('user', 'sintético', extra: {'display_kind': 'goal'}),
        _msg('assistant', '   \n  '),
        _msg('user', 'visible'),
      ]);
      expect(history.map((m) => (m['content'] as List).single['text']), [
        'visible',
      ]);
    });

    test('collapses whitespace', () {
      final history = toLiveHistory([_msg('user', '  a \n\n b\t c  ')]);
      expect((history.single['content'] as List).single['text'], 'a b c');
    });

    test('caps each message at 1200 characters', () {
      final history = toLiveHistory([_msg('user', 'x' * 5000)]);
      expect(
        ((history.single['content'] as List).single['text'] as String).length,
        1200,
      );
    });

    test('keeps the newest 24 messages', () {
      final messages = [for (var i = 0; i < 40; i++) _msg('user', 'm$i')];
      final history = toLiveHistory(messages);
      expect(history, hasLength(24));
      expect((history.first['content'] as List).single['text'], 'm16');
      expect((history.last['content'] as List).single['text'], 'm39');
    });

    test('caps the total at 6000 characters, dropping the oldest', () {
      final messages = [
        for (var i = 0; i < 10; i++) _msg('user', '${i}x' * 600),
      ];
      final history = toLiveHistory(messages);
      final total = history
          .map((m) => ((m['content'] as List).single['text'] as String).length)
          .fold<int>(0, (a, b) => a + b);
      expect(total, lessThanOrEqualTo(6000));
      expect((history.last['content'] as List).single['text'], '9x' * 600);
      expect(history.length, lessThan(10));
    });

    test('empty input yields an empty list', () {
      expect(toLiveHistory(const []), isEmpty);
    });
  });

  group('chunkForCommentary', () {
    test('short text is one collapsed chunk', () {
      expect(chunkForCommentary('  Hola   mundo. \n Adiós. '), [
        'Hola mundo. Adiós.',
      ]);
    });

    test('empty text yields no chunks', () {
      expect(chunkForCommentary('  \n '), isEmpty);
    });

    test('splits on sentence boundaries without exceeding 1400', () {
      final sentence = '${'a' * 700}.';
      final chunks = chunkForCommentary('$sentence $sentence $sentence');
      expect(chunks, ['$sentence', '$sentence', '$sentence']);
      expect(chunks.every((c) => c.length <= 1400), isTrue);
    });

    test('packs consecutive sentences up to the cap', () {
      final sentence = '${'b' * 300}.';
      final chunks = chunkForCommentary(List.filled(6, sentence).join(' '));
      expect(chunks.length, 2);
      expect(chunks.every((c) => c.length <= 1400), isTrue);
      expect(chunks.join(' '), List.filled(6, sentence).join(' '));
    });

    test('hard-splits a single sentence longer than the cap', () {
      final chunks = chunkForCommentary('c' * 3000);
      expect(chunks.map((c) => c.length), [1400, 1400, 200]);
    });
  });

  group('delegationPrompt', () {
    test('merges consecutive fragments by speaker and uses the last user', () {
      final result = delegationPrompt([
        _frag(VoiceLiveSpeaker.user, 'abre el '),
        _frag(VoiceLiveSpeaker.user, 'calendario'),
        _frag(VoiceLiveSpeaker.assistant, 'Claro, '),
        _frag(VoiceLiveSpeaker.assistant, 'un momento'),
        _frag(VoiceLiveSpeaker.user, ' y  dime  lo de mañana'),
      ]);
      expect(result.prompt, 'y dime lo de mañana');
      expect(
        result.voiceContext,
        'User: abre el calendario\n'
        'Voice assistant: Claro, un momento\n'
        'User: y dime lo de mañana',
      );
    });

    test('drops empty lines from the context', () {
      final result = delegationPrompt([
        _frag(VoiceLiveSpeaker.assistant, '   '),
        _frag(VoiceLiveSpeaker.user, 'hola'),
      ]);
      expect(result.voiceContext, 'User: hola');
    });

    test('falls back to the context tail when there is no user text', () {
      final result = delegationPrompt([
        _frag(VoiceLiveSpeaker.assistant, 'z' * 900),
      ]);
      expect(result.prompt.length, 400);
      expect(result.prompt, result.voiceContext.substring(900 + 17 - 400));
    });

    test('empty context gives an empty prompt', () {
      final result = delegationPrompt(const []);
      expect(result.prompt, isEmpty);
      expect(result.voiceContext, isEmpty);
    });
  });

  group('parseVoiceLiveStatus', () {
    test('null on !ok, non-map and missing ok', () {
      expect(parseVoiceLiveStatus({'ok': false, 'available': true}), isNull);
      expect(parseVoiceLiveStatus({'available': true}), isNull);
      expect(parseVoiceLiveStatus('nope'), isNull);
      expect(parseVoiceLiveStatus(null), isNull);
    });

    test('mode is gpt-live only on an exact match', () {
      Map<String, dynamic> body(Object? mode) => {
        'ok': true,
        'mode': mode,
        'available': true,
      };
      expect(
        parseVoiceLiveStatus(body('gpt-live'))!.mode,
        VoiceLiveMode.gptLive,
      );
      expect(
        parseVoiceLiveStatus(body('GPT-Live'))!.mode,
        VoiceLiveMode.chained,
      );
      expect(
        parseVoiceLiveStatus(body('gpt-live '))!.mode,
        VoiceLiveMode.chained,
      );
      expect(
        parseVoiceLiveStatus(body('chained'))!.mode,
        VoiceLiveMode.chained,
      );
      expect(parseVoiceLiveStatus(body(null))!.mode, VoiceLiveMode.chained);
    });

    test('available is coerced to bool and null fields are absent', () {
      final status = parseVoiceLiveStatus({
        'ok': true,
        'mode': 'chained',
        'available': null,
        'reason': null,
        'model': null,
        'voice': null,
      })!;
      expect(status.available, isFalse);
      expect(status.reason, isNull);
      expect(status.model, isNull);
      expect(status.voice, isNull);
    });

    test('carries reason, model and voice', () {
      final status = parseVoiceLiveStatus({
        'ok': true,
        'mode': 'gpt-live',
        'available': false,
        'reason': 'no OpenAI API key',
        'model': 'gpt-live-1',
        'voice': 'marin',
      })!;
      expect(status.available, isFalse);
      expect(status.reason, 'no OpenAI API key');
      expect(status.model, 'gpt-live-1');
      expect(status.voice, 'marin');
    });
  });
}
