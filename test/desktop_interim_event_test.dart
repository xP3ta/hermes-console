import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    test(
      'classifiers explícitos se ven en chat pero fallan cerrados para Voz',
      () async {
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
          expect(visible, contains(marker), reason: marker);
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

    test(
      'deltas y final clasificados conservan el chat pero no entran en Voz',
      () async {
        final fixture = await _startChat();
        addTearDown(fixture.dispose);

        final token = fixture.chat.changes.firstWhere(
          (event) => event == ActiveChatEvent.token,
        );
        fixture.gateway.emit('message.delta', const {
          'text': 'ANALYSIS DELTA PRIVADO',
          'channel': 'analysis',
        });
        await token.timeout(const Duration(seconds: 1));
        expect(fixture.events, contains(ActiveChatEvent.token));
        expect(fixture.chat.assistantNarrationContent, isEmpty);
        expect(
          fixture.chat.assistantContent,
          contains('ANALYSIS DELTA PRIVADO'),
        );

        await _complete(fixture, const {
          'text': 'TRAZA INTERNA FINAL',
          'channel': 'trace',
        });

        expect(fixture.chat.assistantNarrationContent, isEmpty);
        expect(fixture.chat.assistantContent, 'TRAZA INTERNA FINAL');
        expect(
          fixture.chat.messages.map((message) => message['content']).join('\n'),
          contains('TRAZA INTERNA FINAL'),
        );
      },
    );

    test(
      'un final idéntico sin response_previewed se asienta en el mismo segmento',
      () async {
        final fixture = await _startChat();
        addTearDown(fixture.dispose);

        await _emitAndSettle(fixture, 'message.interim', const {
          'text': 'Resultado listo.',
        });
        final interimKey = fixture.chat.messages.firstWhere(
          (message) => message['_desktopInterim'] == true,
        )['_desktopInterimKey'];
        await _complete(fixture, const {'text': 'Resultado listo.'});

        // Paridad con Desktop (#63679): continuidad de prefijo basta para
        // saber que es el MISMO mensaje; duplicarlo en una segunda burbuja
        // pintaba el parcial y el final limpio a la vez.
        final assistants = _assistantMessages(fixture.chat);
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
      final interimKey = fixture.chat.messages.firstWhere(
        (message) => message['_desktopInterim'] == true,
      )['_desktopInterimKey'];

      await _complete(fixture, const {
        'text': 'Resultado listo.',
        'response_previewed': true,
      });

      final assistants = _assistantMessages(fixture.chat);
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
        final interimKey = fixture.chat.messages.firstWhere(
          (message) => message['_desktopInterim'] == true,
        )['_desktopInterimKey'];

        await _complete(fixture, const {
          'text': 'He revisado los logs. No hay errores críticos.',
          'response_previewed': true,
        });

        final assistants = _assistantMessages(fixture.chat);
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
      fixture.chat.messages.addAll(const [
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

    test('status error termina fallido y usa el texto como fallback', () async {
      final fixture = await _startChat();
      addTearDown(fixture.dispose);

      await _failComplete(fixture, const {
        'status': 'error',
        'text': 'Error: invalid model slug',
        'recoverable': true,
      });

      expect(fixture.chat.state, ChatPipelineState.failed);
      expect(fixture.chat.messages.first, {
        'role': 'assistant_error',
        'content': 'Error: invalid model slug',
        '_prompt': 'prueba de interim',
        'error': 'Error: invalid model slug',
        'partial': false,
        'recoverable': true,
        '_localTranscriptProjectionId': 'local-assistant-error-1',
      });
      expect(fixture.events, contains(ActiveChatEvent.error));
      expect(fixture.events, isNot(contains(ActiveChatEvent.done)));
    });

    test(
      'status error conserva el texto parcial y el error estructurado',
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
        expect(fixture.chat.messages, hasLength(3));
        expect(fixture.chat.messages[0], {
          'role': 'assistant_error',
          'content': 'connection reset mid-stream',
          '_prompt': 'prueba de interim',
          'error': 'connection reset mid-stream',
          'partial': true,
          'recoverable': true,
          '_localTranscriptProjectionId': 'local-assistant-error-1',
        });
        expect(fixture.chat.messages[1]['role'], 'assistant');
        expect(fixture.chat.messages[1]['content'], 'half an ans');
        expect(fixture.chat.messages[1]['_cancelled'], isTrue);
        expect(fixture.chat.messages[1]['_pipeline'], isFalse);
        expect(fixture.events, isNot(contains(ActiveChatEvent.done)));
      },
    );

    test('status error conserva el descriptor de facturación', () async {
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
      expect(fixture.chat.messages.first['content'], 'payment required');
      expect(fixture.chat.messages.first['billing'], billing);
      expect(fixture.chat.messages.first['recoverable'], isTrue);
      expect(fixture.events, contains(ActiveChatEvent.error));
      expect(fixture.events, isNot(contains(ActiveChatEvent.done)));
    });
  });
}
