import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _InteractiveGateway
    implements
        HermesDesktopGateway,
        HermesDesktopInteractivePromptGateway,
        HermesDesktopSessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  bool _connected = false;
  int terminalResponses = 0;
  int sensitiveResponses = 0;
  String? clarifyRequestId;
  String? clarifyAnswer;
  String? clarifyQuestionId;
  Future<DesktopPromptResponse> Function(
    String requestId,
    String answer, {
    String? questionId,
  })?
  onRespondToClarify;
  DesktopPromptResponseStatus nextSensitiveStatus =
      DesktopPromptResponseStatus.ok;
  Object? nextSensitiveError;
  DesktopSessionSnapshot? nextResumeSnapshot;
  int lifecycleResumes = 0;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async => _connected = true;

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-interactive',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    lifecycleResumes++;
    return nextResumeSnapshot ??
        DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-interactive',
          storedSessionId: storedSessionId,
          created: false,
        );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-interactive',
    storedSessionId: 'stored-interactive',
    created: true,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  void emit(
    String type,
    Map<String, dynamic> payload, {
    String sessionId = 'runtime-interactive',
  }) {
    _events.add(
      TuiGatewayEvent(type: type, sessionId: sessionId, payload: payload),
    );
  }

  void disconnect() {
    _connected = false;
    _events.addError(StateError('test disconnect'));
  }

  @override
  Future<DesktopPromptResponse> respondToClarify(
    String requestId,
    String answer, {
    String? questionId,
  }) async {
    final callback = onRespondToClarify;
    if (callback != null) {
      return callback(requestId, answer, questionId: questionId);
    }
    clarifyRequestId = requestId;
    clarifyAnswer = answer;
    clarifyQuestionId = questionId;
    return DesktopPromptResponse.fromJson(const {
      'status': 'ok',
    }, method: 'clarify.respond');
  }

  @override
  Future<DesktopPromptResponse> respondToSudo(
    String requestId,
    EphemeralSensitiveValue password,
  ) => _sensitive('sudo.respond', password);

  @override
  Future<DesktopPromptResponse> respondToSecret(
    String requestId,
    EphemeralSensitiveValue value,
  ) => _sensitive('secret.respond', value);

  Future<DesktopPromptResponse> _sensitive(
    String method,
    EphemeralSensitiveValue value,
  ) async {
    sensitiveResponses++;
    value.take();
    value.dispose();
    if (nextSensitiveError case final error?) throw error;
    return DesktopPromptResponse.fromJson(
      {'status': nextSensitiveStatus.name},
      method: method,
      allowExpired: true,
    );
  }

  @override
  Future<DesktopPromptResponse> respondToTerminalRead(String requestId) async {
    terminalResponses++;
    return DesktopPromptResponse.fromJson(const {
      'status': 'ok',
    }, method: 'terminal.read.respond');
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
  }) async {}

  @override
  Future<void> close() async {
    _connected = false;
    if (!_events.isClosed) await _events.close();
  }
}

ActiveChat _chat(
  _InteractiveGateway gateway, {
  void Function(ActiveChatEvent)? onEvent,
}) => ActiveChat(
  connection: SavedConnection(
    id: 'conn-interactive',
    label: 'Interactive',
    host: 'example.invalid',
    port: 443,
    apiKey: 'test-only',
    useHttps: true,
    kind: InstanceKind.vps,
  ),
  sessionId: 'stored-interactive',
  sessionTitle: 'Interactive',
  notifications: null,
  onTerminal: () {},
  onEvent: onEvent,
  api: ApiClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'test-only',
    httpClient: MockClient((_) async => http.Response('unused', 500)),
  ),
  desktopGateway: gateway,
);

Future<ActiveChat> _start(
  _InteractiveGateway gateway, {
  void Function(ActiveChatEvent)? onEvent,
}) async {
  final chat = _chat(gateway, onEvent: onEvent);
  expect(
    await chat.send(
      fullText: 'turno de prueba',
      model: 'hermes-agent',
      history: const [],
    ),
    isTrue,
  );
  return chat;
}

