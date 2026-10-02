import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

// qp1215: a queued turn outlives the chat screen that queued it. Its durable
// writes must follow the screen that owns the chat now, and a turn that could
// not be written must never leave a user bubble behind.

const _runtime = 'runtime-handoff';
const _profile = 'default';

final _connection = SavedConnection(
  id: 'qp1215-handoff',
  label: 'qp1215',
  host: 'example.invalid',
  port: 443,
  apiKey: 'unused',
  useHttps: true,
  kind: InstanceKind.vps,
);

ApiClient _unusedApi() => ApiClient(
  baseUrl: 'https://example.invalid',
  apiKey: 'unused',
  httpClient: MockClient((_) async => http.Response('unused', 500)),
);

class _HandoffGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopIdempotentGateway {
  final StreamController<TuiGatewayEvent> controller =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<String> submissions = [];
  final List<String> interrupts = [];

  void emit(String type, Map<String, dynamic> payload) => controller.add(
    TuiGatewayEvent(type: type, sessionId: _runtime, payload: payload),
  );

  @override
  Stream<TuiGatewayEvent> get events => controller.stream;
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
    runtimeSessionId: _runtime,
    storedSessionId: storedSessionId,
    created: false,
  );
  @override
  Future<DesktopSessionBinding> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) => resumeSession(storedSessionId, profile: profile);
  @override
  Future<DesktopSessionBinding> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => resumeSession('stored-handoff', profile: profile);
  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add(text);
  }

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    submissions.add(text);
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-$clientTurnId',
      state: DesktopTurnState.accepted,
      duplicate: false,
    );
  }

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String runtimeSessionId,
    String clientTurnId,
  ) async => DesktopTurnStatus(known: false, clientTurnId: clientTurnId);

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interrupts.add(runtimeSessionId);
    // The gateway settles the interrupted turn with its terminal.
    scheduleMicrotask(() => emit('message.complete', const {'text': 'cut'}));
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}
  @override
  Future<void> close() => controller.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  late ActiveChatService service;
  late _HandoffGateway gateway;

  setUp(() {
    secure.clear();
    SharedPreferences.setMockInitialValues({});
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
              case 'read':
                return secure[args['key'] as String];
              case 'delete':
                secure.remove(args['key'] as String);
              case 'readAll':
                return Map<String, String>.from(secure);
            }
            return null;
          },
        );
    service = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    gateway = _HandoffGateway();
  });

  tearDown(() async {
    service.dispose();
    await gateway.close();
  });

  /// One ChatScreen route: its own lifecycle and the outbox it writes with.
  ({LocalConversationLifecycle lifecycle, TurnOutboxStore outbox}) openScreen(
    String sessionId,
  ) {
    final lifecycle = LocalConversationCleanupFence.beginLifecycle(
      connectionId: _connection.id,
      profile: _profile,
      sessionId: sessionId,
    );
    expect(LocalConversationCleanupFence.rehydrate(lifecycle), isTrue);
    return (
      lifecycle: lifecycle,
      outbox: TurnOutboxStore(lifecycle: lifecycle),
    );
  }

  ActiveChat attach(String sessionId, LocalConversationLifecycle lifecycle) =>
      service.attach(
        connection: _connection,
        sessionId: sessionId,
        sessionTitle: 'qp1215',
        sessionProfile: _profile,
        initialStoredSessionId: sessionId,
        localConversationLifecycle: lifecycle,
        api: _unusedApi(),
        desktopGateway: gateway,
        allowUnownedDesktopSnapshotForTesting: true,
        disableForegroundKeepAlive: true,
      );

  ActiveTurnDelivery queued(
    String sessionId,
    String id,
    String text,
    TurnOutboxPersistence store,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return ActiveTurnDelivery(
      prepared: PreparedTurn(
        connectionId: _connection.id,
        sessionId: sessionId,
        clientTurnId: id,
        createdAtMs: now,
        updatedAtMs: now,
        text: text,
        fullText: text,
        desktopText: text,
        attachments: const [],
        model: 'hermes-agent',
        profile: _profile,
        state: PreparedTurnState.prepared,
        restoresComposer: true,
        queued: true,
      ),
      store: store,
    );
  }

  Future<void> settle([int rounds = 40]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  List<String> userRows(ActiveChat chat, String text) => chat.messages
      .where((row) => row['role'] == 'user' && row['content'] == text)
      .map((row) => row['content'] as String)
      .toList();

  List<Map<String, dynamic>> errorRows(ActiveChat chat) =>
      chat.messages.where((row) => row['role'] == 'assistant_error').toList();

  test('forcing a turn queued during compaction from a reopened chat sends '
      'it once with one bubble', () async {
    const session = 'stored-handoff-force';
    final first = openScreen(session);
    final chat = attach(session, first.lifecycle);
    expect(
      await chat.send(
        fullText: 'turno largo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    gateway.emit('status.update', const {'kind': 'compacting'});
    await settle(1);
    expect(chat.desktopCompressionInFlight, isTrue);
    expect(
      await chat.enqueuePreparedTurn(
        queued(session, 'forced', 'forzado', first.outbox),
      ),
      isTrue,
    );

    // The user leaves and opens the same conversation again: the first
    // route's producer retires and a new one owns the chat.
    LocalConversationCleanupFence.endLifecycle(first.lifecycle);
    final second = openScreen(session);
    expect(identical(attach(session, second.lifecycle), chat), isTrue);

    expect(await chat.sendQueuedNow('prepared:forced'), isTrue);
    await settle();
    // Compaction ends without a summary while the forced turn runs.
    gateway.emit('status.update', const {'kind': 'status', 'text': 'ready'});
    await settle(10);

    expect(gateway.interrupts, [_runtime]);
    expect(gateway.submissions, ['turno largo', 'forzado']);
    expect(userRows(chat, 'forzado'), ['forzado']);
    expect(errorRows(chat), isEmpty);
    expect(chat.queuedEntries, isEmpty);
    // The durable record followed the new owner instead of being rejected.
    final stored = await TurnOutboxStore().loadAllForChat(
      _connection.id,
      session,
      profile: _profile,
    );
    expect(
      stored.where((turn) => turn.clientTurnId == 'forced').map((t) => t.state),
      anyOf(isEmpty, everyElement(isNot(PreparedTurnState.prepared))),
    );

    gateway.emit('message.complete', const {'text': 'hecho'});
    await settle(20);
    expect(gateway.submissions, ['turno largo', 'forzado']);
    expect(userRows(chat, 'forzado'), ['forzado']);
  });

  test('a queued turn waits, without an error, while no chat screen can '
      'write it, and is sent once when the chat is opened again', () async {
    const session = 'stored-handoff-background';
    final first = openScreen(session);
    final chat = attach(session, first.lifecycle);
    expect(
      await chat.send(
        fullText: 'turno largo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    expect(
      await chat.enqueuePreparedTurn(
        queued(session, 'later', 'después', first.outbox),
      ),
      isTrue,
    );
    LocalConversationCleanupFence.endLifecycle(first.lifecycle);

    gateway.emit('message.complete', const {'text': 'hecho'});
    await settle();

    expect(gateway.submissions, ['turno largo']);
    expect(userRows(chat, 'después'), isEmpty);
    expect(errorRows(chat), isEmpty);
    expect(chat.queuedEntries.map((entry) => entry.text), ['después']);

    final second = openScreen(session);
    expect(identical(attach(session, second.lifecycle), chat), isTrue);
    await settle();

    expect(gateway.submissions, ['turno largo', 'después']);
    expect(userRows(chat, 'después'), ['después']);
    expect(errorRows(chat), isEmpty);
    expect(chat.queuedEntries, isEmpty);
  });

  test('a queued turn already running when the chat is reopened closes its '
      'durable record through the new screen', () async {
    const session = 'stored-handoff-running';
    final first = openScreen(session);
    final chat = attach(session, first.lifecycle);
    expect(
      await chat.send(
        fullText: 'turno largo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    expect(
      await chat.enqueuePreparedTurn(
        queued(session, 'running', 'en marcha', first.outbox),
      ),
      isTrue,
    );
    gateway.emit('message.complete', const {'text': 'hecho'});
    await settle(20);
    expect(gateway.submissions, ['turno largo', 'en marcha']);
    expect(chat.isStreaming, isTrue);

    LocalConversationCleanupFence.endLifecycle(first.lifecycle);
    final second = openScreen(session);
    expect(identical(attach(session, second.lifecycle), chat), isTrue);
    gateway.emit('message.complete', const {'text': 'respuesta'});
    await settle(20);

    expect(gateway.submissions, ['turno largo', 'en marcha']);
    expect(userRows(chat, 'en marcha'), ['en marcha']);
    final stored = await TurnOutboxStore().loadAllForChat(
      _connection.id,
      session,
      profile: _profile,
    );
    expect(stored.where((turn) => turn.clientTurnId == 'running'), isEmpty);
  });
}
