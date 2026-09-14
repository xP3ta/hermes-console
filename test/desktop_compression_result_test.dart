import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_compression_result.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';

Map<String, dynamic> _validResult() => {
  'status': 'compressed',
  'removed': 4,
  'before_messages': 6,
  'after_messages': 2,
  'before_tokens': 179492,
  'after_tokens': 4821,
  'summary': {
    'noop': false,
    'headline': 'Compressed: 6 → 2 messages',
    'token_line': 'Approx request size: ~179,492 → ~4,821 tokens',
  },
  'usage': {
    'calls': 12,
    'total': 201000,
    'context_used': 4821,
    'context_max': 200000,
  },
  'info': {
    'stored_session_id': '20260722_094311_continuation',
    'model': 'openai/gpt-5.5-codex',
    'usage': {'context_used': 4821, 'context_max': 200000},
  },
  'messages': [
    {'role': 'user', 'content': 'Resumen de la conversación anterior'},
    {'role': 'assistant', 'content': 'Contexto conservado'},
  ],
};

void main() {
  test('parsea transcript, métricas y continuación durable de Hermes 0.19', () {
    final result = DesktopCompressionResult.fromJson(_validResult());

    expect(result.status, 'compressed');
    expect(result.removed, 4);
    expect(result.beforeMessages, 6);
    expect(result.afterMessages, 2);
    expect(result.beforeTokens, 179492);
    expect(result.afterTokens, 4821);
    expect(result.summary?.noop, isFalse);
    expect(result.usage?.contextUsed, 4821);
    expect(result.info?.storedSessionId, '20260722_094311_continuation');
    expect(result.messages, hasLength(2));
    expect(result.messages!.first.role, DesktopSessionMessageRole.user);
    expect(result.messages!.last.text, 'Contexto conservado');
  });

  test('acepta un terminal aborted con su transcript autoritativo', () {
    final aborted = _validResult()
      ..['status'] = 'aborted'
      ..['summary'] = {
        'aborted': true,
        'headline': 'Compression aborted: 6 messages preserved',
      };

    final result = DesktopCompressionResult.fromJson(aborted);

    expect(result.status, 'aborted');
    expect(result.isSuccess, isFalse);
    expect(result.messages, hasLength(2));
    expect(result.info?.storedSessionId, '20260722_094311_continuation');
  });

  test('compressed noop is a successful neutral terminal, never aborted', () {
    final result = DesktopCompressionResult.fromJson({
      'status': 'compressed',
      'removed': 0,
      'summary': {'noop': true, 'aborted': false},
    });

    expect(result.outcome, DesktopCompressionStatus.noOp);
    expect(result.status, 'compressed');
    expect(result.isSuccess, isTrue);
    expect(result.isTerminal, isTrue);
    expect(result.isAuthoritativeNoProgress, isTrue);
  });

  test('acepta el terminal parcial exacto de compute host', () {
    final result = DesktopCompressionResult.fromJson({
      'status': 'compressed',
      'turn_isolation': true,
      'removed': 12,
      'summary': {'headline': 'Compressed 14 → 2'},
    });

    expect(result.outcome, DesktopCompressionStatus.compressed);
    expect(result.summary?.noop, isNull);
    expect(result.summary?.headline, 'Compressed 14 → 2');
    expect(result.messages, isNull);
  });

  test('acepta pending sin inventar transcript, summary ni identidad', () {
    final result = DesktopCompressionResult.fromJson({
      'status': 'pending',
      'turn_isolation': true,
      'message': 'compression still running in the background',
    });

    expect(result.outcome, DesktopCompressionStatus.pending);
    expect(result.isSuccess, isFalse);
    expect(result.isTerminal, isFalse);
    expect(result.turnIsolation, isTrue);
    expect(result.messages, isNull);
    expect(result.summary, isNull);
    expect(result.info, isNull);
  });

  test('acepta lock_held sin status ni transcript', () {
    final result = DesktopCompressionResult.fromJson({
      'compressed': false,
      'lock_held': true,
      'message': 'holder details must not reach the UI',
    });

    expect(result.outcome, DesktopCompressionStatus.lockHeld);
    expect(result.status, isNull);
    expect(result.isSuccess, isFalse);
    expect(result.messages, isNull);
    expect(result.summary, isNull);
    expect(result.info, isNull);
  });

  test('acepta terminal parcial aislado del compute host', () {
    final result = DesktopCompressionResult.fromJson({
      'status': 'compressed',
      'turn_isolation': true,
      'host_ack': {'type': 'control.ack'},
      'info': {'stored_session_id': 'tip-after-compression'},
      'messages': [
        {'role': 'user', 'content': 'summary'},
      ],
    });

    expect(result.outcome, DesktopCompressionStatus.compressed);
    expect(result.isSuccess, isTrue);
    expect(result.messages, hasLength(1));
    expect(result.info?.storedSessionId, 'tip-after-compression');
    expect(result.afterMessages, isNull);
  });

  test(
    'REGRESSION_COMP_UNCERTAIN requires equal root aliases in terminal authority',
    () {
      final equal = _validResult()
        ..['info'] = {
          '_lineage_root_id': 'root-A',
          'lineage_root_id': 'root-A',
        };
      expect(DesktopCompressionResult.fromJson(equal).info, isNotNull);

      final contradictory = _validResult()
        ..['info'] = {
          '_lineage_root_id': 'root-A',
          'lineage_root_id': 'root-B',
        };
      expect(
        () => DesktopCompressionResult.fromJson(contradictory),
        throwsFormatException,
      );
    },
  );

  test('rechaza respuestas parciales o transcripts inconsistentes', () {
    final invalidSummary = _validResult()..['summary'] = {'noop': 'false'};
    expect(
      () => DesktopCompressionResult.fromJson(invalidSummary),
      throwsFormatException,
    );

    final invalidMessage = _validResult()
      ..['messages'] = [
        {'content': 'sin role'},
        {'role': 'assistant', 'content': 'respuesta'},
      ];
    expect(
      () => DesktopCompressionResult.fromJson(invalidMessage),
      throwsFormatException,
    );

    final invalidCount = _validResult()..['after_messages'] = 3;
    expect(
      () => DesktopCompressionResult.fromJson(invalidCount),
      throwsFormatException,
    );
  });

  test('rechaza variantes casi válidas, coerciones y campos incompatibles', () {
    final cases = <Map<String, dynamic>>[
      // Missing and whitespace-normalized tags are not union tags.
      {'turn_isolation': true, 'message': 'still running'},
      {
        'status': ' pending ',
        'turn_isolation': true,
        'message': 'still running',
      },
      {'status': 'unknown', 'turn_isolation': true, 'message': 'still running'},
      // Pending and lock-held cannot carry terminal authority.
      {
        'status': 'pending',
        'turn_isolation': true,
        'message': 'still running',
        'messages': <Object>[],
      },
      {'compressed': false, 'lock_held': true, 'status': 'lock_held'},
      {'compressed': false, 'lock_held': true},
      {
        'compressed': false,
        'lock_held': true,
        'info': {'stored_session_id': 'other-session'},
      },
      // Counts are ints, never bools or loosely equivalent numbers.
      _validResult()..['removed'] = true,
      _validResult()..['after_messages'] = 2.0,
      // Returned identities are opaque byte-exact values, not trimmed aliases.
      _validResult()..['info'] = {'stored_session_id': ' tip-with-whitespace '},
      _validResult()..['info'] = {'_lineage_root_id': ' root-with-whitespace '},
      _validResult()..['usage'] = {'compressions': true},
      // A compressed result cannot claim an aborted summary.
      _validResult()..['summary'] = {'noop': true, 'aborted': true},
      // Aborted has to carry its explicit abort marker.
      _validResult()..['status'] = 'aborted',
    ];

    for (final response in cases) {
      expect(
        () => DesktopCompressionResult.fromJson(response),
        throwsFormatException,
      );
    }
  });
}
