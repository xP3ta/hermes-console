import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

class _MemoryOutbox implements TurnOutboxPersistence {
  final List<PreparedTurn> writes = [];
  final List<PreparedTurn> deletes = [];
  PreparedTurnState? failState;

  @override
  Future<void> save(PreparedTurn turn) async {
    if (turn.state == failState) throw StateError('synthetic secure failure');
    writes.add(turn);
  }

  @override
  Future<void> delete(PreparedTurn turn) async => deletes.add(turn);
}

class _DesktopGateway implements HermesDesktopGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  Object? submitError;
  int submitCalls = 0;
  final List<String> submittedTexts = [];

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
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submitCalls++;
    submittedTexts.add(text);
    if (submitError case final error?) throw error;
  }

  @override
  Future<void> close() => _events.close();

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
  }) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}
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

  test('cola conjunta conserva FIFO entre texto y turno preparado', () async {
    final store = _MemoryOutbox();
    final gateway = _DesktopGateway();
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-key',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
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
    chat.enqueue('texto anterior');
    final prepared = PreparedTurn(
      connectionId: 'conn-test',
      sessionId: 'session-test',
      clientTurnId: 'turno-preparado-posterior',
      createdAtMs: 2000,
      updatedAtMs: 2000,
      text: 'adjunto posterior',
      fullText: 'adjunto posterior',
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

    expect(gateway.submittedTexts, ['turno vivo', 'texto anterior']);
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
