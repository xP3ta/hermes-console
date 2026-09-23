import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// Doble de gateway mínimo: sólo necesita aceptar el turno vivo, dejar
/// controlar el ACK de `session.interrupt` y publicar eventos de terminal.
class _StopGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRedirectGateway,
        HermesDesktopRewindResolverGateway,
        HermesDesktopDurableRewindGateway,
        HermesDesktopSessionActivityGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  final List<String> submittedTexts = [];
  final List<({String text, int ordinal, int rowId})> durableRewinds = [];
  int interruptCalls = 0;
  int busyRewindResponses = 0;
  bool emitInterruptTerminal = false;
  Object? interruptError;
  Completer<void>? interruptGate;
  DesktopSessionSnapshot? resumeSnapshot;

  void emit(String type, [Map<String, dynamic>? payload]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: 'runtime-test',
        payload: payload ?? const {},
      ),
    );
  }

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-test',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async =>
      resumeSnapshot ??
      DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-test',
        storedSessionId: storedSessionId,
        created: false,
      );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-test',
    storedSessionId: 'session-test',
    created: true,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submittedTexts.add(text);
  }

  @override
  Future<void> close() => _events.close();

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interruptCalls++;
    await interruptGate?.future;
    if (interruptError case final error?) throw error;
    if (emitInterruptTerminal) {
      emit('message.complete', const {'text': 'Operation interrupted.'});
    }
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async => const DesktopActiveSessionList(sessions: []);

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) => throw UnimplementedError();

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async => DesktopRedirectDisposition.redirected;

  @override
  Future<int?> resolveDurableUserRowId(
    String runtimeSessionId, {
    required String sourceText,
    required int expectedOrdinal,
  }) async => 3;

  @override
  Future<DesktopRewindAck> submitDurableRewindPrompt(
    String runtimeSessionId,
    String text,
    int truncateBeforeUserOrdinal, {
    required int truncateBeforeRowId,
    List<int> rebindSurvivorRowIds = const [],
  }) async {
    durableRewinds.add((
      text: text,
      ordinal: truncateBeforeUserOrdinal,
      rowId: truncateBeforeRowId,
    ));
    if (busyRewindResponses > 0) {
      busyRewindResponses--;
      throw const TuiGatewayRpcError(
        'prompt.submit',
        'session busy',
        code: 4009,
      );
    }
    return const DesktopRewindAck();
  }
}

ActiveChat _chat(
  _StopGateway gateway, {
  String id = 'conn-stop-recovery',
  String sessionId = 'session-test',
  StoredSessionMessageLoader? storedMessageLoader,
  Future<void> Function(CancelledTurnTombstone)? onCancelledTurn,
  bool attachDesktopRuntimeOnLoad = false,
}) {
  final api = ApiClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'test-only',
    httpClient: MockClient((_) async => http.Response('unused', 500)),
  );
  return ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: SavedConnection(
      id: id,
      label: 'Test',
      host: 'example.invalid',
      port: 443,
      apiKey: 'test-only',
      useHttps: true,
    ),
    sessionId: sessionId,
    sessionTitle: 'Test',
    notifications: null,
    onTerminal: () {},
    api: api,
    desktopGateway: gateway,
    storedMessageLoader: storedMessageLoader,
    onCancelledTurn: onCancelledTurn,
    attachDesktopRuntimeOnLoad: attachDesktopRuntimeOnLoad,
    allowUnownedDesktopSnapshotForTesting: attachDesktopRuntimeOnLoad,
  );
}

/// Sesión como la del dispositivo real: hay tombstone store (la app siempre lo
/// pasa) y una conversación previa con identidad durable, de modo que Stop sí
/// puede anclar su tombstone. El servidor, en cambio, nunca llega a publicar
/// una fila durable para el propio turno interrumpido — que es lo normal
/// cuando Stop llega antes de que el gateway persista el prompt, y lo que
/// siempre ocurre si la lectura del transcript falla en el móvil.
({ActiveChat chat, List<CancelledTurnTombstone> saved}) _durableChat(
  _StopGateway gateway, {
  required String id,
}) {
  final saved = <CancelledTurnTombstone>[];
  final chat = _chat(
    gateway,
    id: id,
    storedMessageLoader: (_, _) async => const [
      {'role': 'user', 'content': 'hola', 'id': 1},
      {'role': 'assistant', 'content': 'buenas', 'id': 2},
    ],
    onCancelledTurn: (tombstone) async => saved.add(tombstone),
  );
  return (chat: chat, saved: saved);
}