Future<void> _waitUntil(bool Function() predicate, [String? reason]) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(reason ?? 'Condition was not reached');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('clarify se aparca por runtime y responde una sola vez', () async {
    final gateway = _InteractiveGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('clarify.request', const {
      'request_id': 'foreign',
      'question': 'Foreign',
    }, sessionId: 'runtime-other');
    gateway.emit('clarify.request', const {
      'request_id': 'clarify-1',
      'question': '¿Qué opción?',
      'choices': ['A', 'B'],
    });
    await _waitUntil(() => chat.pendingInteractivePrompt != null);

    final entry = chat.pendingInteractivePrompt!;
    expect(entry.request, isA<ClarifyPromptRequest>());
    expect(chat.needsInput, isTrue);
    await chat.respondToClarify(entry.key, 'B');

    expect(gateway.clarifyRequestId, 'clarify-1');
    expect(gateway.clarifyAnswer, 'B');
    expect(chat.pendingInteractivePrompt, isNull);
    expect(chat.needsInput, isFalse);
  });

  test(
    'terminal.read se responde vacío por política y deduplica replay',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      const payload = {'request_id': 'terminal-1', 'start': 0, 'count': 40};

      gateway.emit('terminal.read.request', payload);
      gateway.emit('terminal.read.request', payload);
      await _waitUntil(() => gateway.terminalResponses == 1);
      await Future<void>.delayed(Duration.zero);

      expect(gateway.terminalResponses, 1);
      expect(chat.pendingInteractivePrompt, isNull);
    },
  );

  test('secret expired se borra y un replay tardío no lo reabre', () async {
    final gateway = _InteractiveGateway()
      ..nextSensitiveStatus = DesktopPromptResponseStatus.expired;
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    const payload = {
      'request_id': 'secret-1',
      'env_var': 'DEPLOY_TOKEN',
      'prompt': 'Token',
    };
    gateway.emit('secret.request', payload);
    await _waitUntil(() => chat.pendingInteractivePrompt != null);
    final entry = chat.pendingInteractivePrompt!;
    final value = EphemeralSensitiveValue('one-shot-value');

    final result = await chat.respondToSecret(entry.key, value);
    expect(result.isExpired, isTrue);
    expect(value.isDisposed, isTrue);
    expect(value.hasValue, isFalse);
    expect(chat.pendingInteractivePrompt, isNull);

    gateway.emit('secret.request', payload);
    await Future<void>.delayed(Duration.zero);
    expect(chat.pendingInteractivePrompt, isNull);
    expect(gateway.sensitiveResponses, 1);
  });

  test(
    'fallo sensible exige valor nuevo y el holder siempre se dispone',
    () async {
      final gateway = _InteractiveGateway()
        ..nextSensitiveError = StateError('sanitized transport failure');
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      gateway.emit('sudo.request', const {'request_id': 'sudo-1'});
      await _waitUntil(() => chat.pendingInteractivePrompt != null);
      final entry = chat.pendingInteractivePrompt!;
      final password = EphemeralSensitiveValue('one-shot-password');

      await expectLater(
        chat.respondToSudo(entry.key, password),
        throwsA(isA<StateError>()),
      );
      expect(password.isDisposed, isTrue);
      expect(password.hasValue, isFalse);
      expect(
        chat.pendingInteractivePrompt?.status,
        InteractivePromptStatus.pending,
      );
    },
  );

  test(
    'disconnect expira la petición del runtime sin cruzarla a otro chat',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      gateway.emit('sudo.request', const {'request_id': 'sudo-disconnect'});
      await _waitUntil(() => chat.pendingInteractivePrompt != null);
      final key = chat.pendingInteractivePrompt!.key;

      gateway.disconnect();
      await _waitUntil(
        () =>
            chat.interactivePrompts[key]?.status ==
            InteractivePromptStatus.expired,
      );

      expect(chat.pendingInteractivePrompt, isNull);
    },
  );

  test(
    'batch clarify se aparca y responde secuencialmente con question_id',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      final calls = <({String? questionId, String answer})>[];
      gateway.onRespondToClarify = (requestId, answer, {questionId}) async {
        calls.add((questionId: questionId, answer: answer));
        return DesktopPromptResponse.fromJson(const {
          'status': 'ok',
        }, method: 'clarify.respond');
      };

      gateway.emit('clarify.request', const {
        'request_id': 'batch-1',
        'questions': [
          {
            'qid': 'q0',
            'question': '¿Bebida?',
            'choices': ['Coffee', 'Tea'],
          },
          {
            'qid': 'q1',
            'question': '¿Momento?',
            'choices': ['Morning', 'Evening'],
          },
        ],
      });
      await _waitUntil(() => chat.pendingInteractivePrompt != null);

      final entry = chat.pendingInteractivePrompt!;
      expect(entry.request, isA<ClarifyPromptRequest>());
      final request = entry.request as ClarifyPromptRequest;
      expect(request.isBatch, isTrue);
      expect(request.questions, hasLength(2));

      await chat.respondToClarifyBatch(entry.key, {
        'q0': 'Coffee',
        'q1': 'Morning',
      });

      expect(calls, [
        (questionId: 'q0', answer: 'Coffee'),
        (questionId: 'q1', answer: 'Morning'),
      ]);
      expect(chat.pendingInteractivePrompt, isNull);
      expect(chat.needsInput, isFalse);
    },
  );

  test('batch replay no duplica la tarjeta', () async {
    final gateway = _InteractiveGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    const payload = {
      'request_id': 'batch-dup',
      'questions': [
        {
          'qid': 'q0',
          'question': '¿Bebida?',
          'choices': ['Coffee', 'Tea'],
        },
      ],
    };
    gateway.emit('clarify.request', payload);
    gateway.emit('clarify.request', payload);
    await _waitUntil(() => chat.pendingInteractivePrompt != null);

    expect(chat.interactivePrompts.forRuntime('runtime-interactive').length, 1);
  });

  test(
    'batch resume omits locked answers and keeps original question order',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      final calls = <({String? questionId, String answer})>[];
      gateway.onRespondToClarify = (requestId, answer, {questionId}) async {
        calls.add((questionId: questionId, answer: answer));
        return DesktopPromptResponse.fromJson(const {
          'status': 'ok',
        }, method: 'clarify.respond');
      };

      gateway.emit('clarify.request', const {
        'request_id': 'batch-resume',
        'questions': [
          {
            'qid': 'q0',
            'question': '¿Bebida?',
            'choices': ['Coffee', 'Tea'],
          },
          {
            'qid': 'q1',
            'question': '¿Momento?',
            'choices': ['Morning'],
          },
          {'qid': 'q2', 'question': '¿Notas?', 'choices': []},
        ],
        'answers': {'q0': 'Coffee', 'q2': 'none'},
      });
      await _waitUntil(() => chat.pendingInteractivePrompt != null);

      final entry = chat.pendingInteractivePrompt!;
      await chat.respondToClarifyBatch(entry.key, {
        'q0': 'Coffee',
        'q1': 'Morning',
        'q2': 'none',
      });

      expect(calls, [(questionId: 'q1', answer: 'Morning')]);
      expect(chat.pendingInteractivePrompt, isNull);
    },
  );

  test(
    'partial success then explicit RPC rejection retries only pending qids',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      final calls = <({String? questionId, String answer})>[];
      var attempt = 0;
      gateway.onRespondToClarify = (requestId, answer, {questionId}) async {
        calls.add((questionId: questionId, answer: answer));
        attempt++;
        if (questionId == 'q1' && attempt <= 2) {
          throw const TuiGatewayRpcError(
            'clarify.respond',
            'rejected before consumption',
            code: 4090,
          );
        }
        return DesktopPromptResponse.fromJson(const {
          'status': 'ok',
        }, method: 'clarify.respond');
      };

      gateway.emit('clarify.request', const {
        'request_id': 'batch-partial',
        'questions': [
          {
            'qid': 'q0',
            'question': '¿A?',
            'choices': ['A0', 'A1'],
          },
          {
            'qid': 'q1',
            'question': '¿B?',
            'choices': ['B0', 'B1'],
          },
        ],
      });
      await _waitUntil(() => chat.pendingInteractivePrompt != null);

      final entry = chat.pendingInteractivePrompt!;
      await expectLater(
        chat.respondToClarifyBatch(entry.key, {'q0': 'A0', 'q1': 'B0'}),
        throwsA(isA<TuiGatewayRpcError>()),
      );

      expect(
        chat.pendingInteractivePrompt?.status,
        InteractivePromptStatus.pending,
      );
      final request =
          chat.pendingInteractivePrompt!.request as ClarifyPromptRequest;
      expect(request.lockedAnswers, {'q0': 'A0'});

      await chat.respondToClarifyBatch(entry.key, {'q0': 'A0', 'q1': 'B0'});

      expect(calls, [
        (questionId: 'q0', answer: 'A0'),
        (questionId: 'q1', answer: 'B0'),
        (questionId: 'q1', answer: 'B0'),
      ]);
      expect(chat.pendingInteractivePrompt, isNull);
    },
  );

  test(
    'batch stops immediately when an intermediate response is expired',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      final calls = <({String? questionId, String answer})>[];
      gateway.onRespondToClarify = (requestId, answer, {questionId}) async {
        calls.add((questionId: questionId, answer: answer));
        if (questionId == 'q0') {
          return DesktopPromptResponse.fromJson(
            const {'status': 'expired'},
            method: 'clarify.respond',
            allowExpired: true,
          );
        }
        return DesktopPromptResponse.fromJson(const {
          'status': 'ok',
        }, method: 'clarify.respond');
      };

      gateway.emit('clarify.request', const {
        'request_id': 'batch-expired',
        'questions': [
          {
            'qid': 'q0',
            'question': '¿A?',
            'choices': ['A0'],
          },
          {
            'qid': 'q1',
            'question': '¿B?',
            'choices': ['B0'],
          },
        ],
      });
      await _waitUntil(() => chat.pendingInteractivePrompt != null);

      final entry = chat.pendingInteractivePrompt!;
      final result = await chat.respondToClarifyBatch(entry.key, {
        'q0': 'A0',
        'q1': 'B0',
      });

      expect(result.isExpired, isTrue);
      expect(calls, [(questionId: 'q0', answer: 'A0')]);
      expect(
        chat.interactivePrompts[entry.key]?.status,
        InteractivePromptStatus.expired,
      );
    },
  );

  test('ambiguous failure reconciles snapshot before allowing retry', () async {
    final gateway = _InteractiveGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    final calls = <String?>[];
    var failOnce = true;
    gateway.onRespondToClarify = (requestId, answer, {questionId}) async {
      calls.add(questionId);
      if (failOnce) {
        failOnce = false;
        throw StateError('ack lost');
      }
      return DesktopPromptResponse.fromJson(const {
        'status': 'ok',
      }, method: 'clarify.respond');
    };
    gateway.emit('clarify.request', const {
      'request_id': 'batch-ambiguous',
      'questions': [
        {
          'qid': 'q0',
          'question': '¿A?',
          'choices': ['A0'],
        },
        {
          'qid': 'q1',
          'question': '¿B?',
          'choices': ['B0'],
        },
      ],
    });
    await _waitUntil(() => chat.pendingInteractivePrompt != null);
    final entry = chat.pendingInteractivePrompt!;
    gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-interactive',
      storedSessionId: 'stored-interactive',
      created: false,
      pendingClarifyProvided: true,
      pendingClarify: {
        'request_id': 'batch-ambiguous',
        'questions': [
          {
            'qid': 'q0',
            'question': '¿A?',
            'choices': ['A0'],
          },
          {
            'qid': 'q1',
            'question': '¿B?',
            'choices': ['B0'],
          },
        ],
        'answers': {'q0': 'A0'},
      },
    );

    await expectLater(
      chat.respondToClarifyBatch(entry.key, {'q0': 'A0', 'q1': 'B0'}),
      throwsA(isA<StateError>()),
    );
    final reconciled =
        chat.pendingInteractivePrompt!.request as ClarifyPromptRequest;
    expect(reconciled.lockedAnswers, {'q0': 'A0'});
    expect(
      chat.pendingInteractivePrompt!.status,
      InteractivePromptStatus.pending,
    );

    await chat.respondToClarifyBatch(entry.key, {'q0': 'A0', 'q1': 'B0'});
    expect(calls, ['q0', 'q1']);
  });

  test(
    'passive snapshot during an in-flight ACK never unlocks or duplicates qid',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      final calls = <String?>[];
      final first = Completer<DesktopPromptResponse>();
      gateway.onRespondToClarify = (requestId, answer, {questionId}) {
        calls.add(questionId);
        if (questionId == 'q0') return first.future;
        return Future.value(
          DesktopPromptResponse.fromJson(const {
            'status': 'ok',
          }, method: 'clarify.respond'),
        );
      };
      const pending = {
        'request_id': 'batch-race',
        'questions': [
          {
            'qid': 'q0',
            'question': '¿A?',
            'choices': ['A0'],
          },
          {
            'qid': 'q1',
            'question': '¿B?',
            'choices': ['B0'],
          },
        ],
      };
      gateway.emit('clarify.request', pending);
      await _waitUntil(() => chat.pendingInteractivePrompt != null);
      final entry = chat.pendingInteractivePrompt!;
      final operation = chat.respondToClarifyBatch(entry.key, {
        'q0': 'A0',
        'q1': 'B0',
      });
      await _waitUntil(() => calls.isNotEmpty);

      gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-interactive',
        storedSessionId: 'stored-interactive',
        created: false,
        pendingClarifyProvided: true,
        pendingClarify: {
          ...pending,
          'answers': {'q1': 'B0'},
        },
      );
      await chat.loadMessages();
      expect(
        chat.interactivePrompts[entry.key]?.status,
        InteractivePromptStatus.responding,
      );

      first.complete(
        DesktopPromptResponse.fromJson(const {
          'status': 'ok',
        }, method: 'clarify.respond'),
      );
      await operation;

      expect(calls, ['q0']);
    },
  );

  test(
    'runtime switch during an in-flight batch ACK expires the old entry',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      final calls = <String?>[];
      final firstAck = Completer<DesktopPromptResponse>();
      final ok = DesktopPromptResponse.fromJson(const {
        'status': 'ok',
      }, method: 'clarify.respond');
      gateway.onRespondToClarify = (requestId, answer, {questionId}) {
        calls.add(questionId);
        return firstAck.future;
      };
      gateway.emit('clarify.request', const {
        'request_id': 'batch-runtime-switch',
        'questions': [
          {
            'qid': 'q0',
            'question': '¿A?',
            'choices': ['A0'],
          },
          {
            'qid': 'q1',
            'question': '¿B?',
            'choices': ['B0'],
          },
        ],
      });
      await _waitUntil(() => chat.pendingInteractivePrompt != null);
      final entry = chat.pendingInteractivePrompt!;
      final operation = chat.respondToClarifyBatch(entry.key, const {
        'q0': 'A0',
        'q1': 'B0',
      });

      try {
        await _waitUntil(() => calls.isNotEmpty);
        gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-replaced',
          storedSessionId: 'stored-interactive',
          created: false,
        );
        await chat.loadMessages();
        expect(
          chat.interactivePrompts[entry.key]?.status,
          InteractivePromptStatus.expired,
        );
        firstAck.complete(ok);

        await operation.timeout(const Duration(seconds: 2));
      } finally {
        if (!firstAck.isCompleted) firstAck.complete(ok);
      }

      expect(calls, ['q0']);
      expect(
        chat.interactivePrompts[entry.key]?.status,
        InteractivePromptStatus.expired,
      );
    },
  );

  test(
    'runtime retirement fences old prompts and submissions before callbacks',
    () async {
      final gateway = _InteractiveGateway();
      late ActiveChat chat;
      var reenterOnRetirement = false;
      var reentryStarted = false;
      Future<DesktopPromptResponse>? reentrantOperation;
      final reentrantKey = InteractivePromptKey(
        runtimeSessionId: 'runtime-retired',
        requestId: 'batch-reentrant',
      );
      chat = await _start(
        gateway,
        onEvent: (event) {
          if (!reenterOnRetirement ||
              event != ActiveChatEvent.interactiveRequest ||
              reentryStarted) {
            return;
          }
          reentryStarted = true;
          reentrantOperation = chat.respondToClarifyBatch(reentrantKey, const {
            'q0': 'B0',
          });
          reentrantOperation!.ignore();
          gateway.emit('clarify.request', const {
            'request_id': 'legacy-during-retirement',
            'question': '¿No debe revivir?',
          }, sessionId: 'runtime-retired');
          gateway.emit('clarify.request', const {
            'request_id': 'batch-during-retirement',
            'questions': [
              {'qid': 'q0', 'question': '¿Tampoco este batch?'},
            ],
          }, sessionId: 'runtime-retired');
        },
      );
      addTearDown(chat.dispose);

      final firstAck = Completer<DesktopPromptResponse>();
      final reentrantAck = Completer<DesktopPromptResponse>();
      final ok = DesktopPromptResponse.fromJson(const {
        'status': 'ok',
      }, method: 'clarify.respond');
      gateway.onRespondToClarify = (requestId, answer, {questionId}) {
        if (requestId == 'batch-old') return firstAck.future;
        if (requestId == 'batch-reentrant') return reentrantAck.future;
        return Future.value(ok);
      };

      final otherBatchKey = InteractivePromptKey(
        runtimeSessionId: 'runtime-interactive',
        requestId: 'batch-reentrant',
      );
      final otherSecretKey = InteractivePromptKey(
        runtimeSessionId: 'runtime-interactive',
        requestId: 'secret-kept',
      );
      final otherSudoKey = InteractivePromptKey(
        runtimeSessionId: 'runtime-interactive',
        requestId: 'sudo-kept',
      );
      final tombstoneKey = InteractivePromptKey(
        runtimeSessionId: 'runtime-interactive',
        requestId: 'terminal-tombstone',
      );
      gateway.emit('clarify.request', const {
        'request_id': 'batch-reentrant',
        'questions': [
          {'qid': 'q0', 'question': '¿Otro runtime?'},
        ],
      });
      gateway.emit('secret.request', const {
        'request_id': 'secret-kept',
        'env_var': 'KEPT_SECRET',
        'prompt': 'Otro secreto',
      });
      gateway.emit('sudo.request', const {'request_id': 'sudo-kept'});
      gateway.emit('terminal.read.request', const {
        'request_id': 'terminal-tombstone',
        'start': 0,
        'count': 1,
      });
      await _waitUntil(
        () =>
            chat.interactivePrompts[tombstoneKey]?.status ==
            InteractivePromptStatus.responded,
        'terminal tombstone was not recorded',
      );

      gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-retired',
        storedSessionId: 'stored-interactive',
        created: false,
      );
      await chat.loadMessages();

      final oldBatchKey = InteractivePromptKey(
        runtimeSessionId: 'runtime-retired',
        requestId: 'batch-old',
      );
      final legacyKey = InteractivePromptKey(
        runtimeSessionId: 'runtime-retired',
        requestId: 'clarify-kept',
      );
      final secretKey = InteractivePromptKey(
        runtimeSessionId: 'runtime-retired',
        requestId: 'secret-kept',
      );
      final sudoKey = InteractivePromptKey(
        runtimeSessionId: 'runtime-retired',
        requestId: 'sudo-kept',
      );
      gateway.emit('clarify.request', const {
        'request_id': 'batch-old',
        'questions': [
          {'qid': 'q0', 'question': '¿Antiguo?'},
        ],
      }, sessionId: 'runtime-retired');
      gateway.emit('clarify.request', const {
        'request_id': 'batch-reentrant',
        'questions': [
          {'qid': 'q0', 'question': '¿Reentrante?'},
        ],
      }, sessionId: 'runtime-retired');
      gateway.emit('clarify.request', const {
        'request_id': 'clarify-kept',
        'question': '¿Legacy?',
      }, sessionId: 'runtime-retired');
      gateway.emit('secret.request', const {
        'request_id': 'secret-kept',
        'env_var': 'RETIRED_SECRET',
        'prompt': 'Secreto retirado',
      }, sessionId: 'runtime-retired');
      gateway.emit('sudo.request', const {
        'request_id': 'sudo-kept',
      }, sessionId: 'runtime-retired');
      for (final key in [
        oldBatchKey,
        reentrantKey,
        legacyKey,
        secretKey,
        sudoKey,
      ]) {
        await _waitUntil(
          () => chat.interactivePrompts[key] != null,
          'prompt was not recorded: $key',
        );
      }
      final oldOperation = chat.respondToClarifyBatch(oldBatchKey, const {
        'q0': 'A0',
      });
      await _waitUntil(
        () =>
            chat.interactivePrompts[oldBatchKey]?.status ==
            InteractivePromptStatus.responding,
        'old batch did not start responding',
      );

      reenterOnRetirement = true;
      gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-current',
        storedSessionId: 'stored-interactive',
        created: false,
      );
      try {
        await chat.loadMessages();

        expect(
          chat.interactivePrompts[oldBatchKey]?.status,
          InteractivePromptStatus.expired,
        );
        expect(
          chat.interactivePrompts[reentrantKey]?.status,
          InteractivePromptStatus.expired,
        );
        for (final requestId in [
          'legacy-during-retirement',
          'batch-during-retirement',
        ]) {
          expect(
            chat.interactivePrompts[InteractivePromptKey(
              runtimeSessionId: 'runtime-retired',
              requestId: requestId,
            )],
            isNull,
          );
        }
        for (final key in [legacyKey, secretKey, sudoKey]) {
          expect(
            chat.interactivePrompts[key]?.status,
            InteractivePromptStatus.expired,
            reason: key.toString(),
          );
        }
        expect(
          chat.interactivePrompts[tombstoneKey]?.status,
          InteractivePromptStatus.responded,
        );
        for (final key in [otherBatchKey, otherSecretKey, otherSudoKey]) {
          expect(
            chat.interactivePrompts[key]?.status,
            InteractivePromptStatus.expired,
            reason: key.toString(),
          );
        }
      } finally {
        if (!firstAck.isCompleted) firstAck.complete(ok);
        if (!reentrantAck.isCompleted) reentrantAck.complete(ok);
        await oldOperation;
        if (reentrantOperation case final operation?) {
          await expectLater(operation, throwsA(isA<StateError>()));
        }
      }
    },
  );

  for (final lateStatus in ['ok', 'expired']) {
    test(
      'late $lateStatus reconciles only the retired runtime composite key',
      () async {
        final gateway = _InteractiveGateway();
        final chat = await _start(gateway);
        addTearDown(chat.dispose);
        final lateAck = Completer<DesktopPromptResponse>();
        gateway.onRespondToClarify = (requestId, answer, {questionId}) {
          return lateAck.future;
        };

        gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-old',
          storedSessionId: 'stored-interactive',
          created: false,
        );
        await chat.loadMessages();
        gateway.emit('clarify.request', const {
          'request_id': 'shared-request',
          'question': '¿La misma pregunta?',
        }, sessionId: 'runtime-old');
        await _waitUntil(() => chat.pendingInteractivePrompt != null);
        final oldKey = chat.pendingInteractivePrompt!.key;
        final oldOperation = chat.respondToClarify(oldKey, 'old answer');
        await _waitUntil(
          () =>
              chat.interactivePrompts[oldKey]?.status ==
              InteractivePromptStatus.responding,
        );

        gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-successor',
          storedSessionId: 'stored-interactive',
          created: false,
          pendingClarifyProvided: true,
          pendingClarify: {
            'request_id': 'shared-request',
            'question': '¿La misma pregunta?',
          },
        );
        await chat.loadMessages();
        final successorKey = InteractivePromptKey(
          runtimeSessionId: 'runtime-successor',
          requestId: 'shared-request',
        );
        expect(
          chat.interactivePrompts[successorKey]?.status,
          InteractivePromptStatus.pending,
        );

        lateAck.complete(
          DesktopPromptResponse.fromJson(
            {'status': lateStatus},
            method: 'clarify.respond',
            allowExpired: true,
          ),
        );
        await oldOperation;

        expect(
          chat.interactivePrompts[oldKey]?.status,
          InteractivePromptStatus.expired,
        );
        expect(
          chat.interactivePrompts[successorKey]?.status,
          InteractivePromptStatus.pending,
        );
      },
    );
  }

  test(
    'successor snapshot rearms reused request and keeps reentrant callbacks',
    () async {
      final gateway = _InteractiveGateway();
      late ActiveChat chat;
      final successorKey = InteractivePromptKey(
        runtimeSessionId: 'runtime-successor',
        requestId: 'shared-request',
      );
      var reenterSuccessor = false;
      chat = await _start(
        gateway,
        onEvent: (event) {
          if (!reenterSuccessor ||
              event != ActiveChatEvent.interactiveRequest ||
              chat.interactivePrompts[successorKey]?.status !=
                  InteractivePromptStatus.pending) {
            return;
          }
          reenterSuccessor = false;
          gateway.emit('clarify.request', const {
            'request_id': 'successor-reentrant',
            'question': '¿Callback sucesor?',
          }, sessionId: 'runtime-successor');
        },
      );
      addTearDown(chat.dispose);

      gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-old',
        storedSessionId: 'stored-interactive',
        created: false,
      );
      await chat.loadMessages();
      gateway.emit('clarify.request', const {
        'request_id': 'shared-request',
        'question': '¿La misma pregunta?',
      }, sessionId: 'runtime-old');
      await _waitUntil(() => chat.pendingInteractivePrompt != null);
      final oldKey = chat.pendingInteractivePrompt!.key;

      reenterSuccessor = true;
      gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-successor',
        storedSessionId: 'stored-interactive',
        created: false,
        pendingClarifyProvided: true,
        pendingClarify: {
          'request_id': 'shared-request',
          'question': '¿La misma pregunta?',
        },
      );
      await chat.loadMessages();

      final reentrantKey = InteractivePromptKey(
        runtimeSessionId: 'runtime-successor',
        requestId: 'successor-reentrant',
      );
      await _waitUntil(
        () => chat.interactivePrompts[reentrantKey] != null,
        'successor reentrant callback was dropped',
      );
      expect(
        chat.interactivePrompts[oldKey]?.status,
        InteractivePromptStatus.expired,
      );
      expect(
        chat.interactivePrompts[successorKey]?.status,
        InteractivePromptStatus.pending,
      );
      expect(
        chat.interactivePrompts[reentrantKey]?.status,
        InteractivePromptStatus.pending,
      );
    },
  );

  test(
    'fully locked batch completes without sending or dereferencing a null ACK',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      final calls = <String?>[];
      gateway.onRespondToClarify = (requestId, answer, {questionId}) async {
        calls.add(questionId);
        return DesktopPromptResponse.fromJson(const {
          'status': 'ok',
        }, method: 'clarify.respond');
      };
      gateway.emit('clarify.request', const {
        'request_id': 'batch-fully-locked',
        'questions': [
          {
            'qid': 'q0',
            'question': '¿A?',
            'choices': ['A0'],
          },
        ],
        'answers': {'q0': 'A0'},
      });
      await _waitUntil(() => chat.pendingInteractivePrompt != null);
      final entry = chat.pendingInteractivePrompt!;

      final result = await chat.respondToClarifyBatch(entry.key, const {
        'q0': 'A0',
      });

      expect(result.isExpired, isFalse);
      expect(calls, isEmpty);
      expect(chat.pendingInteractivePrompt, isNull);
    },
  );

  test(
    'matching authoritative lock for the in-flight qid completes without resend',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      final first = Completer<DesktopPromptResponse>();
      gateway.onRespondToClarify = (requestId, answer, {questionId}) {
        return first.future;
      };
      const pending = {
        'request_id': 'batch-current-lock-same',
        'questions': [
          {
            'qid': 'q0',
            'question': '¿A?',
            'choices': ['A0'],
          },
        ],
      };
      gateway.emit('clarify.request', pending);
      await _waitUntil(() => chat.pendingInteractivePrompt != null);
      final entry = chat.pendingInteractivePrompt!;
      final operation = chat.respondToClarifyBatch(entry.key, const {
        'q0': 'A0',
      });
      await _waitUntil(
        () =>
            chat.pendingInteractivePrompt?.status ==
            InteractivePromptStatus.responding,
      );
      gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-interactive',
        storedSessionId: 'stored-interactive',
        created: false,
        pendingClarifyProvided: true,
        pendingClarify: {
          ...pending,
          'answers': {'q0': 'A0'},
        },
      );
      await chat.loadMessages();
      first.complete(
        DesktopPromptResponse.fromJson(const {
          'status': 'ok',
        }, method: 'clarify.respond'),
      );

      await operation;
      expect(chat.pendingInteractivePrompt, isNull);
    },
  );

  test(
    'conflicting authoritative lock for the in-flight qid fails closed',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      final first = Completer<DesktopPromptResponse>();
      gateway.onRespondToClarify = (requestId, answer, {questionId}) {
        return first.future;
      };
      const pending = {
        'request_id': 'batch-current-lock-conflict',
        'questions': [
          {
            'qid': 'q0',
            'question': '¿A?',
            'choices': ['A0', 'A1'],
          },
        ],
      };
      gateway.emit('clarify.request', pending);
      await _waitUntil(() => chat.pendingInteractivePrompt != null);
      final entry = chat.pendingInteractivePrompt!;
      final operation = chat.respondToClarifyBatch(entry.key, const {
        'q0': 'A0',
      });
      await _waitUntil(
        () =>
            chat.pendingInteractivePrompt?.status ==
            InteractivePromptStatus.responding,
      );
      gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-interactive',
        storedSessionId: 'stored-interactive',
        created: false,
        pendingClarifyProvided: true,
        pendingClarify: {
          ...pending,
          'answers': {'q0': 'A1'},
        },
      );
      await chat.loadMessages();
      first.complete(
        DesktopPromptResponse.fromJson(const {
          'status': 'ok',
        }, method: 'clarify.respond'),
      );

      await expectLater(operation, throwsA(isA<StateError>()));
      expect(
        chat.interactivePrompts[entry.key]?.status,
        InteractivePromptStatus.expired,
      );
    },
  );

  test('legacy clarify rejects the batch response API', () async {
    final gateway = _InteractiveGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    gateway.emit('clarify.request', const {
      'request_id': 'legacy-cross-api',
      'question': '¿Continuar?',
      'choices': ['Sí', 'No'],
    });
    await _waitUntil(() => chat.pendingInteractivePrompt != null);
    final entry = chat.pendingInteractivePrompt!;

    await expectLater(
      chat.respondToClarifyBatch(entry.key, const {'q0': 'Sí'}),
      throwsA(isA<StateError>()),
    );
    expect(entry.status, InteractivePromptStatus.pending);
  });

  test('batch clarify rejects the legacy response API', () async {
    final gateway = _InteractiveGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    gateway.emit('clarify.request', const {
      'request_id': 'batch-cross-api',
      'questions': [
        {
          'qid': 'q0',
          'question': '¿A?',
          'choices': ['A0'],
        },
      ],
    });
    await _waitUntil(() => chat.pendingInteractivePrompt != null);
    final entry = chat.pendingInteractivePrompt!;

    await expectLater(
      chat.respondToClarify(entry.key, 'A0'),
      throwsA(isA<StateError>()),
    );
    expect(entry.status, InteractivePromptStatus.pending);
  });

  test(
    'malformed authoritative snapshot after ambiguous ACK expires only clarify',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      gateway.onRespondToClarify = (requestId, answer, {questionId}) async {
        throw StateError('ack lost');
      };
      gateway.emit('secret.request', const {
        'request_id': 'secret-stays-pending',
        'env_var': 'TEST_SECRET',
        'prompt': 'Secret',
      });
      gateway.emit('clarify.request', const {
        'request_id': 'batch-malformed-resume',
        'questions': [
          {'qid': 'q0', 'question': '¿A?'},
        ],
      });
      await _waitUntil(
        () => chat.interactivePrompts.entries.values.length == 2,
      );
      final clarify = chat.interactivePrompts.entries.values.singleWhere(
        (entry) => entry.request is ClarifyPromptRequest,
      );
      gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-interactive',
        storedSessionId: 'stored-interactive',
        created: false,
        pendingClarifyProvided: true,
        pendingClarify: {
          'request_id': 'batch-malformed-resume',
          'questions': 'not-a-list',
        },
      );

      await expectLater(
        chat.respondToClarifyBatch(clarify.key, const {'q0': 'A0'}),
        throwsA(isA<StateError>()),
      );

      expect(
        chat.interactivePrompts[clarify.key]?.status,
        InteractivePromptStatus.expired,
      );
      expect(
        chat.interactivePrompts.entries.values
            .singleWhere((entry) => entry.request is SecretPromptRequest)
            .status,
        InteractivePromptStatus.pending,
      );
    },
  );

  test(
    'legacy malformed ACK reconciles authoritatively before retry',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      final resumesBefore = gateway.lifecycleResumes;
      gateway.onRespondToClarify = (requestId, answer, {questionId}) async {
        throw const TuiGatewayRpcError(
          'clarify.respond',
          'invalid response payload',
        );
      };
      const pending = {
        'request_id': 'legacy-malformed-ack',
        'question': '¿Continuar?',
        'choices': ['Sí', 'No'],
      };
      gateway.emit('clarify.request', pending);
      await _waitUntil(() => chat.pendingInteractivePrompt != null);
      final entry = chat.pendingInteractivePrompt!;
      gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-interactive',
        storedSessionId: 'stored-interactive',
        created: false,
        pendingClarifyProvided: true,
        pendingClarify: pending,
      );

      await expectLater(
        chat.respondToClarify(entry.key, 'Sí'),
        throwsA(isA<TuiGatewayRpcError>()),
      );

      expect(gateway.lifecycleResumes, resumesBefore + 1);
      expect(
        chat.interactivePrompts[entry.key]?.status,
        InteractivePromptStatus.pending,
      );
    },
  );

  test('malformed ACK requires authoritative resume before retry', () async {
    final gateway = _InteractiveGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    final resumesBefore = gateway.lifecycleResumes;
    gateway.onRespondToClarify = (requestId, answer, {questionId}) async {
      throw const TuiGatewayRpcError(
        'clarify.respond',
        'invalid response payload',
      );
    };
    gateway.emit('clarify.request', const {
      'request_id': 'batch-malformed-ack',
      'questions': [
        {
          'qid': 'q0',
          'question': '¿A?',
          'choices': ['A0'],
        },
        {
          'qid': 'q1',
          'question': '¿B?',
          'choices': ['B0'],
        },
      ],
    });
    await _waitUntil(() => chat.pendingInteractivePrompt != null);
    final entry = chat.pendingInteractivePrompt!;
    gateway.nextResumeSnapshot = const DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-interactive',
      storedSessionId: 'stored-interactive',
      created: false,
      pendingClarifyProvided: true,
      pendingClarify: {
        'request_id': 'batch-malformed-ack',
        'questions': [
          {
            'qid': 'q0',
            'question': '¿A?',
            'choices': ['A0'],
          },
          {
            'qid': 'q1',
            'question': '¿B?',
            'choices': ['B0'],
          },
        ],
        'answers': {'q0': 'A0'},
      },
    );

    await expectLater(
      chat.respondToClarifyBatch(entry.key, {'q0': 'A0', 'q1': 'B0'}),
      throwsA(isA<TuiGatewayRpcError>()),
    );

    expect(gateway.lifecycleResumes, resumesBefore + 1);
    final request =
        chat.pendingInteractivePrompt!.request as ClarifyPromptRequest;
    expect(request.lockedAnswers, {'q0': 'A0'});
  });

  test(
    'dispose while a batch answer is in flight never sends the next qid',
    () async {
      final gateway = _InteractiveGateway();
      final chat = await _start(gateway);
      final calls = <String?>[];
      final first = Completer<DesktopPromptResponse>();
      gateway.onRespondToClarify = (requestId, answer, {questionId}) {
        calls.add(questionId);
        return first.future;
      };
      gateway.emit('clarify.request', const {
        'request_id': 'batch-dispose',
        'questions': [
          {
            'qid': 'q0',
            'question': '¿A?',
            'choices': ['A0'],
          },
          {
            'qid': 'q1',
            'question': '¿B?',
            'choices': ['B0'],
          },
        ],
      });
      await _waitUntil(() => chat.pendingInteractivePrompt != null);

      final operation = chat.respondToClarifyBatch(
        chat.pendingInteractivePrompt!.key,
        {'q0': 'A0', 'q1': 'B0'},
      );
      await _waitUntil(() => calls.isNotEmpty);
      chat.dispose();
      first.complete(
        DesktopPromptResponse.fromJson(const {
          'status': 'ok',
        }, method: 'clarify.respond'),
      );
      await operation;

      expect(calls, ['q0']);
    },
  );

  test('concurrent respondToClarifyBatch calls are serialized', () async {
    final gateway = _InteractiveGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    final calls = <({String? questionId, String answer})>[];
    final completers = <Completer<DesktopPromptResponse>>[];
    gateway.onRespondToClarify = (requestId, answer, {questionId}) async {
      calls.add((questionId: questionId, answer: answer));
      final completer = Completer<DesktopPromptResponse>();
      completers.add(completer);
      return completer.future;
    };

    gateway.emit('clarify.request', const {
      'request_id': 'batch-concurrent',
      'questions': [
        {
          'qid': 'q0',
          'question': '¿A?',
          'choices': ['A0'],
        },
      ],
    });
    await _waitUntil(() => chat.pendingInteractivePrompt != null);

    final entry = chat.pendingInteractivePrompt!;
    final first = chat.respondToClarifyBatch(entry.key, {'q0': 'A0'});
    final second = chat.respondToClarifyBatch(entry.key, {'q0': 'A0'});

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls, hasLength(1));

    completers.first.complete(
      DesktopPromptResponse.fromJson(const {
        'status': 'ok',
      }, method: 'clarify.respond'),
    );
    await expectLater(first, completes);
    await expectLater(second, completes);
  });
}
