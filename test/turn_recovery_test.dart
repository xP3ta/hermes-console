import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _MemoryOutbox implements TurnOutboxPersistence {
  final List<PreparedTurn> writes = [];
  final List<PreparedTurn> saveAttempts = [];
  final List<PreparedTurn> deletes = [];
  PreparedTurnState? failState;

  @override
  Future<void> save(PreparedTurn turn) async {
    saveAttempts.add(turn);
    if (turn.state == failState) throw StateError('synthetic secure failure');
    writes.add(turn);
  }

  @override
  Future<void> delete(PreparedTurn turn) async => deletes.add(turn);
}

class _FailingDeleteOutbox extends _MemoryOutbox {
  var failDelete = true;

  @override
  Future<void> delete(PreparedTurn turn) async {
    if (failDelete) throw StateError('synthetic delete failure');
    await super.delete(turn);
  }
}

class _BlockingDeleteOutbox extends _MemoryOutbox {
  final deleteStarted = Completer<void>();
  final releaseDelete = Completer<void>();

  @override
  Future<void> delete(PreparedTurn turn) async {
    if (!deleteStarted.isCompleted) deleteStarted.complete();
    await releaseDelete.future;
    await super.delete(turn);
  }
}

class _BlockingSaveOutbox extends _MemoryOutbox {
  final saveStarted = Completer<void>();
  final releaseSave = Completer<void>();
  var _blocked = true;

  @override
  Future<void> save(PreparedTurn turn) async {
    if (_blocked) {
      _blocked = false;
      saveStarted.complete();
      await releaseSave.future;
    }
    await super.save(turn);
  }
}

class _BlockingSaveFailingDeleteOutbox extends _BlockingSaveOutbox {
  var deleteAttempts = 0;

  @override
  Future<void> delete(PreparedTurn turn) async {
    deleteAttempts++;
    throw StateError('synthetic delete failure');
  }
}

class _DesktopGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRedirectGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  Object? connectError;
  Object? submitError;
  int submitCalls = 0;
  final List<String> submittedTexts = [];
  int interruptCalls = 0;
  Object? interruptError;
  Completer<void>? interruptGate;
  DesktopRedirectDisposition redirectDisposition =
      DesktopRedirectDisposition.redirected;
  final List<String> redirectedTexts = [];

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
  Future<void> connect() async {
    if (connectError case final error?) throw error;
  }

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
  }) async => DesktopSessionSnapshot(
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
    submitCalls++;
    submittedTexts.add(text);
    if (submitError case final error?) throw error;
  }

  @override
  Future<void> close() => _events.close();

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interruptCalls++;
    await interruptGate?.future;
    if (interruptError case final error?) throw error;
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
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    redirectedTexts.add(text);
    return redirectDisposition;
  }
}

PreparedTurn _prepared() {
  const now = 1000;
  return const PreparedTurn(
    connectionId: 'conn-test',
    sessionId: 'session-test',
    clientTurnId: 'turn-test',
    createdAtMs: now,
    updatedAtMs: now,
    text: 'mensaje',
    attachments: [],
    model: 'hermes-agent',
    profile: '',
  );
}