/// El terminal autoritativo puede llegar mientras `session.interrupt` espera.
/// Cualquier `message.complete` confirma Stop sin inspeccionar su texto.
Future<void> _stopSettledByAuthoritativeTerminal(
  ActiveChat chat,
  _StopGateway gateway,
) async {
  final gate = Completer<void>();
  gateway.interruptGate = gate;
  final stop = chat.cancel();
  await Future<void>.delayed(Duration.zero);
  expect(gateway.interruptCalls, 1);
  gateway.emit('message.complete', {'text': 'terminó antes del Stop'});
  await Future<void>.delayed(const Duration(milliseconds: 50));
  gate.complete();
  await stop;
  expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('terminal durante Stop no bloquea el envío siguiente', () async {
    final gateway = _StopGateway();
    final chat = _chat(gateway);
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    expect(chat.enqueue('encolado'), isTrue);

    await _stopSettledByAuthoritativeTerminal(chat, gateway);
    expect(chat.queueParked, isTrue);

    // Un gesto explícito del usuario siempre se admite y levanta el park.
    expect(
      await chat
          .send(
            fullText: 'mensaje nuevo',
            model: 'hermes-agent',
            history: const [],
          )
          .timeout(const Duration(seconds: 5)),
      isTrue,
    );
    expect(chat.queueParked, isFalse);
    expect(gateway.submittedTexts, contains('mensaje nuevo'));
  });

  test('terminal durante Stop deja el lease reutilizable', () async {
    final gateway = _StopGateway();
    final chat = _chat(gateway, id: 'conn-stop-superseded-lease');
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );

    await _stopSettledByAuthoritativeTerminal(chat, gateway);

    expect(chat.queueParked, isFalse);
    expect(chat.queueDrainSuspendedForTesting, isFalse);
  });

  test('stop failed permite reanudar la cola', () async {
    final gateway = _StopGateway()
      ..interruptError = StateError('interrupt rejected');
    final chat = _chat(gateway, id: 'conn-stop-failed-resume');
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    expect(chat.enqueue('uno'), isTrue);
    expect(chat.enqueue('dos'), isTrue);

    await expectLater(chat.cancel(), throwsA(isA<StateError>()));
    expect(chat.stopConfirmationState, StopConfirmationState.failed);
    expect(chat.queueParked, isTrue);

    chat.resumeParkedQueue();

    expect(chat.queueParked, isFalse);
    expect(chat.queueDrainSuspendedForTesting, isFalse);
    expect(chat.queuedMessages, ['uno', 'dos']);
  });

  test('terminal autoritativo limpia un Stop fallido obsoleto', () async {
    final gateway = _StopGateway()
      ..interruptError = StateError('interrupt rejected');
    final chat = _chat(gateway, id: 'conn-stop-failed-terminal');
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno que termina por sí solo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );

    await expectLater(chat.cancel(), throwsA(isA<StateError>()));
    expect(chat.stopConfirmationState, StopConfirmationState.failed);

    await chat.refreshPassiveRemoteActivity();

    expect(chat.stopConfirmationState, StopConfirmationState.idle);
  });

  test('stop sobre cola vacía no parkea', () async {
    final gateway = _StopGateway();
    final chat = _chat(gateway, id: 'conn-stop-empty-queue');
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    expect(chat.queuedMessages, isEmpty);

    await chat.cancel();

    expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
    expect(chat.queueParked, isFalse);
    expect(chat.queueDrainSuspendedForTesting, isFalse);
  });

  group('un Stop confirmado nunca inutiliza la sesión', () {
    test('se puede volver a enviar aunque el turno detenido no sea durable', () async {
      final gateway = _StopGateway();
      final harness = _durableChat(gateway, id: 'conn-stop-then-send');
      final chat = harness.chat;
      addTearDown(chat.dispose);
      await chat.loadMessages();

      expect(
        await chat.send(
          fullText: 'segundo',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      await chat.cancel().timeout(const Duration(seconds: 5));
      expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
      expect(harness.saved, hasLength(1));

      // El turno detenido se quedó sin fila durable en el servidor. Antes eso
      // rechazaba en silencio TODO envío posterior y la sesión quedaba muerta.
      expect(
        await chat
            .send(
              fullText: 'tercero',
              model: 'hermes-agent',
              history: const [],
            )
            .timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(gateway.submittedTexts, ['segundo', 'tercero']);
      expect(chat.stopConfirmationState, StopConfirmationState.idle);
    });

    test('la cola retenida drena al reanudarla tras el Stop', () async {
      final gateway = _StopGateway();
      final harness = _durableChat(gateway, id: 'conn-stop-queue-drains');
      final chat = harness.chat;
      addTearDown(chat.dispose);
      await chat.loadMessages();

      expect(
        await chat.send(
          fullText: 'segundo',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      expect(chat.enqueue('en cola'), isTrue);
      await chat.cancel().timeout(const Duration(seconds: 5));
      expect(chat.queueParked, isTrue);

      chat.resumeParkedQueue();
      for (var tick = 0; tick < 60 && chat.queuedMessages.isNotEmpty; tick++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // El drenaje llamaba a `send()`, se lo rechazaban y la rama de texto no
      // reintentaba ni avisaba: la entrada se quedaba muda en la cabeza.
      expect(gateway.submittedTexts, ['segundo', 'en cola']);
      expect(chat.queuedMessages, isEmpty);
    });

    test('editar un mensaje vivo reintenta 4009 con el recorte intacto', () async {
      final gateway = _StopGateway()
        ..emitInterruptTerminal = true
        ..busyRewindResponses = 1;
      final harness = _durableChat(gateway, id: 'conn-edit-while-streaming');
      final chat = harness.chat;
      addTearDown(chat.dispose);
      await chat.loadMessages();

      expect(
        await chat.send(
          fullText: 'segundo',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      expect(chat.isStreaming, isTrue);

      // Ordinal 1 == el turno vivo ('hola' es el 0).
      await chat
          .rewrite(
            userOrdinal: 1,
            text: 'segundo editado',
            model: 'hermes-agent',
          )
          .timeout(const Duration(seconds: 6));

      expect(gateway.interruptCalls, 2);
      expect(gateway.submittedTexts, ['segundo']);
      expect(gateway.durableRewinds, [
        (text: 'segundo editado', ordinal: 1, rowId: 3),
        (text: 'segundo editado', ordinal: 1, rowId: 3),
      ]);
      expect(chat.takeRewindRestoredOnError(), isFalse);
      expect(chat.isStreaming, isTrue);

      // Y la sesión sigue viva: editar no puede dejarla bloqueada tampoco.
      expect(
        chat.messages.any(
          (message) =>
              message['role'] == 'user' && message['_cancelledUser'] == true,
        ),
        isFalse,
        reason: 'editar no es un Stop del usuario',
      );
    });

    test('una edición rechazada antes de arrancar se marca para la UI', () async {
      final gateway = _StopGateway();
      final harness = _durableChat(gateway, id: 'conn-edit-rejected');
      final chat = harness.chat;
      addTearDown(chat.dispose);
      await chat.loadMessages();
      expect(
        await chat.send(
          fullText: 'segundo',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      chat.dispose();

      await chat
          .rewrite(userOrdinal: 0, text: 'no llega', model: 'hermes-agent')
          .timeout(const Duration(seconds: 6));

      // Sin esta marca la pantalla no mostraba nada: el turno vivo quedaba
      // interrumpido y la edición desaparecía sin aviso.
      expect(chat.takeRewindRestoredOnError(), isTrue);
    });
  });

  test('fallo de persistencia no bloquea Stop ni el siguiente envío', () async {
    final gateway = _StopGateway()..emitInterruptTerminal = true;
    final chat = _chat(
      gateway,
      id: 'conn-stop-persistence-failure',
      storedMessageLoader: (_, _) async => const [
        {'role': 'user', 'content': 'primero', 'id': 1},
        {'role': 'assistant', 'content': 'respuesta', 'id': 2},
      ],
      onCancelledTurn: (_) async => throw StateError('keystore unavailable'),
    );
    addTearDown(chat.dispose);
    await chat.loadMessages();

    expect(
      await chat.send(
        fullText: 'turno detenido',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );

    Object? stopError;
    try {
      await chat.cancel();
    } catch (error) {
      stopError = error;
    }

    expect(stopError, isNull);
    expect(gateway.interruptCalls, 1);
    expect(
      await chat.send(
        fullText: 'turno posterior',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    expect(gateway.submittedTexts, ['turno detenido', 'turno posterior']);
  });

  group('Stop never duplicates durable user rows', () {
    test('composer Stop on a new first turn reloads one user row', () async {
      final gateway = _StopGateway()..emitInterruptTerminal = true;
      final rows = <Map<String, dynamic>>[];
      final saved = <CancelledTurnTombstone>[];
      final chat = _chat(
        gateway,
        id: 'conn-composer-stop-first-turn',
        sessionId: 'mob-composer-stop-first-turn',
        storedMessageLoader: (_, _) async => List.of(rows),
        onCancelledTurn: (tombstone) async => saved.add(tombstone),
      );
      addTearDown(chat.dispose);

      expect(
        await chat.send(
          fullText: 'sleep 60',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      gateway.emit('tool.start', const {
        'name': 'terminal',
        'tool_id': 'terminal-first-turn',
      });
      await Future<void>.delayed(Duration.zero);

      await chat.cancel();
      for (var tick = 0; tick < 20 && saved.isEmpty; tick++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(saved, hasLength(1));
      expect(saved.single.firstUser, isTrue);

      rows.addAll(const [
        {
          'id': 1,
          'message_id': 'user-first-turn',
          'role': 'user',
          'content': 'sleep 60',
        },
        {'id': 2, 'role': 'assistant', 'content': ''},
        {'id': 3, 'role': 'tool', 'content': 'sleep 60'},
        {
          'id': 4,
          'role': 'assistant',
          'content': 'Operation interrupted.',
        },
      ]);
      await chat.loadMessages(expectedMessageCount: 4);

      expect(
        chat.messages.where(
          (message) =>
              message['role'] == 'user' && message['content'] == 'sleep 60',
        ),
        hasLength(1),
      );
    });

    test('clarify cancel on a new first turn reloads one user row', () async {
      final gateway = _StopGateway()..emitInterruptTerminal = true;
      final rows = <Map<String, dynamic>>[];
      final saved = <CancelledTurnTombstone>[];
      final chat = _chat(
        gateway,
        id: 'conn-clarify-stop-first-turn',
        sessionId: 'mob-clarify-stop-first-turn',
        storedMessageLoader: (_, _) async => List.of(rows),
        onCancelledTurn: (tombstone) async => saved.add(tombstone),
      );
      addTearDown(chat.dispose);

      expect(
        await chat.send(
          fullText: 'ask before continuing',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      gateway.emit('clarify.request', const {
        'request_id': 'clarify-first-turn',
        'question': 'Continue?',
      });
      for (
        var tick = 0;
        tick < 20 && chat.pendingInteractivePrompt == null;
        tick++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(chat.pendingInteractivePrompt, isNotNull);

      await chat.cancel();
      for (var tick = 0; tick < 20 && saved.isEmpty; tick++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(saved, hasLength(1));

      rows.addAll(const [
        {
          'id': 11,
          'message_id': 'user-clarify-first-turn',
          'role': 'user',
          'content': 'ask before continuing',
        },
        {'id': 12, 'role': 'assistant', 'content': ''},
        {'id': 13, 'role': 'tool', 'content': 'clarify'},
        {
          'id': 14,
          'role': 'assistant',
          'content': 'Operation interrupted.',
        },
      ]);
      await chat.loadMessages(expectedMessageCount: 4);

      expect(
        chat.messages.where(
          (message) =>
              message['role'] == 'user' &&
              message['content'] == 'ask before continuing',
        ),
        hasLength(1),
      );
    });

    test('row Stop over a durable first turn reloads one user row', () async {
      final gateway = _StopGateway()
        ..emitInterruptTerminal = true
        ..resumeSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-test',
          storedSessionId: 'session-row-stop',
          created: false,
          running: true,
          status: 'working',
          inflight: DesktopInflightTurn(user: 'sleep 60', streaming: true),
          messagesProvided: false,
          messageCount: 3,
        );
      final rows = <Map<String, dynamic>>[
        const {
          'id': 21,
          'message_id': 'user-row-stop',
          'role': 'user',
          'content': 'sleep 60',
        },
        const {'id': 22, 'role': 'assistant', 'content': ''},
        const {'id': 23, 'role': 'tool', 'content': 'sleep 60'},
      ];
      final chat = _chat(
        gateway,
        id: 'conn-row-stop-first-turn',
        sessionId: 'session-row-stop',
        storedMessageLoader: (_, _) async => List.of(rows),
        onCancelledTurn: (_) async {},
        attachDesktopRuntimeOnLoad: true,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 3);
      expect(chat.isStreaming, isTrue);
      await chat.cancel();
      rows.add(const {
        'id': 24,
        'role': 'assistant',
        'content': 'Operation interrupted.',
      });
      gateway.resumeSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-test',
        storedSessionId: 'session-row-stop',
        created: false,
        running: false,
        status: 'idle',
        messagesProvided: false,
        messageCount: 4,
      );
      await chat.loadMessages(expectedMessageCount: 4);

      expect(
        chat.messages.where(
          (message) =>
              message['role'] == 'user' && message['content'] == 'sleep 60',
        ),
        hasLength(1),
      );
    });

    test('two identical durable prompts remain distinct rows', () async {
      final gateway = _StopGateway();
      final chat = _chat(
        gateway,
        id: 'conn-identical-prompts',
        storedMessageLoader: (_, _) async => const [
          {
            'id': 31,
            'message_id': 'identical-user-1',
            'role': 'user',
            'content': 'same prompt',
          },
          {'id': 32, 'role': 'assistant', 'content': 'first answer'},
          {
            'id': 33,
            'message_id': 'identical-user-2',
            'role': 'user',
            'content': 'same prompt',
          },
          {'id': 34, 'role': 'assistant', 'content': 'second answer'},
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 4);

      final identicalUsers = chat.messages
          .where(
            (message) =>
                message['role'] == 'user' &&
                message['content'] == 'same prompt',
          )
          .toList(growable: false);
      expect(identicalUsers, hasLength(2));
      expect(
        identicalUsers.map((message) => message['message_id']).toSet(),
        {'identical-user-1', 'identical-user-2'},
      );
    });
  });

  test('dos drenajes solapados no envían la misma entrada dos veces', () async {
    final gateway = _StopGateway();
    final chat = _chat(gateway, id: 'conn-queue-reentrancy');
    addTearDown(chat.dispose);

    // Cola en reposo: cada `enqueue` programa su propio drenaje, así que dos
    // seguidos dejan dos drenajes en vuelo sobre la misma cabeza. `send()`
    // tarda varios `await` en publicar `connecting`, que era la ventana en la
    // que ambos leían la misma entrada y la enviaban por duplicado.
    expect(
      await chat.send(
        fullText: 'vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    gateway.emit('message.complete', {'text': 'listo'});
    for (var tick = 0; tick < 40 && chat.isStreaming; tick++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(chat.isStreaming, isFalse);

    expect(chat.enqueue('A'), isTrue);
    expect(chat.enqueue('B'), isTrue);
    for (var tick = 0; tick < 60; tick++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(gateway.submittedTexts, ['vivo', 'A']);
    expect(chat.queuedMessages, ['B']);
  });
}
