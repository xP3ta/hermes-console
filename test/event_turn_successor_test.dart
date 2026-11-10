// event-turn (Fold, 9960): when a delegated subagent ends, Hermes runs a turn
// of its own (`async_delegation_complete`) on the session. Its
// `message.start` came on a socket renewed since the previous turn closed, so
// no producer order placed it after that terminal: the chat dropped the start
// and every frame after it, the roster still said busy (stop button) and the
// durable rows of the running turn were painted as a finished «Trabajó ✓»
// block. A running snapshot of the same runtime now opens the turn.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

const _runtimeId = 'runtime-event-turn';

class _EventTurnGateway
    implements
        HermesDesktopGateway,
        HermesDesktopRecoverySessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  /// The server's per-session numbering survives a renewed socket.
  int sequence = 0;
  int generation = 1;
  Object channel = Object();

  bool serverRunning = false;
  String snapshotRuntimeId = _runtimeId;
  Completer<void>? recoveryGate;
  int recoveryReads = 0;

  void emit(
    String type, [
    Map<String, dynamic> payload = const {},
    bool sequenced = true,
  ]) => _events.add(
    TuiGatewayEvent(
      type: type,
      sessionId: _runtimeId,
      payload: payload,
      sequence: sequenced ? ++sequence : null,
      transportGeneration: generation,
      producerChannel: channel,
    ),
  );

  /// App backgrounded or network changed while idle: a new transport.
  void renewSocket() {
    generation += 1;
    channel = Object();
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
    runtimeSessionId: _runtimeId,
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    recoveryReads += 1;
    await recoveryGate?.future;
    return DesktopSessionSnapshot(
      runtimeSessionId: snapshotRuntimeId,
      storedSessionId: storedSessionId,
      created: false,
      running: serverRunning,
    );
  }

  @override
  // ignore: deprecated_member_use_from_same_package
  void commitRecoveryRuntime(String runtimeSessionId) {}

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

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A chat whose own turn already ended with its answer.
Future<ActiveChat> _afterAnsweredTurn(_EventTurnGateway gateway) async {
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: SavedConnection(
      id: 'conn-event-turn',
      label: 'Event turn',
      host: 'example.invalid',
      port: 443,
      apiKey: 'test-only',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-event-turn',
    sessionTitle: 'Event turn',
    notifications: null,
    onTerminal: () {},
    api: testApiClient(
      baseUrl: 'https://example.invalid',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
  );
  addTearDown(chat.dispose);
  expect(
    await chat.send(
      fullText: 'Pero qué hacemos ahora?',
      model: 'hermes-agent',
      history: const [],
    ),
    isTrue,
  );
  gateway.emit('message.start');
  gateway.emit('tool.start', const {
    'tool_id': 'call-first',
    'name': 'terminal',
    'args': {'command': 'ls'},
  });
  gateway.emit('tool.complete', const {
    'tool_id': 'call-first',
    'name': 'terminal',
    'result': {'output': 'ok'},
  });
  gateway.emit('message.complete', const {
    'text': 'El ensayo ya está en marcha.',
  });
  await _waitUntil(() => !chat.isStreaming);
  return chat;
}

List<String> _steps(ActiveChat chat) => [
  for (final message in chat.messages)
    if (message['role'] == 'assistant')
      for (final step in (message['_activity_trace'] as List?) ?? const [])
        if (step is Map) '${step['id']}:${step['status']}',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an event turn on a renewed socket opens live and settles once', () async {
    final gateway = _EventTurnGateway();
    final chat = await _afterAnsweredTurn(gateway);
    final revision = chat.turnRevision;
    final streaming = <bool>[chat.isStreaming];
    final subscription = chat.changes.listen((_) {
      if (streaming.last != chat.isStreaming) streaming.add(chat.isStreaming);
    });
    addTearDown(subscription.cancel);

    gateway.renewSocket();
    gateway.serverRunning = true;
    final gate = gateway.recoveryGate = Completer<void>();
    // The poller's start and `_run_prompt_submit`'s: one read.
    gateway.emit('message.start');
    gateway.emit('message.start');
    await _settle();
    expect(gateway.recoveryReads, 1);
    gate.complete();
    await _waitUntil(() => chat.isStreaming);
    expect(chat.turnRevision, greaterThan(revision));
    expect(gateway.recoveryReads, 1);

    gateway.emit('tool.start', const {
      'tool_id': 'call-event',
      'name': 'terminal',
      'args': {'command': 'git status'},
    });
    await _settle();
    expect(_steps(chat), contains('call-event:running'));
    expect(chat.messages.where((m) => m['_pipeline'] == true), hasLength(1));

    gateway.emit('tool.complete', const {
      'tool_id': 'call-event',
      'name': 'terminal',
      'result': {'output': 'clean'},
    });
    gateway.emit('message.complete', const {'text': 'La copia funciona.'});
    await _waitUntil(() => !chat.isStreaming);
    expect(
      chat.messages.where((m) => m['content'] == 'La copia funciona.'),
      hasLength(1),
    );
    expect(
      chat.messages.where(
        (m) => m['content'] == 'El ensayo ya está en marcha.',
      ),
      hasLength(1),
    );
    // Not streaming → streaming → not streaming: never back and forth.
    expect(streaming, [false, true, false]);
  });

  test('a terminal during the read is not left as a live turn', () async {
    final gateway = _EventTurnGateway();
    final chat = await _afterAnsweredTurn(gateway);
    final revision = chat.turnRevision;
    gateway.renewSocket();
    final gate = gateway.recoveryGate = Completer<void>();
    gateway.emit('message.start');
    gateway.emit('message.complete', const {'text': 'Hecho rápido.'});
    await _settle();
    // Hermes still reports running until its own cleanup clears it.
    gateway.serverRunning = true;
    gate.complete();
    await _settle();
    expect(gateway.recoveryReads, 1);
    expect(chat.isStreaming, isFalse);
    expect(chat.turnRevision, revision);
  });

  test('the same socket keeps the ordered start, with no read', () async {
    final gateway = _EventTurnGateway()..serverRunning = true;
    final chat = await _afterAnsweredTurn(gateway);
    gateway.emit('message.start');
    await _waitUntil(() => chat.isStreaming);
    expect(gateway.recoveryReads, 0);
  });

  test('an idle snapshot keeps an unordered start closed', () async {
    final gateway = _EventTurnGateway();
    final chat = await _afterAnsweredTurn(gateway);
    final revision = chat.turnRevision;
    gateway.renewSocket();
    gateway.emit('message.start');
    await _waitUntil(() => gateway.recoveryReads == 1);
    await _settle();
    gateway.emit('tool.start', const {
      'tool_id': 'call-stale',
      'name': 'terminal',
      'args': {'command': 'ls'},
    });
    await _settle();
    expect(chat.isStreaming, isFalse);
    expect(chat.turnRevision, revision);
    expect(_steps(chat), isNot(contains('call-stale:running')));
  });

  test('a running snapshot of another runtime keeps it closed', () async {
    final gateway = _EventTurnGateway()
      ..serverRunning = true
      ..snapshotRuntimeId = 'runtime-other';
    final chat = await _afterAnsweredTurn(gateway);
    gateway.renewSocket();
    gateway.emit('message.start');
    await _waitUntil(() => gateway.recoveryReads == 1);
    await _settle();
    expect(chat.isStreaming, isFalse);
  });

  test('an unsequenced start reads nothing', () async {
    final gateway = _EventTurnGateway()..serverRunning = true;
    final chat = await _afterAnsweredTurn(gateway);
    gateway.renewSocket();
    gateway.emit('message.start', const {}, false);
    await _settle();
    expect(gateway.recoveryReads, 0);
    expect(chat.isStreaming, isFalse);
  });

  test('repeated unordered starts are bounded per turn and socket', () async {
    final gateway = _EventTurnGateway();
    final chat = await _afterAnsweredTurn(gateway);
    gateway.renewSocket();
    for (var i = 0; i < 6; i++) {
      gateway.emit('message.start');
      await _settle();
    }
    expect(gateway.recoveryReads, 3);
    expect(chat.isStreaming, isFalse);
  });
}