PreparedTurn _queuedPrepared(String id, String text) => PreparedTurn(
  connectionId: 'conn-test',
  sessionId: 'session-test',
  clientTurnId: id,
  createdAtMs: 1000,
  updatedAtMs: 1000,
  text: text,
  fullText: text,
  desktopText: text,
  attachments: const [],
  model: 'hermes-agent',
  profile: '',
  state: PreparedTurnState.prepared,
  queued: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('corte antes de write queda como failedBeforeAcceptance', () async {
    final store = _MemoryOutbox();
    final delivery = ActiveTurnDelivery(
      prepared: _prepared(),
      store: store,
      nowMs: () => 2000,
    );

    await delivery.markUnaccepted();

    expect(delivery.transportStarted, isFalse);
    expect(delivery.current.state, PreparedTurnState.failedBeforeAcceptance);
    expect(store.writes.map((turn) => turn.state), [
      PreparedTurnState.failedBeforeAcceptance,
    ]);
  });

  test('corte después de write y antes de ACK queda ambiguo', () async {
    final store = _MemoryOutbox();
    final delivery = ActiveTurnDelivery(
      prepared: _prepared(),
      store: store,
      nowMs: () => 2000,
    );

    expect(
      await delivery.beginTransport(PreparedTurnTransport.desktop),
      isTrue,
    );
    await delivery.markUnaccepted();

    expect(delivery.transportStarted, isTrue);
    expect(delivery.current.state, PreparedTurnState.ambiguous);
    expect(store.writes.map((turn) => turn.state), [
      PreparedTurnState.submitting,
      PreparedTurnState.ambiguous,
    ]);
  });

  test('ACK se persiste como accepted antes de devolver aceptación', () async {
    final store = _MemoryOutbox();
    final delivery = ActiveTurnDelivery(
      prepared: _prepared(),
      store: store,
      nowMs: () => 2000,
    );

    await delivery.beginTransport(PreparedTurnTransport.desktop);
    await delivery.markAccepted();

    expect(delivery.acknowledged, isTrue);
    expect(delivery.current.state, PreparedTurnState.accepted);
    expect(store.writes.map((turn) => turn.state), [
      PreparedTurnState.submitting,
      PreparedTurnState.accepted,
    ]);
  });

  test(
    'ACK running se conserva hasta terminal y entonces se elimina',
    () async {
      final store = _MemoryOutbox();
      final delivery = ActiveTurnDelivery(
        prepared: _prepared(),
        store: store,
        nowMs: () => 2000,
      );

      await delivery.beginTransport(PreparedTurnTransport.desktop);
      await delivery.markAccepted();
      await delivery.markRunning();

      expect(delivery.current.state, PreparedTurnState.running);
      expect(store.deletes, isEmpty);

      await delivery.markTerminalAndDelete();

      expect(delivery.current.state, PreparedTurnState.terminal);
      expect(store.deletes, hasLength(1));
      expect(store.deletes.single.state, PreparedTurnState.terminal);
    },
  );

  test('fallo al guardar submitting bloquea el transporte', () async {
    final store = _MemoryOutbox()..failState = PreparedTurnState.submitting;
    final delivery = ActiveTurnDelivery(
      prepared: _prepared(),
      store: store,
      nowMs: () => 2000,
    );

    expect(
      await delivery.beginTransport(PreparedTurnTransport.desktop),
      isFalse,
    );

    expect(delivery.transportStarted, isFalse);
    expect(delivery.persistenceFailed, isTrue);
    expect(delivery.current.state, PreparedTurnState.prepared);
  });

  test('ActiveChat conserva submitting y ambiguous si se pierde ACK', () async {
    final store = _MemoryOutbox();
    final delivery = ActiveTurnDelivery(
      prepared: _prepared(),
      store: store,
      nowMs: () => 2000,
    );
    final gateway = _DesktopGateway()
      ..submitError = TimeoutException('synthetic ack loss');
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-only',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: 'test-only',
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
    );
    addTearDown(chat.dispose);

    final accepted = await chat.send(
      fullText: 'mensaje',
      model: 'hermes-agent',
      history: const [],
      delivery: delivery,
    );

    expect(accepted, isFalse);
    expect(gateway.submitCalls, 1);
    expect(delivery.current.state, PreparedTurnState.ambiguous);
    expect(chat.activeTurnDelivery, same(delivery));
  });

  test('cola conserva turno completo y cancela por clientTurnId', () async {
    final store = _MemoryOutbox();
    final gateway = _DesktopGateway();
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: 'test',
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
    );
    addTearDown(chat.dispose);
    final complete = PreparedTurn(
      connectionId: 'conn-test',
      sessionId: 'session-test',
      clientTurnId: 'queued-complete',
      createdAtMs: 1000,
      updatedAtMs: 1000,
      text: 'revisa',
      fullText: 'revisa\n⟦adjunto⟧\nprivado',
      desktopText: 'revisa\n@file:.hermes/a.pdf',
      attachments: const [
        AttachmentDraft(
          localId: 'a',
          type: AttachmentType.document,
          name: 'a.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 1,
          localPath: '/private/a.pdf',
        ),
      ],
      model: 'modelo-cola',
      profile: 'research',
    );
    final delivery = ActiveTurnDelivery(prepared: complete, store: store);

    expect(await chat.enqueuePreparedTurn(delivery), isTrue);
    expect(chat.queuedTurns.single.delivery, same(delivery));
    expect(chat.queuedTurns.single.turn.fullText, contains('privado'));
    expect(chat.queuedTurns.single.turn.attachments.single.name, 'a.pdf');
    expect(await chat.cancelQueuedTurn('queued-complete'), isTrue);
    expect(chat.queuedTurns, isEmpty);
    expect(store.deletes.single.clientTurnId, 'queued-complete');
  });

  test(
    'cola durable nunca reabre REST aunque policy legacy lo permita',
    () async {
      final store = _BlockingSaveOutbox();
      final gateway = _DesktopGateway();
      final firstRemotePost = Completer<http.Request>();
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: String.fromCharCodes([116, 101, 115, 116]),
        httpClient: MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == '/v1/runs' &&
              !firstRemotePost.isCompleted) {
            firstRemotePost.complete(request);
          }
          return http.Response('{}', 500);
        }),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-test',
          label: 'Test',
          host: 'example.invalid',
          port: 443,
          apiKey: String.fromCharCodes([116, 101, 115, 116]),
          useHttps: true,
        ),
        sessionId: 'session-test',
        sessionTitle: 'Test',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
        storedMessageLoader: (_, _) async => const [],
        terminalReconcileBudget: Duration.zero,
      );
      addTearDown(chat.dispose);

      expect(
        await chat.send(
          fullText: 'turno vivo',
          model: 'hermes-agent',
          history: const [],
          sessionConfig: const DesktopSessionCreateConfig(
            allowTransportFallback: true,
          ),
        ),
        isTrue,
      );
      final prepared = PreparedTurn(
        connectionId: 'conn-test',
        sessionId: 'session-test',
        clientTurnId: 'turno-preparado-primero',
        createdAtMs: 2000,
        updatedAtMs: 2000,
        text: 'adjunto primero',
        fullText: 'adjunto primero',
        attachments: const [],
        model: 'hermes-agent',
        profile: '',
        queued: true,
      );
      final preparedEnqueue = chat.enqueuePreparedTurn(
        ActiveTurnDelivery(prepared: prepared, store: store),
      );
      await store.saveStarted.future;
      chat.enqueue('texto posterior');
      gateway.connectError = StateError('desktop unavailable before submit');
      gateway.emit('message.complete');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(firstRemotePost.isCompleted, isFalse);

      store.releaseSave.complete();
      expect(await preparedEnqueue, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(firstRemotePost.isCompleted, isFalse);
      expect(
        chat.queuedTurns.single.turn.clientTurnId,
        'turno-preparado-primero',
      );
    },
  );

  test('clientTurnId pendiente rechaza enqueue preparado duplicado', () async {
    final firstStore = _BlockingSaveOutbox();
    final secondStore = _MemoryOutbox();
    final gateway = _DesktopGateway();
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: String.fromCharCodes([116, 101, 115, 116]),
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: String.fromCharCodes([116, 101, 115, 116]),
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      storedMessageLoader: (_, _) async => const [],
      terminalReconcileBudget: Duration.zero,
    );
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    final first = chat.enqueuePreparedTurn(
      ActiveTurnDelivery(
        prepared: _queuedPrepared('duplicate', 'primero'),
        store: firstStore,
      ),
    );
    await firstStore.saveStarted.future;

    expect(
      await chat.enqueuePreparedTurn(
        ActiveTurnDelivery(
          prepared: _queuedPrepared('duplicate', 'segundo'),
          store: secondStore,
        ),
      ),
      isFalse,
    );

    firstStore.releaseSave.complete();
    expect(await first, isTrue);
    expect(chat.queuedTurns, hasLength(1));
    expect(chat.queuedTurns.single.turn.text, 'primero');
    expect(secondStore.writes, isEmpty);
  });

  test('persistencias preparadas fuera de orden conservan FIFO', () async {
    final firstStore = _BlockingSaveOutbox();
    final secondStore = _MemoryOutbox();
    final gateway = _DesktopGateway();
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: String.fromCharCodes([116, 101, 115, 116]),
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: String.fromCharCodes([116, 101, 115, 116]),
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
    );
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    final first = chat.enqueuePreparedTurn(
      ActiveTurnDelivery(
        prepared: _queuedPrepared('primero', 'primero'),
        store: firstStore,
      ),
    );
    await firstStore.saveStarted.future;
    expect(
      await chat.enqueuePreparedTurn(
        ActiveTurnDelivery(
          prepared: _queuedPrepared('segundo', 'segundo'),
          store: secondStore,
        ),
      ),
      isTrue,
    );
    firstStore.releaseSave.complete();
    expect(await first, isTrue);

    expect(chat.queuedTurns.map((item) => item.turn.clientTurnId).toList(), [
      'primero',
      'segundo',
    ]);
  });

  test('fallo al borrar cancelación mantiene el turno bloqueado', () async {
    final store = _FailingDeleteOutbox();
    final gateway = _DesktopGateway();
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: String.fromCharCodes([116, 101, 115, 116]),
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: String.fromCharCodes([116, 101, 115, 116]),
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      storedMessageLoader: (_, _) async => const [],
      terminalReconcileBudget: Duration.zero,
    );
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    expect(
      await chat.enqueuePreparedTurn(
        ActiveTurnDelivery(
          prepared: _queuedPrepared('cancel-falla', 'no debe salir'),
          store: store,
        ),
      ),
      isTrue,
    );
    expect(await chat.cancelQueuedTurn('cancel-falla'), isFalse);
    gateway.emit('message.complete');
    await Future<void>.delayed(const Duration(milliseconds: 1800));

    expect(gateway.submittedTexts, ['turno vivo']);
    expect(chat.queuedTurns.single.turn.clientTurnId, 'cancel-falla');

    store.failDelete = false;
    expect(await chat.cancelQueuedTurn('cancel-falla'), isTrue);
    expect(chat.queuedTurns, isEmpty);
  });

  test(
    'Stop estaciona la cola durable aunque falle un delete posterior',
    () async {
      final store = _FailingDeleteOutbox();
      final gateway = _DesktopGateway();
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'not-a-secret',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-test',
          label: 'Test',
          host: 'example.invalid',
          port: 443,
          apiKey: 'not-a-secret',
          useHttps: true,
        ),
        sessionId: 'session-test',
        sessionTitle: 'Test',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);

      final prepared = _queuedPrepared('stop-terminal', 'no debe revivir');
      await chat.restoreQueuedTurns([prepared], store, scheduleDrain: false);

      await chat.cancel();

      expect(chat.queueParked, isTrue);
      expect(chat.queuedTurns.single.turn.clientTurnId, 'stop-terminal');
      expect(store.writes, isEmpty);
      expect(gateway.submittedTexts, isEmpty);
    },
  );

  test('cancel individual no compite con drain terminal', () async {
    final store = _BlockingDeleteOutbox();
    final gateway = _DesktopGateway();
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: String.fromCharCodes([116, 101, 115, 116]),
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: String.fromCharCodes([116, 101, 115, 116]),
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
    );
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    expect(
      await chat.enqueuePreparedTurn(
        ActiveTurnDelivery(
          prepared: _queuedPrepared('cancel-race', 'no enviar'),
          store: store,
        ),
      ),
      isTrue,
    );

    final cancelling = chat.cancelQueuedTurn('cancel-race');
    await store.deleteStarted.future;
    final duplicateStore = _MemoryOutbox();
    expect(
      await chat.enqueuePreparedTurn(
        ActiveTurnDelivery(
          prepared: _queuedPrepared('cancel-race', 'duplicado tardío'),
          store: duplicateStore,
        ),
      ),
      isFalse,
    );
    expect(duplicateStore.writes, isEmpty);
    gateway.emit('message.complete');
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    expect(gateway.submittedTexts, ['turno vivo']);

    store.releaseDelete.complete();
    expect(await cancelling, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    expect(gateway.submittedTexts, ['turno vivo']);
    expect(chat.queuedTurns, isEmpty);
  });

  test(
    'Stop espera save inicial y deja terminal aunque falle delete',
    () async {
      final store = _BlockingSaveFailingDeleteOutbox();
      final gateway = _DesktopGateway();
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-test',
          label: 'Test',
          host: 'example.invalid',
          port: 443,
          apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
          useHttps: true,
        ),
        sessionId: 'session-test',
        sessionTitle: 'Test',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);

      final prepared = _queuedPrepared('save-stop-terminal', 'no debe revivir');
      final enqueue = chat.enqueuePreparedTurn(
        ActiveTurnDelivery(prepared: prepared, store: store),
      );
      await store.saveStarted.future;

      var stopCompleted = false;
      final stop = chat.cancel().whenComplete(() => stopCompleted = true);
      await Future<void>.delayed(Duration.zero);
      final stoppedBeforeSave = stopCompleted;
      store.releaseSave.complete();
      await stop;

      expect(stoppedBeforeSave, isTrue);
      expect(await enqueue, isTrue);
      expect(chat.queueParked, isTrue);
      expect(chat.queuedTurns.single.turn.clientTurnId, 'save-stop-terminal');
      expect(store.deleteAttempts, 0);
      expect(store.writes.map((turn) => turn.state), [
        PreparedTurnState.prepared,
      ]);

      final recoveredGateway = _DesktopGateway();
      final recovered = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-test',
          label: 'Test',
          host: 'example.invalid',
          port: 443,
          apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
          useHttps: true,
        ),
        sessionId: 'session-test',
        sessionTitle: 'Test',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: recoveredGateway,
      );
      addTearDown(recovered.dispose);
      await recovered.restoreQueuedTurns(
        [store.writes.last],
        store,
        scheduleDrain: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        recovered.queuedTurns.single.turn.clientTurnId,
        'save-stop-terminal',
      );
      expect(recoveredGateway.submittedTexts, isEmpty);
    },
  );

  test(
    'Stop deja terminal fallido visible, bloqueado y reintentable',
    () async {
      final store = _MemoryOutbox()..failState = PreparedTurnState.terminal;
      final gateway = _DesktopGateway();
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-test',
          label: 'Test',
          host: 'example.invalid',
          port: 443,
          apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
          useHttps: true,
        ),
        sessionId: 'session-test',
        sessionTitle: 'Test',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.restoreQueuedTurns(
        [_queuedPrepared('terminal-retry', 'conservar bloqueado')],
        store,
        scheduleDrain: false,
      );

      await chat.cancel();
      expect(chat.queueParked, isTrue);
      expect(chat.queuedTurns, hasLength(1));
      expect(chat.queuedTurns.single.turn.clientTurnId, 'terminal-retry');
      expect(
        store.saveAttempts.where(
          (turn) => turn.state == PreparedTurnState.terminal,
        ),
        isEmpty,
      );
      expect(gateway.submittedTexts, isEmpty);

      store.failState = null;
      expect(chat.queuedTurns.single.turn.clientTurnId, 'terminal-retry');
      expect(gateway.submittedTexts, isEmpty);
    },
  );

  test('un turno nuevo reabre la admisión después de Stop seguro', () async {
    final store = _MemoryOutbox();
    final gateway = _DesktopGateway();
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      storedMessageLoader: (_, _) async => const [],
      terminalReconcileBudget: Duration.zero,
    );
    addTearDown(chat.dispose);

    await chat.restoreQueuedTurns(
      [_queuedPrepared('stop-before-reuse', 'cancelar primero')],
      store,
      scheduleDrain: false,
    );
    await chat.cancel();

    expect(
      await chat.send(
        fullText: 'nuevo turno',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    expect(chat.enqueue('seguimiento nuevo'), isTrue);
    gateway.emit('message.complete');
    await Future<void>.delayed(const Duration(milliseconds: 1800));

    expect(gateway.submittedTexts, ['nuevo turno', 'seguimiento nuevo']);
  });

  test('un Stop repetido conserva nuevas entradas estacionadas', () async {
    final store = _MemoryOutbox();
    final gateway = _DesktopGateway();
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
    );
    addTearDown(chat.dispose);

    await chat.restoreQueuedTurns(
      [_queuedPrepared('repeat-stop', 'cancelar')],
      store,
      scheduleDrain: false,
    );
    await chat.cancel();

    final repeatedStop = chat.cancel();
    final admittedDuringStop = chat.enqueue('conservar estacionado');
    await repeatedStop;

    expect(admittedDuringStop, isTrue);
    expect(chat.queueParked, isFalse);
    expect(chat.queuedTextMessages, contains('conservar estacionado'));
    expect(gateway.submittedTexts, isEmpty);
    expect(chat.queuedMessages, ['cancelar', 'conservar estacionado']);
  });

  test(
    'probe adversarial: Stop no recupera ownership ya transferido',
    () async {
      final store = _MemoryOutbox();
      final gateway = _DesktopGateway();
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-test',
          label: 'Test',
          host: 'example.invalid',
          port: 443,
          apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
          useHttps: true,
        ),
        sessionId: 'session-test',
        sessionTitle: 'Test',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
        storedMessageLoader: (_, _) async => const [],
        terminalReconcileBudget: Duration.zero,
      );
      addTearDown(chat.dispose);

      expect(
        await chat.send(
          fullText: 'turno vivo',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      expect(
        await chat.enqueuePreparedTurn(
          ActiveTurnDelivery(
            prepared: _queuedPrepared('transferred-owner', 'turno transferido'),
            store: store,
          ),
        ),
        isTrue,
      );
      gateway.emit('message.complete');
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      expect(gateway.submittedTexts, ['turno vivo', 'turno transferido']);
      expect(chat.queuedTurns, isEmpty);

      await chat.cancel();

      expect(chat.queuedTurns, isEmpty);
      expect(gateway.submittedTexts, ['turno vivo', 'turno transferido']);
    },
  );

  test(
    'probe adversarial: Stop persiste terminal antes de dispose tardío',
    () async {
      final transcriptSaveStarted = Completer<void>();
      final releaseTranscriptSave = Completer<void>();
      final store = _MemoryOutbox();
      final gateway = _DesktopGateway();
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-test',
          label: 'Test',
          host: 'example.invalid',
          port: 443,
          apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
          useHttps: true,
        ),
        sessionId: 'session-test',
        sessionTitle: 'Test',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
        onCancelledTurn: (_) async {
          transcriptSaveStarted.complete();
          await releaseTranscriptSave.future;
        },
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = [
        {'message_id': 'durable-user', 'role': 'user', 'content': 'turno vivo'},
      ];
      chat.messagesLoaded = true;

      await chat.restoreQueuedTurns(
        [_queuedPrepared('dispose-race', 'conservar terminal')],
        store,
        scheduleDrain: false,
      );

      final stop = chat.cancel();
      await transcriptSaveStarted.future;
      final terminalPrecededTranscript =
          store.writes.lastOrNull?.state == PreparedTurnState.terminal;
      chat.dispose();
      releaseTranscriptSave.complete();
      await stop;

      expect(terminalPrecededTranscript, isFalse);
      expect(store.writes, isEmpty);
      expect(store.deletes, isEmpty);
    },
  );

  test(
    'Stop RPC fallido queda sin confirmar y reintenta solo por usuario',
    () async {
      final gateway = _DesktopGateway()
        ..interruptError = StateError('interrupt rejected');
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: String.fromCharCodes([116, 101, 115, 116]),
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-stop-confirmation',
          label: 'Test',
          host: 'example.invalid',
          port: 443,
          apiKey: String.fromCharCodes([116, 101, 115, 116]),
          useHttps: true,
        ),
        sessionId: 'session-test',
        sessionTitle: 'Test',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);

      expect(
        await chat.send(
          fullText: 'turno vivo',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      await expectLater(chat.cancel(), throwsA(isA<StateError>()));
      expect(gateway.interruptCalls, 1);
      expect(chat.stopConfirmationState, StopConfirmationState.failed);
      expect(chat.state, ChatPipelineState.cancelled);

      gateway.interruptError = null;
      final retryGate = Completer<void>();
      gateway.interruptGate = retryGate;
      final retry = chat.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(chat.stopConfirmationState, StopConfirmationState.retrying);
      expect(gateway.interruptCalls, 2);
      retryGate.complete();
      await retry;
      expect(gateway.interruptCalls, 2);
      expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
      expect(chat.state, ChatPipelineState.cancelled);
    },
  );

  test('terminal autoritativo confirma Stop mientras espera el ACK', () async {
    final interruptGate = Completer<void>();
    final gateway = _DesktopGateway()..interruptGate = interruptGate;
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'not-a-secret',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-stop-completion-wins',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: 'not-a-secret',
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
    );
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    final stop = chat.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(gateway.interruptCalls, 1);
    expect(chat.stopConfirmationState, StopConfirmationState.stopping);

    gateway.emit('message.complete', {'text': 'terminó antes del Stop'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    interruptGate.complete();
    await stop;
    expect(chat.state, ChatPipelineState.cancelled);
    expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
    expect(gateway.interruptCalls, 1);
  });

  test(
    'Stop estaciona y reconcilia un prompt queued aceptado por gateway',
    () async {
      final gateway = _DesktopGateway()
        ..redirectDisposition = DesktopRedirectDisposition.queued;
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'not-a-secret',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-stop-gateway-queued',
          label: 'Test',
          host: 'example.invalid',
          port: 443,
          apiKey: 'not-a-secret',
          useHttps: true,
        ),
        sessionId: 'session-test',
        sessionTitle: 'Test',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);

      expect(
        await chat.send(
          fullText: 'turno vivo',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      await chat.steer('siguiente aceptado');
      expect(gateway.redirectedTexts, ['siguiente aceptado']);
      expect(chat.queuedTextMessages, ['siguiente aceptado']);

      await chat.cancel();
      expect(chat.queueParked, isTrue);
      expect(chat.queuedTextMessages, ['siguiente aceptado']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(gateway.submittedTexts, ['turno vivo']);

      chat.resumeParkedQueue();
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      expect(gateway.submittedTexts, ['turno vivo', 'siguiente aceptado']);
      expect(chat.queuedTextMessages, isEmpty);
    },
  );

  test(
    'Stop durante persistencia estaciona el turno preparado sin borrarlo',
    () async {
      final store = _BlockingSaveOutbox();
      final gateway = _DesktopGateway();
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: String.fromCharCodes([116, 101, 115, 116]),
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-test',
          label: 'Test',
          host: 'example.invalid',
          port: 443,
          apiKey: String.fromCharCodes([116, 101, 115, 116]),
          useHttps: true,
        ),
        sessionId: 'session-test',
        sessionTitle: 'Test',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);

      expect(
        await chat.send(
          fullText: 'turno vivo',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );

      final prepared = _prepared().copyWith(queued: true);
      final enqueueFuture = chat.enqueuePreparedTurn(
        ActiveTurnDelivery(prepared: prepared, store: store),
      );
      await store.saveStarted.future;

      final stop = chat.cancel();
      await Future<void>.delayed(Duration.zero);
      store.releaseSave.complete();
      await stop;

      expect(await enqueueFuture, isTrue);
      expect(chat.queueParked, isTrue);
      expect(chat.queuedTurns, hasLength(1));
      expect(chat.queuedTurns.single.turn.clientTurnId, 'turn-test');
      expect(store.deletes, isEmpty);
      expect(gateway.submittedTexts, ['turno vivo']);

      gateway.emit('message.complete');
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(gateway.submittedTexts, ['turno vivo']);

      chat.resumeParkedQueue();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(gateway.submittedTexts, ['turno vivo', 'mensaje']);
    },
  );

  test('dispose bloquea un drain ya agendado por enqueue', () async {
    var remoteRequests = 0;
    final gateway = _DesktopGateway();
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: String.fromCharCodes([116, 101, 115, 116]),
      httpClient: MockClient((_) async {
        remoteRequests++;
        return http.Response('{}', 500);
      }),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: String.fromCharCodes([116, 101, 115, 116]),
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      storedMessageLoader: (_, _) async => const [],
      terminalReconcileBudget: Duration.zero,
    );

    chat.enqueue('no debe salir');
    chat.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(gateway.submitCalls, 0);
    expect(remoteRequests, 0);
  });

  test('cola de texto nunca reabre fallback REST remoto', () async {
    var remoteRequests = 0;
    final gateway = _DesktopGateway()
      ..connectError = StateError('desktop unavailable before submit');
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: String.fromCharCodes([116, 101, 115, 116]),
      httpClient: MockClient((_) async {
        remoteRequests++;
        return http.Response('{"run_id":"unexpected"}', 200);
      }),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: String.fromCharCodes([116, 101, 115, 116]),
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
    );
    addTearDown(chat.dispose);

    chat.enqueue('texto en cola');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(remoteRequests, 0);
  });

  test('cola hereda el fence Desktop tras resetear el config staged', () async {
    var remoteRequests = 0;
    final gateway = _DesktopGateway();
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: String.fromCharCodes([116, 101, 115, 116]),
      httpClient: MockClient((_) async {
        remoteRequests++;
        return http.Response('{"run_id":"unexpected"}', 200);
      }),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: String.fromCharCodes([116, 101, 115, 116]),
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      storedMessageLoader: (_, _) async => const [],
      terminalReconcileBudget: Duration.zero,
    );
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno Desktop',
        model: 'hermes-agent',
        history: const [],
        sessionConfig: const DesktopSessionCreateConfig(
          allowTransportFallback: false,
        ),
      ),
      isTrue,
    );
    chat.enqueue('turno en cola');
    gateway.connectError = StateError(
      'desktop unavailable before queued submit',
    );
    gateway.emit('message.complete');
    await Future<void>.delayed(const Duration(milliseconds: 1800));

    expect(gateway.submittedTexts, ['turno Desktop']);
    expect(remoteRequests, 0);
  });

  test('cola preparada legacy nunca reabre fallback REST remoto', () async {
    var remoteRequests = 0;
    final store = _MemoryOutbox();
    final gateway = _DesktopGateway()
      ..connectError = StateError('desktop unavailable before submit');
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: String.fromCharCodes([116, 101, 115, 116]),
      httpClient: MockClient((_) async {
        remoteRequests++;
        return http.Response('{"run_id":"unexpected"}', 200);
      }),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: String.fromCharCodes([116, 101, 115, 116]),
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
    );
    addTearDown(chat.dispose);

    await chat.restoreQueuedTurns([_prepared().copyWith(queued: true)], store);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(remoteRequests, 0);
  });

  test('terminal drena una cola que solo contiene turno preparado', () async {
    final store = _MemoryOutbox();
    final gateway = _DesktopGateway();
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-key',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: 'test-key',
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      storedMessageLoader: (_, _) async => const [],
      terminalReconcileBudget: Duration.zero,
    );
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    final prepared = PreparedTurn(
      connectionId: 'conn-test',
      sessionId: 'session-test',
      clientTurnId: 'turno-preparado-unico',
      createdAtMs: 2000,
      updatedAtMs: 2000,
      queueOrder: 1,
      text: 'turno preparado',
      fullText: 'turno preparado',
      attachments: const [],
      model: 'hermes-agent',
      profile: '',
      queued: true,
    );
    expect(
      await chat.enqueuePreparedTurn(
        ActiveTurnDelivery(prepared: prepared, store: store),
      ),
      isTrue,
    );

    gateway.emit('message.complete');
    await Future<void>.delayed(const Duration(milliseconds: 1800));

    expect(gateway.submittedTexts, ['turno vivo', 'turno preparado']);
  });

  test(
    'barrera ambigua bloquea drenajes disparados por enqueues posteriores',
    () async {
      final store = _MemoryOutbox();
      final gateway = _DesktopGateway();
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-test',
          label: 'Test',
          host: 'example.invalid',
          port: 443,
          apiKey: 'test-key',
          useHttps: true,
        ),
        sessionId: 'session-test',
        sessionTitle: 'Test',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.restoreQueuedTurns(
        [_prepared().copyWith(queued: true)],
        store,
        scheduleDrain: false,
      );
      chat.enqueue('turno nuevo posterior');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(gateway.submittedTexts, isEmpty);
    },
  );

  test('ACK perdido no reintenta automáticamente el turno queued', () async {
    final store = _MemoryOutbox();
    final gateway = _DesktopGateway()
      ..submitError = TimeoutException('synthetic ack loss');
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-test',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: 'test',
        useHttps: true,
      ),
      sessionId: 'session-test',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
    );
    addTearDown(chat.dispose);
    final queued = _prepared().copyWith(queued: true);

    expect(
      await chat.enqueuePreparedTurn(
        ActiveTurnDelivery(prepared: queued, store: store),
      ),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 1800));

    expect(gateway.submitCalls, 1);
    expect(chat.queuedTurns, hasLength(1));
    expect(chat.queuedTurns.single.turn.state, PreparedTurnState.ambiguous);
  });

  test(
    'recuperación solo autoencola estados inequívocamente no enviados',
    () async {
      final store = _MemoryOutbox();
      final gateway = _DesktopGateway();
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'test',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-test',
          label: 'Test',
          host: 'example.invalid',
          port: 443,
          apiKey: 'test',
          useHttps: true,
        ),
        sessionId: 'session-test',
        sessionTitle: 'Test',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);
      await chat.restoreQueuedTurns([
        _prepared().copyWith(state: PreparedTurnState.prepared, queued: true),
        _prepared().copyWith(state: PreparedTurnState.ambiguous, queued: true),
        _prepared().copyWith(state: PreparedTurnState.submitting, queued: true),
      ], store);

      expect(chat.queuedTurns, hasLength(1));
      expect(chat.queuedTurns.single.turn.state, PreparedTurnState.prepared);
      expect(gateway.submitCalls, 0);
    },
  );
}
