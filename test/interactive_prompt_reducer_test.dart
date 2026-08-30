import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/interactive_prompt_reducer.dart';

InteractivePromptKey _key(String runtime, [String request = 'request-1']) =>
    InteractivePromptKey(runtimeSessionId: runtime, requestId: request);

ClarifyPromptRequest _clarify(String runtime, [String request = 'request-1']) =>
    ClarifyPromptRequest(
      key: _key(runtime, request),
      question: '¿Qué entorno?',
      choices: const ['Pruebas', 'Producción'],
    );

ClarifyPromptRequest _clarifyBatch(
  String runtime,
  String request, {
  List<ClarifyQuestion> questions = const [
    ClarifyQuestion(qid: 'q0', question: '¿A?'),
    ClarifyQuestion(qid: 'q1', question: '¿B?'),
  ],
  Map<String, String> lockedAnswers = const {},
}) => ClarifyPromptRequest(
  key: _key(runtime, request),
  questions: questions,
  lockedAnswers: lockedAnswers,
);

InteractivePromptRequest _requestForKind(
  InteractivePromptKind kind,
  String runtime,
  String request,
) => switch (kind) {
  InteractivePromptKind.clarify => _clarify(runtime, request),
  InteractivePromptKind.sudo => SudoPromptRequest(key: _key(runtime, request)),
  InteractivePromptKind.secret => SecretPromptRequest(
    key: _key(runtime, request),
    envVar: 'TEST_TOKEN',
    prompt: 'Token',
  ),
  InteractivePromptKind.terminalRead => TerminalReadPromptRequest(
    key: _key(runtime, request),
    start: 0,
    count: 1,
  ),
};

