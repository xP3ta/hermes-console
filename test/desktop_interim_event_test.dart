import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_fence_storage.dart';

class _InterimGateway implements HermesDesktopGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  bool _connected = false;

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
    runtimeSessionId: 'runtime-interim',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: 'runtime-interim',
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    _connected = false;
    if (!_events.isClosed) await _events.close();
  }
}

class _InterimFixture {
  _InterimFixture(this.chat, this.gateway, this.events, this.subscription);

  final ActiveChat chat;
  final _InterimGateway gateway;
  final List<ActiveChatEvent> events;
  final StreamSubscription<ActiveChatEvent> subscription;

  Future<void> dispose() async {
    await subscription.cancel();
    chat.dispose();
    await Future<void>.delayed(Duration.zero);
  }
}

Future<_InterimFixture> _startChat() async {
  final gateway = _InterimGateway();
  final chat = ActiveChat(
    compressionFenceStore: testCompressionFenceStore(),
    connection: SavedConnection(
      id: 'conn-interim',
      label: 'Interim contract',
      host: 'example.invalid',
      port: 443,
      apiKey: 'test-only',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-interim',
    sessionTitle: 'Interim contract',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-only',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
    terminalReconcileBudget: Duration.zero,
  );
  final events = <ActiveChatEvent>[];
  final subscription = chat.changes.listen(events.add);

  final accepted = await chat.send(
    fullText: 'prueba de interim',
    model: 'hermes-agent',
    history: const [],
  );
  expect(accepted, isTrue);
  events.clear();
  return _InterimFixture(chat, gateway, events, subscription);
}

List<Map<String, dynamic>> _assistantMessages(ActiveChat chat) => chat.messages
    .where((message) => message['role'] == 'assistant')
    .toList(growable: false);

List<Map<String, dynamic>> _internalAssistantMessages(ActiveChat chat) => chat
    .internalMessagesForTesting
    .where((message) => message['role'] == 'assistant')
    .toList(growable: false);

List<String> _nonEmptyAssistantTexts(ActiveChat chat) =>
    _assistantMessages(chat)
        .map((message) => (message['content'] ?? '').toString())
        .where((text) => text.isNotEmpty)
        .toList(growable: false);

Future<void> _emitAndSettle(
  _InterimFixture fixture,
  String type,
  Map<String, dynamic> payload,
) async {
  final visualUpdate = fixture.chat.changes.firstWhere(
    (event) => event == ActiveChatEvent.toolProgress,
  );
  fixture.gateway.emit(type, payload);
  await visualUpdate.timeout(const Duration(seconds: 1));
}

Future<void> _complete(
  _InterimFixture fixture,
  Map<String, dynamic> payload, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final done = fixture.chat.changes.firstWhere(
    (event) => event == ActiveChatEvent.done,
  );
  fixture.gateway.emit('message.complete', payload);
  await done.timeout(timeout);
}

Future<void> _failComplete(
  _InterimFixture fixture,
  Map<String, dynamic> payload, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final failed = fixture.chat.changes.firstWhere(
    (event) => event == ActiveChatEvent.error,
  );
  fixture.gateway.emit('message.complete', payload);
  await failed.timeout(timeout);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Hermes Desktop 0.19 — message.interim', () {
    test('ignora payloads vacíos o con text malformado', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);
      final before = fixture.chat.messages
          .map((message) => Map<String, dynamic>.from(message))
          .toList(growable: false);

      fixture.gateway.emit('message.interim');
      fixture.gateway.emit('message.interim', const {'text': ''});
      fixture.gateway.emit('message.interim', const {'text': '   '});
      fixture.gateway.emit('message.interim', const {'text': 19});
      await Future<void>.delayed(Duration.zero);

      expect(fixture.chat.messages, equals(before));
      expect(fixture.chat.state, ChatPipelineState.waiting);
      expect(fixture.events, isEmpty);
    });

    test('message.delta ignora text no String', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);

      fixture.gateway.emit('message.delta', const {'text': 19});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fixture.chat.assistantContent, isEmpty);
      expect(fixture.chat.assistantNarrationContent, isEmpty);
      expect(fixture.events, isNot(contains(ActiveChatEvent.token)));
      expect(fixture.chat.messages.toString(), isNot(contains('19')));
    });

    test('message.complete ignora text no String', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);

      fixture.gateway.emit('message.complete', const {
        'text': {'secret': 'PRIVATE_MALFORMED_COMPLETE'},
      });
      await Future<void>.delayed(Duration.zero);

      expect(fixture.events, isNot(contains(ActiveChatEvent.done)));

      expect(fixture.chat.assistantContent, isEmpty);
      expect(fixture.chat.assistantNarrationContent, isEmpty);
      expect(
        fixture.chat.messages.toString(),
        isNot(contains('PRIVATE_MALFORMED_COMPLETE')),
      );
    });

    test('es visual y no termina el turno', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);

      await _emitAndSettle(fixture, 'message.interim', const {
        'text': 'Estoy revisando el proyecto.',
      });

      expect(fixture.chat.state, ChatPipelineState.executing);
      expect(fixture.chat.isStreaming, isTrue);
      expect(_nonEmptyAssistantTexts(fixture.chat), [
        'Estoy revisando el proyecto.',
      ]);
      expect(fixture.chat.messages.first['_pipeline'], isTrue);
      expect(
        fixture.events,
        isNot(
          contains(
            anyOf(
              ActiveChatEvent.done,
              ActiveChatEvent.error,
              ActiveChatEvent.cancelled,
            ),
          ),
        ),
      );
    });

    test('nunca emite ActiveChatEvent.token por un interim', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);

      await _emitAndSettle(fixture, 'message.interim', const {
        'text': 'Primer avance.',
      });
      await _emitAndSettle(fixture, 'message.interim', const {
        'text': 'Segundo avance.',
      });

      expect(fixture.events, isNot(contains(ActiveChatEvent.token)));
      expect(
        fixture.events.where((event) => event == ActiveChatEvent.toolProgress),
        hasLength(2),
      );
    });

    test('classifiers privados no entran en chat ni Voz', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);

      for (final payload in const <Map<String, dynamic>>[
        {'text': 'ANALYSIS PRIVADO', 'channel': 'analysis'},
        {'text': 'INTERNAL PRIVADO', 'channel': 'internal'},
        {'text': 'DEBUG PRIVADO', 'kind': 'debug'},
        {'text': 'TRACE PRIVADO', 'content_type': 'trace'},
        {'text': 'STDOUT PRIVADO', 'channel': 'stdout'},
        {'text': 'STDERR PRIVADO', 'channel': 'stderr'},
        {'text': 'PREVIEW PRIVADO', 'channel': 'preview'},
        {'text': 'NULL PRIVADO', 'channel': null},
        {'text': 'EMPTY PRIVADO', 'kind': ''},
        {'text': 'SPACE PRIVADO', 'content_type': '   '},
        {'text': 'HIDDEN PRIVADO', 'hidden': true},
        {'text': 'REASONING PRIVADO', 'reasoning': true},
      ]) {
        fixture.gateway.emit('message.interim', payload);
      }
      await Future<void>.delayed(Duration.zero);

      expect(fixture.chat.assistantNarrationContent, isEmpty);
      expect(fixture.chat.assistantPublicCommentary, isEmpty);
      final visible = fixture.chat.messages
          .map((message) => message['content'])
          .join('\n');
      for (final marker in const [
        'ANALYSIS PRIVADO',
        'INTERNAL PRIVADO',
        'DEBUG PRIVADO',
        'TRACE PRIVADO',
        'STDOUT PRIVADO',
        'STDERR PRIVADO',
        'PREVIEW PRIVADO',
        'NULL PRIVADO',
        'EMPTY PRIVADO',
        'SPACE PRIVADO',
        'HIDDEN PRIVADO',
        'REASONING PRIVADO',
      ]) {
        expect(visible, isNot(contains(marker)), reason: marker);
      }

      await _emitAndSettle(fixture, 'message.interim', const {
        'text': 'Comentario público sin classifier.',
      });
      expect(
        fixture.chat.assistantNarrationContent,
        'Comentario público sin classifier.',
      );
      expect(
        fixture.chat.assistantPublicCommentary,
        'Comentario público sin classifier.',
      );
    });

    test('reasoning partido entre deltas nunca se publica ni narra', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);

      fixture.gateway.emit('message.delta', const {'text': '<thi'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fixture.chat.assistantContent, isEmpty);
      expect(fixture.chat.assistantNarrationContent, isEmpty);
      expect(fixture.events, isNot(contains(ActiveChatEvent.token)));

      fixture.gateway.emit('message.delta', const {
        'text': 'nk>PRIVATE_SPLIT_REASONING',
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fixture.chat.assistantContent, isEmpty);
      expect(fixture.chat.assistantNarrationContent, isEmpty);

      final token = fixture.chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.token,
      );
      fixture.gateway.emit('message.delta', const {
        'text': '</think>PUBLIC ANSWER',
      });
      await token.timeout(const Duration(seconds: 1));

      expect(fixture.chat.assistantContent, 'PUBLIC ANSWER');
      expect(fixture.chat.assistantNarrationContent, 'PUBLIC ANSWER');
      expect(
        fixture.chat.messages.toString(),
        isNot(contains('PRIVATE_SPLIT_REASONING')),
      );
    });

    test(
      'ambos terminales proyectan la causa oficial segura y fallan',
      () async {
        for (final terminal in <({String type, Map<String, dynamic> payload})>[
          (
            type: 'message.complete',
            payload: const {
              'status': 'error',
              'message': 'El modelo solicitado no está disponible.',
            },
          ),
          (
            type: 'error',
            payload: const {
              'message': 'El modelo solicitado no está disponible.',
            },
          ),
        ]) {
          final fixture = await _startChat();
          addTearDown(fixture.dispose);
          final failed = fixture.chat.changes.firstWhere(
            (event) => event == ActiveChatEvent.error,
          );

          fixture.gateway.emit(terminal.type, terminal.payload);
          await failed.timeout(const Duration(seconds: 1));

          expect(fixture.chat.state, ChatPipelineState.failed);
          expect(fixture.events, contains(ActiveChatEvent.error));
          expect(fixture.events, isNot(contains(ActiveChatEvent.done)));
          final error = fixture.chat.messages.firstWhere(
            (message) => message['role'] == 'assistant_error',
          );
          expect(
            error['content'],
            'No se pudo completar la respuesta: '
            'El modelo solicitado no está disponible.',
          );
        }
      },
    );

    test(
      'ambos terminales rechazan secretos rutas y payload lateral',
      () async {
        for (final terminal in <({String type, Map<String, dynamic> payload})>[
          (
            type: 'message.complete',
            payload: const {
              'status': 'error',
              'message': 'Falló en /home/alice/private/config.yaml',
              'text': 'PRIVATE_TERMINAL_TEXT',
              'error': 'PRIVATE_STRUCTURED_ERROR',
              'billing': {'raw': 'PRIVATE_BILLING'},
            },
          ),
          (
            type: 'error',
            payload: const {
              'message': 'Authorization: Bearer PRIVATE_TOKEN_VALUE',
              'cause': {'raw': 'PRIVATE_CAUSE'},
            },
          ),
        ]) {
          final fixture = await _startChat();
          addTearDown(fixture.dispose);
          final failed = fixture.chat.changes.firstWhere(
            (event) => event == ActiveChatEvent.error,
          );

          fixture.gateway.emit(terminal.type, terminal.payload);
          await failed.timeout(const Duration(seconds: 1));

          expect(fixture.chat.state, ChatPipelineState.failed);
          final serialized = fixture.chat.messages.toString();
          expect(serialized, isNot(contains('PRIVATE_')));
          expect(serialized, isNot(contains('/home/alice')));
          expect(serialized, isNot(contains('Authorization')));
          final error = fixture.chat.messages.firstWhere(
            (message) => message['role'] == 'assistant_error',
          );
          expect(
            error['content'],
            'No se pudo completar la respuesta. Inténtalo de nuevo.',
          );
        }
      },
    );

    test(
      'ambos terminales nunca emiten un secreto partido por el acote',
      () async {
        // Prosa corta y sin palabra clave: nada en el prefijo dispara la regla
        // de opacidad, así que el único riesgo es el propio acote cortando el
        // secreto y dejando un fragmento demasiado corto para `{24,}`.
        final filler = List.filled(34, 'el fallo').join(' ').substring(0, 170);
        const secret = 'AKIAIOSFODNN7EXAMPLEKEYQ1234567890abcdef';
        for (final terminal in <({String type, Map<String, dynamic> payload})>[
          (
            type: 'message.complete',
            payload: {'status': 'error', 'message': '$filler $secret'},
          ),
          (type: 'error', payload: {'message': '$filler $secret'}),
        ]) {
          final fixture = await _startChat();
          addTearDown(fixture.dispose);
          final failed = fixture.chat.changes.firstWhere(
            (event) => event == ActiveChatEvent.error,
          );

          fixture.gateway.emit(terminal.type, terminal.payload);
          await failed.timeout(const Duration(seconds: 1));

          expect(fixture.chat.state, ChatPipelineState.failed);
          final error = fixture.chat.messages.firstWhere(
            (message) => message['role'] == 'assistant_error',
          );
          final content = error['content'].toString();
          // Ni el secreto entero ni ningún prefijo suyo puede sobrevivir.
          expect(content, isNot(contains(secret)));
          for (var length = 4; length <= secret.length; length++) {
            expect(
              content,
              isNot(contains(secret.substring(0, length))),
              reason: 'fragmento de $length caracteres del secreto proyectado',
            );
          }
        }
      },
    );

    test(
      'el final público ignora reasoning sidecar sin perder su texto',
      () async {
        final fixture = await _startChat();
        addTearDown(fixture.dispose);

        await _complete(fixture, const {
          'text': 'Respuesta pública final.',
          'reasoning': 'RAZONAMIENTO SIDECAR PRIVADO',
        });

        expect(
          fixture.chat.assistantNarrationContent,
          'Respuesta pública final.',
        );
        expect(fixture.chat.assistantContent, 'Respuesta pública final.');
        expect(
          fixture.chat.messages.map((message) => message['content']).join('\n'),
          isNot(contains('RAZONAMIENTO SIDECAR PRIVADO')),
        );
      },
    );

    test('deltas y final clasificados no entran en chat ni Voz', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);

      fixture.gateway.emit('message.delta', const {
        'text': 'ANALYSIS DELTA PRIVADO',
        'channel': 'analysis',
      });
      await Future<void>.delayed(Duration.zero);
      expect(fixture.events, isNot(contains(ActiveChatEvent.token)));
      expect(fixture.chat.assistantNarrationContent, isEmpty);
      expect(
        fixture.chat.assistantContent,
        isNot(contains('ANALYSIS DELTA PRIVADO')),
      );

      fixture.gateway.emit('message.complete', const {
        'text': 'TRAZA INTERNA FINAL',
        'channel': 'trace',
      });
      await Future<void>.delayed(Duration.zero);
      expect(fixture.events, isNot(contains(ActiveChatEvent.done)));

      expect(fixture.chat.assistantNarrationContent, isEmpty);
      expect(fixture.chat.assistantContent, isEmpty);
      expect(
        fixture.chat.messages.map((message) => message['content']).join('\n'),
        isNot(contains('TRAZA INTERNA FINAL')),
      );
    });

    test(
      'un final idéntico sin response_previewed se asienta en el mismo segmento',
      () async {
        final fixture = await _startChat();
        addTearDown(fixture.dispose);

        await _emitAndSettle(fixture, 'message.interim', const {
          'text': 'Resultado listo.',
        });
        final interimKey = fixture.chat.internalMessagesForTesting.firstWhere(
          (message) => message['_desktopInterim'] == true,
        )['_desktopInterimKey'];
        await _complete(fixture, const {'text': 'Resultado listo.'});

        // Paridad con Desktop (#63679): continuidad de prefijo basta para
        // saber que es el MISMO mensaje; duplicarlo en una segunda burbuja
        // pintaba el parcial y el final limpio a la vez.
        final assistants = _internalAssistantMessages(fixture.chat);
        expect(_nonEmptyAssistantTexts(fixture.chat), ['Resultado listo.']);
        expect(assistants, hasLength(1));
        expect(assistants.single['_desktopInterimKey'], interimKey);
      },
    );

    test(
      'sin response_previewed asienta un final que continúa el interim',
      () async {
        final fixture = await _startChat();
        addTearDown(fixture.dispose);

        await _emitAndSettle(fixture, 'message.interim', const {
          'text': 'He revisado los logs.',
        });
        await _complete(fixture, const {
          'text': 'He revisado los logs. No hay errores críticos.',
        });

        final assistants = _assistantMessages(fixture.chat);
        expect(assistants, hasLength(1));
        expect(
          assistants.single['content'],
          'He revisado los logs. No hay errores críticos.',
        );
      },
    );

    test(
      'un final reescrito más corto sustituye al interim sin conservar restos',
      () async {
        final fixture = await _startChat();
        addTearDown(fixture.dispose);

        await _emitAndSettle(fixture, 'message.interim', const {
          'text': 'Borrador provisional del preview.',
        });
        await _complete(fixture, const {
          'text': 'Borrador provisional.',
          'response_previewed': true,
        });

        final assistants = _assistantMessages(fixture.chat);
        expect(assistants, hasLength(1));
        expect(assistants.single['content'], 'Borrador provisional.');
      },
    );

    test(
      'un final sin relación con el interim queda como otro segmento',
      () async {
        final fixture = await _startChat();
        addTearDown(fixture.dispose);

        await _emitAndSettle(fixture, 'message.interim', const {
          'text': 'Estoy revisando el proyecto.',
        });
        await _complete(fixture, const {
          'text': 'Aquí tienes el resumen final.',
        });

        expect(_nonEmptyAssistantTexts(fixture.chat), [
          'Aquí tienes el resumen final.',
          'Estoy revisando el proyecto.',
        ]);
      },
    );

    test('response_previewed deduplica un final idéntico', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);

      await _emitAndSettle(fixture, 'message.interim', const {
        'text': 'Resultado listo.',
      });
      final interimKey = fixture.chat.internalMessagesForTesting.firstWhere(
        (message) => message['_desktopInterim'] == true,
      )['_desktopInterimKey'];

      await _complete(fixture, const {
        'text': 'Resultado listo.',
        'response_previewed': true,
      });

      final assistants = _internalAssistantMessages(fixture.chat);
      expect(_nonEmptyAssistantTexts(fixture.chat), ['Resultado listo.']);
      expect(assistants, hasLength(1));
      expect(assistants.single['_desktopInterimKey'], interimKey);
      expect(assistants.single['_responsePreviewed'], isTrue);
    });

    test(
      'response_previewed asienta un final prefijo en el mismo segmento',
      () async {
        final fixture = await _startChat();
        addTearDown(fixture.dispose);

        await _emitAndSettle(fixture, 'message.interim', const {
          'text': 'He revisado los logs.',
        });
        final interimKey = fixture.chat.internalMessagesForTesting.firstWhere(
          (message) => message['_desktopInterim'] == true,
        )['_desktopInterimKey'];

        await _complete(fixture, const {
          'text': 'He revisado los logs. No hay errores críticos.',
          'response_previewed': true,
        });

        final assistants = _internalAssistantMessages(fixture.chat);
        expect(assistants, hasLength(1));
        expect(
          assistants.single['content'],
          'He revisado los logs. No hay errores críticos.',
        );
        expect(assistants.single['_desktopInterimKey'], interimKey);
        expect(assistants.single['_responsePreviewed'], isTrue);
      },
    );

    test('response_previewed publica el sufijo final sin fragmentarlo', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);
      fixture.chat.smoothStreaming = true;

      const interim = 'He revisado los logs.';
      final finalText =
          '$interim '
          '${List<String>.generate(12, (index) => 'Hallazgo ${index + 1} confirmado').join(', ')}.';

      await _emitAndSettle(fixture, 'message.interim', const {'text': interim});

      final revealed = <String>[];
      final subscription = fixture.chat.changes.listen((event) {
        if (event == ActiveChatEvent.token) {
          revealed.add(fixture.chat.assistantContent);
        }
      });
      addTearDown(subscription.cancel);

      await _complete(fixture, {
        'text': finalText,
        'response_previewed': true,
      }, timeout: const Duration(seconds: 3));

      expect(revealed, [finalText]);
    });

    test('message.complete sin deltas publica el texto completo', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);
      fixture.chat.smoothStreaming = true;

      final finalText = List<String>.generate(
        12,
        (index) => 'Frase corta ${index + 1}.',
      ).join(' ');
      final revealedLengths = <int>[];
      final subscription = fixture.chat.changes.listen((event) {
        if (event == ActiveChatEvent.token) {
          revealedLengths.add(fixture.chat.assistantContent.length);
        }
      });
      addTearDown(subscription.cancel);

      await _complete(fixture, {
        'text': finalText,
      }, timeout: const Duration(seconds: 3));

      expect(revealedLengths, [finalText.length]);
    });

    test('el terminal elimina cualquier pipeline histórico huérfano', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);
      fixture.chat.internalMessagesForTesting.addAll(const [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {'role': 'user', 'content': 'turno anterior'},
      ]);

      await _complete(fixture, const {'text': 'Turno actual terminado.'});

      expect(
        fixture.chat.messages.where((message) => message['_pipeline'] == true),
        isEmpty,
      );
      expect(fixture.chat.assistantContent, 'Turno actual terminado.');
    });

    test('status error termina fallido con causa pública acotada', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);

      await _failComplete(fixture, const {
        'status': 'error',
        'message': 'El modelo no existe.',
        'recoverable': true,
      });

      expect(fixture.chat.state, ChatPipelineState.failed);
      expect(fixture.chat.messages.first, {
        'role': 'assistant_error',
        'content': 'No se pudo completar la respuesta: El modelo no existe.',
        '_prompt': 'prueba de interim',
        'partial': false,
        'recoverable': true,
      });
      expect(fixture.events, contains(ActiveChatEvent.error));
      expect(fixture.events, isNot(contains(ActiveChatEvent.done)));
    });

    test(
      'status error no conserva texto parcial ni error remoto ambiguo',
      () async {
        final fixture = await _startChat();
        addTearDown(fixture.dispose);

        await _failComplete(fixture, const {
          'status': 'error',
          'text': 'half an ans',
          'error': 'connection reset mid-stream',
          'partial': true,
          'recoverable': true,
        });

        expect(fixture.chat.state, ChatPipelineState.failed);
        expect(fixture.chat.messages, hasLength(2));
        expect(fixture.chat.messages[0], {
          'role': 'assistant_error',
          'content': 'No se pudo completar la respuesta. Inténtalo de nuevo.',
          '_prompt': 'prueba de interim',
          'partial': true,
          'recoverable': true,
        });
        expect(
          fixture.chat.messages.toString(),
          isNot(contains('half an ans')),
        );
        expect(
          fixture.chat.messages.toString(),
          isNot(contains('connection reset mid-stream')),
        );
        expect(fixture.events, isNot(contains(ActiveChatEvent.done)));
      },
    );

    test(
      'status error no conserva el descriptor remoto de facturación',
      () async {
        final fixture = await _startChat();
        addTearDown(fixture.dispose);
        const billing = {
          'provider': 'nous',
          'billing_url': 'https://example.invalid/billing',
          'message': 'Crédito agotado',
        };

        await _failComplete(fixture, const {
          'status': 'error',
          'error': 'payment required',
          'billing': billing,
          'recoverable': true,
        });

        expect(fixture.chat.state, ChatPipelineState.failed);
        expect(fixture.chat.messages.first['role'], 'assistant_error');
        expect(
          fixture.chat.messages.first['content'],
          'No se pudo completar la respuesta. Inténtalo de nuevo.',
        );
        expect(fixture.chat.messages.first, isNot(contains('billing')));
        expect(
          fixture.chat.messages.toString(),
          isNot(contains('payment required')),
        );
        expect(
          fixture.chat.messages.toString(),
          isNot(contains('Crédito agotado')),
        );
        expect(fixture.chat.messages.first['recoverable'], isTrue);
        expect(fixture.events, contains(ActiveChatEvent.error));
        expect(fixture.events, isNot(contains(ActiveChatEvent.done)));
      },
    );
  });
}
