import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/json_rpc_wire.dart';
import 'package:hermes_android/core/services/replay_batch_proof.dart';

SessionGatewayEvent held(int seq, {String text = 'x'}) =>
    SessionGatewayEvent('message.delta', 'runtime-a', seq, {'text': text});

Map<String, dynamic> row(
  int seq, {
  String session = 'runtime-a',
  String text = 'x',
}) => {
  'type': 'message.delta',
  'session_id': session,
  'seq': seq,
  'payload': {'text': text},
};

void main() {
  group('SafeJsonInt', () {
    for (final value in <Object?>[
      true,
      false,
      null,
      '1',
      1.0,
      1.5,
      9007199254740992,
      -9007199254740992,
    ]) {
      test('rejects ${value.runtimeType} $value', () {
        expect(() => SafeJsonInt.require(value), throwsFormatException);
      });
    }
    test('accepts exact interoperable boundaries', () {
      expect(SafeJsonInt.require(-maxSafeJsonInteger), -maxSafeJsonInteger);
      expect(SafeJsonInt.require(maxSafeJsonInteger), maxSafeJsonInteger);
    });
  });

  group('duplicate-aware decoder', () {
    for (final entry in <String, String>{
      'envelope': '{"jsonrpc":"2.0","jsonrpc":"2.0","method":"n"}',
      'error':
          '{"jsonrpc":"2.0","id":1,"error":{"code":1,"code":2,"message":"x"}}',
      'params':
          '{"jsonrpc":"2.0","method":"event","params":{"type":"x","type":"y"}}',
      'payload':
          '{"jsonrpc":"2.0","method":"event","params":{"type":"x","payload":{"a":1,"a":2}}}',
      'replay row':
          '{"jsonrpc":"2.0","id":1,"result":{"events":[{"seq":1,"seq":2}]}}',
      'escaped-equivalent envelope key':
          '{"jsonrpc":"2.0","id":1,"\\u0069d":2,"result":{}}',
    }.entries) {
      test('rejects duplicate in ${entry.key}', () {
        expect(
          () =>
              JsonRpcWireDecoder.decodeText(entry.value, replayCapable: false),
          throwsFormatException,
        );
      });
    }
    test('accepts duplicate-free nested JSON', () {
      final frame = JsonRpcWireDecoder.decodeText(
        '{"jsonrpc":"2.0","id":1,"result":{"nested":{"a":[1,true,null]}}}',
        replayCapable: false,
      );
      expect(frame, isA<JsonRpcResponseFrame>());
    });

    for (final number in const [
      '0',
      '-0',
      '1',
      '-42',
      '1.25',
      '-0.5',
      '1e3',
      '1E-3',
      '1e+3',
    ]) {
      test('accepts JSON number $number', () {
        expect(
          JsonRpcWireDecoder.decodeText(
            '{"jsonrpc":"2.0","id":1,"result":$number}',
            replayCapable: false,
          ),
          isA<JsonRpcResponseFrame>(),
        );
      });
    }

    for (final number in const [
      '01',
      '-01',
      '1.',
      '.1',
      '1e',
      '1e+',
      '--1',
      '+1',
      'NaN',
      'Infinity',
    ]) {
      test('rejects invalid JSON number $number', () {
        expect(
          () => JsonRpcWireDecoder.decodeText(
            '{"jsonrpc":"2.0","id":1,"result":$number}',
            replayCapable: false,
          ),
          throwsFormatException,
        );
      });
    }

    test('decodes a numeric-heavy Gateway frame without blocking the UI', () {
      final payload = jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'result': [
          for (var i = 0; i < 20000; i++) {'ordinal': i, 'timestamp': i * 1000},
        ],
      });
      final watch = Stopwatch()..start();

      final frame = JsonRpcWireDecoder.decodeText(
        payload,
        replayCapable: false,
      );
      watch.stop();

      expect(frame, isA<JsonRpcResponseFrame>());
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 3)),
        reason: 'numeric tokenization must stay linear in the frame size',
      );
    });
  });

  group('ReplayBatchProof', () {
    ReplayBatchDecision validate(
      Map<String, dynamic> result, {
      List<SessionGatewayEvent> heldEvents = const [],
    }) => ReplayBatchProof.validate(
      runtime: 'runtime-a',
      epoch: 'epoch-a',
      lastSeen: 1,
      result: result,
      held: heldEvents,
    );

    test('commits an exact contiguous local proof without sorting', () {
      final decision = validate({
        'epoch': 'epoch-a',
        'truncated': false,
        'latest_seq': 3,
        'count': 2,
        'events': [row(2), row(3)],
      });
      expect(decision, isA<ReplayBatchCommit>());
      expect((decision as ReplayBatchCommit).newWatermark, 3);
    });

    test('latest_seq below lastSeen quarantines stale replay authority', () {
      final decision = ReplayBatchProof.validate(
        runtime: 'runtime-a',
        epoch: 'epoch-a',
        lastSeen: 5,
        result: const {
          'epoch': 'epoch-a',
          'truncated': false,
          'latest_seq': 4,
          'events': <Object>[],
        },
        held: const [],
      );

      expect(decision, isA<ReplayBatchQuarantine>());
      expect(
        (decision as ReplayBatchQuarantine).reason,
        'stale latest sequence',
      );
    });

    for (final entry in <String, Map<String, dynamic>>{
      'missing latest': {
        'epoch': 'epoch-a',
        'truncated': false,
        'events': <Object>[],
      },
      'latest concurrency gap': {
        'epoch': 'epoch-a',
        'truncated': false,
        'latest_seq': 2,
        'events': <Object>[],
      },
      'duplicate': {
        'epoch': 'epoch-a',
        'truncated': false,
        'latest_seq': 2,
        'events': [row(2), row(2)],
      },
      'gap': {
        'epoch': 'epoch-a',
        'truncated': false,
        'latest_seq': 4,
        'events': [row(2), row(4)],
      },
      'out of order': {
        'epoch': 'epoch-a',
        'truncated': false,
        'latest_seq': 3,
        'events': [row(3), row(2)],
      },
      'count mismatch': {
        'epoch': 'epoch-a',
        'truncated': false,
        'latest_seq': 2,
        'count': 0,
        'events': [row(2)],
      },
      'trimmed epoch': {
        'epoch': ' epoch-a ',
        'truncated': false,
        'latest_seq': 1,
        'events': <Object>[],
      },
      'trimmed runtime': {
        'epoch': 'epoch-a',
        'truncated': false,
        'latest_seq': 2,
        'events': [row(2, session: ' runtime-a ')],
      },
      'truncated': {
        'epoch': 'epoch-a',
        'truncated': true,
        'latest_seq': 1,
        'events': <Object>[],
      },
    }.entries) {
      test('quarantines ${entry.key}', () {
        expect(validate(entry.value), isA<ReplayBatchQuarantine>());
      });
    }

    test('accepts identical held overlap and contiguous tail', () {
      final decision = validate(
        {
          'epoch': 'epoch-a',
          'truncated': false,
          'latest_seq': 2,
          'events': [row(2)],
        },
        heldEvents: [held(2), held(3)],
      );
      expect(decision, isA<ReplayBatchCommit>());
      expect(
        (decision as ReplayBatchCommit).held.map((event) => event.sequence),
        [3],
      );
    });

    test('quarantines conflicting held overlap', () {
      expect(
        validate(
          {
            'epoch': 'epoch-a',
            'truncated': false,
            'latest_seq': 2,
            'events': [row(2)],
          },
          heldEvents: [held(2, text: 'different')],
        ),
        isA<ReplayBatchQuarantine>(),
      );
    });

    test('quarantines held gap and preserves received order', () {
      expect(
        validate(
          {
            'epoch': 'epoch-a',
            'truncated': false,
            'latest_seq': 1,
            'events': <Object>[],
          },
          heldEvents: [held(3), held(2)],
        ),
        isA<ReplayBatchQuarantine>(),
      );
    });
  });
}