void main() {
  group('typed gateway requests', () {
    test('parses all four Hermes 0.19 blocking event shapes', () {
      final clarify = InteractivePromptRequest.fromGatewayEvent(
        type: 'clarify.request',
        runtimeSessionId: 'runtime-a',
        payload: const {
          'request_id': 'clarify-1',
          'question': '¿Cuál?',
          'choices': ['A', 'B'],
        },
      );
      final sudo = InteractivePromptRequest.fromGatewayEvent(
        type: 'sudo.request',
        runtimeSessionId: 'runtime-a',
        payload: const {'request_id': 'sudo-1'},
      );
      final secret = InteractivePromptRequest.fromGatewayEvent(
        type: 'secret.request',
        runtimeSessionId: 'runtime-a',
        payload: const {
          'request_id': 'secret-1',
          'env_var': 'DEPLOY_TOKEN',
          'prompt': 'Token de despliegue',
          'metadata': {'provider': 'example'},
        },
      );
      final terminal = InteractivePromptRequest.fromGatewayEvent(
        type: 'terminal.read.request',
        runtimeSessionId: 'runtime-a',
        payload: const {'request_id': 'terminal-1', 'start': 4, 'count': 12},
      );

      expect(clarify, isA<ClarifyPromptRequest>());
      expect((clarify as ClarifyPromptRequest).choices, ['A', 'B']);
      expect(sudo, isA<SudoPromptRequest>());
      expect(secret, isA<SecretPromptRequest>());
      expect((secret as SecretPromptRequest).envVar, 'DEPLOY_TOKEN');
      expect(terminal, isA<TerminalReadPromptRequest>());
      expect((terminal as TerminalReadPromptRequest).start, 4);
      expect(terminal.count, 12);
    });

    test('rejects malformed opaque identities instead of coercing them', () {
      expect(
        () => InteractivePromptRequest.fromGatewayEvent(
          type: 'sudo.request',
          runtimeSessionId: 'runtime-a',
          payload: const {'request_id': 42},
        ),
        throwsFormatException,
      );
      expect(
        () =>
            InteractivePromptKey(runtimeSessionId: ' ', requestId: 'request-1'),
        throwsFormatException,
      );
    });

    test('rejects a clarify batch with malformed questions atomically', () {
      expect(
        () => InteractivePromptRequest.fromGatewayEvent(
          type: 'clarify.request',
          runtimeSessionId: 'runtime-a',
          payload: const {
            'request_id': 'batch-malformed',
            'questions': [
              {
                'qid': 'q0',
                'question': '¿Bebida?',
                'choices': ['Coffee'],
              },
              {'qid': '', 'question': ''},
            ],
          },
        ),
        throwsFormatException,
      );
    });

    test('rejects a clarify batch with duplicate qids atomically', () {
      expect(
        () => InteractivePromptRequest.fromGatewayEvent(
          type: 'clarify.request',
          runtimeSessionId: 'runtime-a',
          payload: const {
            'request_id': 'batch-dup',
            'questions': [
              {
                'qid': 'q0',
                'question': '¿A?',
                'choices': ['1', '2'],
              },
              {
                'qid': 'q0',
                'question': '¿B?',
                'choices': ['x', 'y'],
              },
            ],
          },
        ),
        throwsFormatException,
      );
    });

    test('rejects malformed batch fields instead of normalizing them', () {
      final invalidPayloads = <Map<String, dynamic>>[
        {
          'request_id': 'bad-questions-type',
          'questions': 'not-a-list',
          'question': 'legacy must not hide an invalid batch',
        },
        {
          'request_id': 'bad-choices-type',
          'questions': [
            {'qid': 'q0', 'question': '¿A?', 'choices': 'A'},
          ],
        },
        {
          'request_id': 'bad-choice-element',
          'questions': [
            {
              'qid': 'q0',
              'question': '¿A?',
              'choices': ['A', 2],
            },
          ],
        },
        {
          'request_id': 'bad-multi-select',
          'questions': [
            {
              'qid': 'q0',
              'question': '¿A?',
              'choices': ['A'],
              'multi_select': 'yes',
            },
          ],
        },
        {
          'request_id': 'bad-answers-type',
          'questions': [
            {'qid': 'q0', 'question': '¿A?'},
          ],
          'answers': ['A'],
        },
        {
          'request_id': 'unknown-answer-qid',
          'questions': [
            {'qid': 'q0', 'question': '¿A?'},
          ],
          'answers': {'q1': 'A'},
        },
      ];

      for (final payload in invalidPayloads) {
        expect(
          () => InteractivePromptRequest.fromGatewayEvent(
            type: 'clarify.request',
            runtimeSessionId: 'runtime-a',
            payload: payload,
          ),
          throwsFormatException,
          reason: payload['request_id'] as String,
        );
      }
    });

    test('shared interpreter applies source-specific malformed scope', () {
      const payload = {
        'request_id': 'shared-malformed',
        'questions': 'not-a-list',
      };
      final ordinary = InteractivePromptParseOutcome.tryFromGatewayEvent(
        type: 'clarify.request',
        runtimeSessionId: 'runtime-a',
        payload: payload,
      );
      final authoritative = InteractivePromptParseOutcome.tryFromGatewayEvent(
        type: 'clarify.request',
        runtimeSessionId: 'runtime-a',
        payload: payload,
        source: InteractivePromptParseSource.authoritativeKindSlot,
      );

      expect(
        (ordinary! as InteractivePromptParseFailure).scope,
        InteractivePromptFailureScope.exactKey,
      );
      expect(
        (authoritative! as InteractivePromptParseFailure).scope,
        InteractivePromptFailureScope.runtimeKind,
      );
    });
  });

  group('InteractivePromptReducer', () {
    test('duplicate request is idempotent', () {
      const initial = InteractivePromptState.empty();
      final event = InteractivePromptReceived(_clarify('runtime-a'));
      final once = InteractivePromptReducer.reduce(initial, event);
      final twice = InteractivePromptReducer.reduce(once, event);

      expect(once.entries, hasLength(1));
      expect(identical(once, twice), isTrue);
      expect(once[_key('runtime-a')]?.status, InteractivePromptStatus.pending);
    });

    test('cross-kind replay expires the exact key and erases its payload', () {
      for (final firstKind in InteractivePromptKind.values) {
        for (final replayKind in InteractivePromptKind.values) {
          if (firstKind == replayKind) continue;
          final requestId = '${firstKind.name}-${replayKind.name}';
          final key = _key('runtime-a', requestId);
          var state = InteractivePromptReducer.reduce(
            const InteractivePromptState.empty(),
            InteractivePromptReceived(
              _requestForKind(firstKind, 'runtime-a', requestId),
            ),
          );

          state = InteractivePromptReducer.reduce(
            state,
            InteractivePromptReceived(
              _requestForKind(replayKind, 'runtime-a', requestId),
            ),
          );

          expect(
            state[key]?.status,
            InteractivePromptStatus.expired,
            reason: '${firstKind.name} then ${replayKind.name}',
          );
          expect(
            state[key]?.request,
            isNull,
            reason: '${firstKind.name} then ${replayKind.name}',
          );
          final tombstone = state;
          for (final delayedKind in InteractivePromptKind.values) {
            state = InteractivePromptReducer.reduce(
              state,
              InteractivePromptReceived(
                _requestForKind(delayedKind, 'runtime-a', requestId),
              ),
            );
            expect(
              identical(state, tombstone),
              isTrue,
              reason:
                  '${firstKind.name} then ${replayKind.name}, '
                  'late ${delayedKind.name}',
            );
          }
        }
      }
    });

    test('malformed kind scope expires only live peers in its runtime', () {
      var state = const InteractivePromptState.empty();
      for (final request in <InteractivePromptRequest>[
        _clarify('runtime-a', 'clarify-live'),
        _clarify('runtime-a', 'clarify-terminal'),
        _requestForKind(
          InteractivePromptKind.secret,
          'runtime-a',
          'secret-live',
        ),
        _clarify('runtime-b', 'clarify-other-runtime'),
      ]) {
        state = InteractivePromptReducer.reduce(
          state,
          InteractivePromptReceived(request),
        );
      }
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptResponded(_key('runtime-a', 'clarify-terminal')),
      );
      final outcome = InteractivePromptParseOutcome.tryFromGatewayEvent(
        type: 'clarify.request',
        runtimeSessionId: 'runtime-a',
        payload: const {'questions': 'not-a-list'},
      );
      expect(outcome, isA<InteractivePromptParseFailure>());
      final failure = outcome! as InteractivePromptParseFailure;
      expect(failure.scope, InteractivePromptFailureScope.runtimeKind);

      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptMalformedReceived(failure),
      );

      expect(
        state[_key('runtime-a', 'clarify-live')]?.status,
        InteractivePromptStatus.expired,
      );
      expect(state[_key('runtime-a', 'clarify-live')]?.request, isNull);
      expect(
        state[_key('runtime-a', 'clarify-terminal')]?.status,
        InteractivePromptStatus.responded,
      );
      expect(
        state[_key('runtime-a', 'secret-live')]?.status,
        InteractivePromptStatus.pending,
      );
      expect(
        state[_key('runtime-b', 'clarify-other-runtime')]?.status,
        InteractivePromptStatus.pending,
      );
    });

    test('transport-scope malformed event cannot mutate another runtime', () {
      final populated = InteractivePromptReducer.reduce(
        const InteractivePromptState.empty(),
        InteractivePromptReceived(_clarify('runtime-a', 'clarify-live')),
      );
      final outcome = InteractivePromptParseOutcome.tryFromGatewayEvent(
        type: 'clarify.request',
        runtimeSessionId: '',
        payload: const {
          'request_id': 'clarify-live',
          'questions': 'not-a-list',
        },
      );
      final failure = outcome! as InteractivePromptParseFailure;
      expect(failure.scope, InteractivePromptFailureScope.transport);

      final next = InteractivePromptReducer.reduce(
        populated,
        InteractivePromptMalformedReceived(failure),
      );

      expect(identical(next, populated), isTrue);
      expect(
        next[_key('runtime-a', 'clarify-live')]?.status,
        InteractivePromptStatus.pending,
      );
    });

    test('terminal out-of-order event creates an absorbing tombstone', () {
      const initial = InteractivePromptState.empty();
      final key = _key('runtime-a');
      final expired = InteractivePromptReducer.reduce(
        initial,
        InteractivePromptExpired(key),
      );
      final delayedRequest = InteractivePromptReducer.reduce(
        expired,
        InteractivePromptReceived(_clarify('runtime-a')),
      );
      final delayedResponse = InteractivePromptReducer.reduce(
        delayedRequest,
        InteractivePromptResponded(key),
      );

      expect(expired[key]?.request, isNull);
      expect(expired[key]?.status, InteractivePromptStatus.expired);
      expect(identical(expired, delayedRequest), isTrue);
      expect(identical(delayedRequest, delayedResponse), isTrue);
    });

    test(
      'non-terminal out-of-order event attaches request without rollback',
      () {
        const initial = InteractivePromptState.empty();
        final key = _key('runtime-a');
        final responding = InteractivePromptReducer.reduce(
          initial,
          InteractivePromptResponseStarted(key),
        );
        final received = InteractivePromptReducer.reduce(
          responding,
          InteractivePromptReceived(_clarify('runtime-a')),
        );

        expect(received[key]?.request, isA<ClarifyPromptRequest>());
        expect(received[key]?.status, InteractivePromptStatus.responding);
      },
    );

    test('failed response requires a fresh explicit input', () {
      var state = InteractivePromptReducer.reduce(
        const InteractivePromptState.empty(),
        InteractivePromptReceived(_clarify('runtime-a')),
      );
      final key = _key('runtime-a');
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptResponseStarted(key),
      );
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptResponseFailed(key),
      );

      expect(state[key]?.status, InteractivePromptStatus.pending);
      expect(state[key]?.needsInput, isTrue);
    });

    test('same request id in two runtimes remains independent', () {
      var state = const InteractivePromptState.empty();
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptReceived(_clarify('runtime-a')),
      );
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptReceived(_clarify('runtime-b')),
      );
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptResponded(_key('runtime-a')),
      );

      expect(state.entries, hasLength(2));
      expect(
        state[_key('runtime-a')]?.status,
        InteractivePromptStatus.responded,
      );
      expect(state[_key('runtime-b')]?.status, InteractivePromptStatus.pending);
    });

    test('cancelled is terminal and cannot be reopened or overwritten', () {
      var state = const InteractivePromptState.empty();
      final key = _key('runtime-a');
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptReceived(_clarify('runtime-a')),
      );
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptCancelled(key),
      );
      final cancelled = state;
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptReceived(_clarify('runtime-a')),
      );
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptResponded(key),
      );

      expect(identical(cancelled, state), isTrue);
      expect(state[key]?.status, InteractivePromptStatus.cancelled);
      expect(state.blocking, isEmpty);
    });

    test('runtime expiry affects only its live requests', () {
      var state = const InteractivePromptState.empty();
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptReceived(_clarify('runtime-a', 'one')),
      );
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptReceived(_clarify('runtime-a', 'two')),
      );
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptResponded(_key('runtime-a', 'two')),
      );
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptReceived(_clarify('runtime-b', 'one')),
      );
      state = InteractivePromptReducer.reduce(
        state,
        const InteractivePromptRuntimeExpired('runtime-a'),
      );

      expect(
        state[_key('runtime-a', 'one')]?.status,
        InteractivePromptStatus.expired,
      );
      expect(
        state[_key('runtime-a', 'two')]?.status,
        InteractivePromptStatus.responded,
      );
      expect(
        state[_key('runtime-b', 'one')]?.status,
        InteractivePromptStatus.pending,
      );
    });

    test('dispose clears all entries and absorbs later socket events', () {
      final populated = InteractivePromptReducer.reduce(
        const InteractivePromptState.empty(),
        InteractivePromptReceived(_clarify('runtime-a')),
      );
      final disposed = InteractivePromptReducer.reduce(
        populated,
        const InteractivePromptDisposed(),
      );
      final late = InteractivePromptReducer.reduce(
        disposed,
        InteractivePromptReceived(_clarify('runtime-a')),
      );

      expect(disposed.isDisposed, isTrue);
      expect(disposed.entries, isEmpty);
      expect(identical(disposed, late), isTrue);
    });

    test(
      'replay with matching questions merges new locked answers monotonically',
      () {
        var state = InteractivePromptReducer.reduce(
          const InteractivePromptState.empty(),
          InteractivePromptReceived(
            _clarifyBatch('runtime-a', 'request-1', lockedAnswers: {'q0': 'A'}),
          ),
        );
        state = InteractivePromptReducer.reduce(
          state,
          InteractivePromptReceived(
            _clarifyBatch(
              'runtime-a',
              'request-1',
              lockedAnswers: {'q0': 'A', 'q1': 'B'},
            ),
          ),
        );

        final request =
            state[_key('runtime-a', 'request-1')]?.request
                as ClarifyPromptRequest;
        expect(request.lockedAnswers, {'q0': 'A', 'q1': 'B'});
      },
    );

    test('replay never erases confirmed answers with an older snapshot', () {
      var state = InteractivePromptReducer.reduce(
        const InteractivePromptState.empty(),
        InteractivePromptReceived(
          _clarifyBatch(
            'runtime-a',
            'request-1',
            lockedAnswers: {'q0': 'A', 'q1': 'B'},
          ),
        ),
      );
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptReceived(
          _clarifyBatch('runtime-a', 'request-1', lockedAnswers: {'q0': 'A'}),
        ),
      );

      final request =
          state[_key('runtime-a', 'request-1')]?.request
              as ClarifyPromptRequest;
      expect(request.lockedAnswers, {'q0': 'A', 'q1': 'B'});
    });

    test('replay with different questions expires the live request', () {
      var state = InteractivePromptReducer.reduce(
        const InteractivePromptState.empty(),
        InteractivePromptReceived(
          _clarifyBatch(
            'runtime-a',
            'request-1',
            questions: const [ClarifyQuestion(qid: 'q0', question: '¿A?')],
          ),
        ),
      );
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptReceived(
          _clarifyBatch(
            'runtime-a',
            'request-1',
            questions: const [ClarifyQuestion(qid: 'q0', question: '¿B?')],
          ),
        ),
      );

      expect(
        state[_key('runtime-a', 'request-1')]?.status,
        InteractivePromptStatus.expired,
      );
    });

    test(
      'legacy replay with a changed definition expires the live request',
      () {
        var state = InteractivePromptReducer.reduce(
          const InteractivePromptState.empty(),
          InteractivePromptReceived(_clarify('runtime-a')),
        );
        state = InteractivePromptReducer.reduce(
          state,
          InteractivePromptReceived(
            ClarifyPromptRequest(
              key: _key('runtime-a'),
              question: '¿Otra pregunta?',
              choices: const ['Pruebas', 'Producción'],
            ),
          ),
        );

        expect(
          state[_key('runtime-a')]?.status,
          InteractivePromptStatus.expired,
        );
      },
    );

    test(
      'authoritative cross-kind collision erases the old request payload',
      () {
        final key = _key('runtime-a', 'shared-request');
        var state = InteractivePromptReducer.reduce(
          const InteractivePromptState.empty(),
          InteractivePromptReceived(
            _requestForKind(
              InteractivePromptKind.terminalRead,
              key.runtimeSessionId,
              key.requestId,
            ),
          ),
        );

        state = InteractivePromptReducer.reduce(
          state,
          InteractivePromptSnapshotReconciled(
            _clarify(key.runtimeSessionId, key.requestId),
          ),
        );

        final entry = state[key];
        expect(entry?.status, InteractivePromptStatus.expired);
        expect(entry?.request, isNull);
        expect(state.blocking, isEmpty);
      },
    );

    test('authoritative clear preserves other prompt kinds and runtimes', () {
      var state = InteractivePromptReducer.reduce(
        const InteractivePromptState.empty(),
        InteractivePromptReceived(_clarify('runtime-a', 'clarify-a')),
      );
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptReceived(
          SecretPromptRequest(
            key: _key('runtime-a', 'secret-a'),
            envVar: 'TOKEN',
            prompt: 'Token',
          ),
        ),
      );
      state = InteractivePromptReducer.reduce(
        state,
        InteractivePromptReceived(_clarify('runtime-b', 'clarify-b')),
      );
      state = InteractivePromptReducer.reduce(
        state,
        const InteractivePromptClarifySnapshotCleared('runtime-a'),
      );

      expect(
        state[_key('runtime-a', 'clarify-a')]?.status,
        InteractivePromptStatus.expired,
      );
      expect(
        state[_key('runtime-a', 'secret-a')]?.status,
        InteractivePromptStatus.pending,
      );
      expect(
        state[_key('runtime-b', 'clarify-b')]?.status,
        InteractivePromptStatus.pending,
      );
    });
  });

  group('sensitive response handling', () {
    test('clarify question diagnostics redact protocol content', () {
      const question = ClarifyQuestion(
        qid: 'private-qid',
        question: 'private-question',
        choices: ['private-choice'],
      );
      final diagnostics = question.toString();
      final leaked = <String>[
        question.qid,
        question.question,
        ...question.choices,
      ].any(diagnostics.contains);

      expect(leaked, isFalse);
    });

    test(
      'secret and sudo parsers never retain raw maps or accidental values',
      () {
        const secretValue = 'actual-secret-value-DO-NOT-LOG';
        const password = 'actual-sudo-password-DO-NOT-LOG';
        final secret = InteractivePromptRequest.fromGatewayEvent(
          type: 'secret.request',
          runtimeSessionId: 'runtime-a',
          payload: const {
            'request_id': 'secret-1',
            'env_var': 'DEPLOY_TOKEN',
            'prompt': 'Token',
            'metadata': {'accidental_value': secretValue},
            'value': secretValue,
          },
        );
        final sudo = InteractivePromptRequest.fromGatewayEvent(
          type: 'sudo.request',
          runtimeSessionId: 'runtime-a',
          payload: const {'request_id': 'sudo-1', 'password': password},
        );

        final diagnostics =
            '${jsonEncode(secret)} $secret ${jsonEncode(sudo)} '
            '$sudo';
        expect(diagnostics, isNot(contains(secretValue)));
        expect(diagnostics, isNot(contains(password)));
        expect(diagnostics, isNot(contains('metadata')));
      },
    );

    test('one-use value redacts on take and never serializes its contents', () {
      const raw = 'one-use-sensitive-value';
      final value = EphemeralSensitiveValue(raw);

      expect(value.hasValue, isTrue);
      expect(value.toString(), isNot(contains(raw)));
      expect(jsonEncode(value), isNot(contains(raw)));
      expect(value.take(), raw);
      expect(value.hasValue, isFalse);
      expect(() => value.take(), throwsStateError);
      expect(value.toString(), isNot(contains(raw)));
      expect(jsonEncode(value), isNot(contains(raw)));
    });

    test('redact and dispose remove the holder reference idempotently', () {
      final redacted = EphemeralSensitiveValue('redact-me');
      redacted.redact();
      expect(redacted.hasValue, isFalse);
      expect(() => redacted.take(), throwsStateError);

      final disposed = EphemeralSensitiveValue('dispose-me');
      disposed.dispose();
      disposed.dispose();
      expect(disposed.hasValue, isFalse);
      expect(disposed.isDisposed, isTrue);
      expect(() => disposed.take(), throwsStateError);
    });
  });

  test('terminal read without an owned terminal is exactly empty text', () {
    expect(TerminalReadResponsePolicy.noOwnedTerminalText, isEmpty);
    expect(TerminalReadResponsePolicy.noOwnedTerminalText, '');
  });

  group('clarify batch parsing', () {
    test('batch with a single question is a batch, not legacy', () {
      final request = InteractivePromptRequest.fromGatewayEvent(
        type: 'clarify.request',
        runtimeSessionId: 'runtime-a',
        payload: const {
          'request_id': 'batch-1',
          'questions': [
            {
              'qid': 'q0',
              'question': '¿Qué opción?',
              'choices': ['A', 'B'],
              'multi_select': false,
            },
          ],
        },
      );
      expect(request, isA<ClarifyPromptRequest>());
      final clarify = request as ClarifyPromptRequest;
      expect(clarify.isBatch, isTrue);
      expect(clarify.questions, hasLength(1));
      expect(clarify.questions.single.qid, 'q0');
      expect(clarify.questions.single.question, '¿Qué opción?');
      expect(clarify.questions.single.choices, ['A', 'B']);
      expect(clarify.questions.single.multiSelect, isFalse);
    });

    test(
      'batch with several questions keeps qid, text, choices and multi_select',
      () {
        final request = InteractivePromptRequest.fromGatewayEvent(
          type: 'clarify.request',
          runtimeSessionId: 'runtime-a',
          payload: const {
            'request_id': 'batch-2',
            'questions': [
              {
                'qid': 'q0',
                'question': '¿Bebida?',
                'choices': ['Coffee', 'Tea'],
                'multi_select': false,
              },
              {
                'qid': 'q1',
                'question': '¿Momentos?',
                'choices': ['Morning', 'Evening'],
                'multi_select': true,
              },
            ],
          },
        );
        final clarify = request as ClarifyPromptRequest;
        expect(clarify.questions, hasLength(2));
        expect(clarify.questions[1].multiSelect, isTrue);
        expect(clarify.questions[1].qid, 'q1');
      },
    );

    test('legacy single-question payload still works', () {
      final request = InteractivePromptRequest.fromGatewayEvent(
        type: 'clarify.request',
        runtimeSessionId: 'runtime-a',
        payload: const {
          'request_id': 'legacy-1',
          'question': '¿Cuál?',
          'choices': ['A', 'B'],
        },
      );
      final clarify = request as ClarifyPromptRequest;
      expect(clarify.isBatch, isFalse);
      expect(clarify.question, '¿Cuál?');
      expect(clarify.choices, ['A', 'B']);
      expect(clarify.multiSelect, isFalse);
    });

    test('legacy multi_select is rejected instead of answered as single', () {
      expect(
        () => InteractivePromptRequest.fromGatewayEvent(
          type: 'clarify.request',
          runtimeSessionId: 'runtime-a',
          payload: const {
            'request_id': 'legacy-multi',
            'question': '¿Cuáles?',
            'choices': ['A', 'B'],
            'multi_select': true,
          },
        ),
        throwsFormatException,
      );
    });

    test('opaque ids, text, choices and locked answers stay literal', () {
      final request =
          InteractivePromptRequest.fromGatewayEvent(
                type: 'clarify.request',
                runtimeSessionId: 'runtime-a',
                payload: const {
                  'request_id': 'literal-batch',
                  'questions': [
                    {
                      'qid': ' q0 ',
                      'question': ' pregunta ',
                      'choices': [' A ', 'B'],
                    },
                  ],
                  'answers': {' q0 ': ' A '},
                },
              )
              as ClarifyPromptRequest;

      expect(request.questions.single.qid, ' q0 ');
      expect(request.questions.single.question, ' pregunta ');
      expect(request.questions.single.choices, [' A ', 'B']);
      expect(request.lockedAnswers, {' q0 ': ' A '});
    });

    test('choices containing CR or LF are rejected atomically', () {
      for (final invalid in ['A\n', '\nA', 'A\rB', 'A\r\nB']) {
        expect(
          () => InteractivePromptRequest.fromGatewayEvent(
            type: 'clarify.request',
            runtimeSessionId: 'runtime-a',
            payload: {
              'request_id': 'line-break',
              'questions': [
                {
                  'qid': 'q0',
                  'question': 'Pregunta',
                  'choices': [invalid, 'B'],
                },
              ],
            },
          ),
          throwsFormatException,
          reason: invalid.codeUnits.toString(),
        );
      }
    });

    test('locked answers from replay are exposed on the request', () {
      final request = InteractivePromptRequest.fromGatewayEvent(
        type: 'clarify.request',
        runtimeSessionId: 'runtime-a',
        payload: const {
          'request_id': 'batch-locked',
          'questions': [
            {
              'qid': 'q0',
              'question': 'Q1',
              'choices': ['A', 'B'],
            },
          ],
          'answers': {'q0': 'A'},
        },
      );
      final clarify = request as ClarifyPromptRequest;
      expect(clarify.lockedAnswers, {'q0': 'A'});
    });

    test('rejects batch with invalid question entries atomically', () {
      expect(
        () => InteractivePromptRequest.fromGatewayEvent(
          type: 'clarify.request',
          runtimeSessionId: 'runtime-a',
          payload: const {
            'request_id': 'batch-partial',
            'questions': [
              {'qid': '', 'question': 'No id'},
              {'qid': 'q0', 'question': 'Valid'},
              {'qid': 'q1', 'question': ''},
            ],
          },
        ),
        throwsFormatException,
      );
    });

    test('empty batch with no legacy question is rejected', () {
      expect(
        () => InteractivePromptRequest.fromGatewayEvent(
          type: 'clarify.request',
          runtimeSessionId: 'runtime-a',
          payload: const {'request_id': 'empty-batch', 'questions': []},
        ),
        throwsFormatException,
      );
    });
  });
}
