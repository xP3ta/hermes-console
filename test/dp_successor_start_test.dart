// dp-G (Desktop parity): Desktop opens a turn on every `message.start`
// unless the user stopped it (apps/desktop/src/app/session/hooks/
// use-message-stream/gateway-event/message-stream.ts:143-212), trusting the
// transport's per-session seq dedupe (apps/shared/src/json-rpc-gateway.ts).
// Console keeps its terminal fence and admits a start the fence cannot order
// only when the frame proves it is new: live on the socket the chat holds
// now, not replayed, same replay epoch as the terminal and a higher seq.
// Everything else keeps the event-turn snapshot probe (event_turn_successor
// tests cover that path with a gateway that cannot vouch for its socket).

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

const _runtimeId = 'runtime-dp-successor';

class _LiveTransportGateway
    implements
        HermesDesktopGateway,
        HermesDesktopRecoverySessionLifecycleGateway,
        HermesDesktopLiveTransportGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  /// The server's per-session numbering survives a renewed socket.
  int sequence = 0;
  int generation = 1;
  Object channel = Object();
  String epoch = 'epoch-1';

  bool serverRunning = false;
  int recoveryReads = 0;

  void emit(
    String type, {
    Map<String, dynamic> payload = const {},
    bool sequenced = true,
    int? sequenceOverride,
    int? generationOverride,
    bool replayed = false,
  }) => _events.add(
    TuiGatewayEvent(
      type: type,
      sessionId: _runtimeId,
      payload: payload,
      sequence: sequenceOverride ?? (sequenced ? ++sequence : null),
      transportGeneration: generationOverride ?? generation,
      producerChannel: generationOverride == null ? channel : Object(),
      replayed: replayed,
    ),
  );

  /// App backgrounded or network changed while idle: a new transport.
  void renewSocket() {
    generation += 1;
    channel = Object();
  }

  @override
  bool isCurrentLiveTransport(int? generation, Object? producerChannel) =>
      generation == this.generation && identical(producerChannel, channel);

  @override
  String get currentReplayEpoch => epoch;

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
    return DesktopSessionSnapshot(
      runtimeSessionId: _runtimeId,
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

ActiveChat _chat(_LiveTransportGateway gateway) {
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: SavedConnection(
      id: 'conn-dp-successor',
      label: 'dp successor',
      host: 'example.invalid',
      port: 443,
      apiKey: 'test-only',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-dp-successor',
    sessionTitle: 'dp successor',
    notifications: null,
    onTerminal: () {},
    api: testApiClient(
      baseUrl: 'https://example.invalid',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
  );
  addTearDown(chat.dispose);
  return chat;
}

/// A chat whose own turn already ended with its answer; the terminal fence
/// holds that `message.complete`'s sequence.
Future<ActiveChat> _afterAnsweredTurn(_LiveTransportGateway gateway) async {
  final chat = _chat(gateway);
  expect(
    await chat.send(
      fullText: 'Lanza el ensayo',
      model: 'hermes-agent',
      history: const [],
    ),
    isTrue,
  );
  gateway.emit('message.start');
  gateway.emit(
    'message.complete',
    payload: const {'text': 'El ensayo ya está en marcha.'},
  );
  await _waitUntil(() => !chat.isStreaming);
  return chat;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a live start on the renewed socket with a higher seq opens the turn '
      'at once, with no snapshot read', () async {
    final gateway = _LiveTransportGateway();
    final chat = await _afterAnsweredTurn(gateway);
    final revision = chat.turnRevision;

    gateway.renewSocket();
    gateway.emit('message.start');
    await _settle();

    expect(chat.isStreaming, isTrue);
    expect(chat.turnRevision, greaterThan(revision));
    expect(gateway.recoveryReads, 0);

    gateway.emit(
      'message.complete',
      payload: const {'text': 'Los subagentes terminaron.'},
    );
    await _waitUntil(() => !chat.isStreaming);
    expect(
      chat.messages.where((m) => m['content'] == 'Los subagentes terminaron.'),
      hasLength(1),
    );
    expect(
      chat.messages.where(
        (m) => m['content'] == 'El ensayo ya está en marcha.',
      ),
      hasLength(1),
    );
  });

  test('a replayed start stays closed (the probe decides)', () async {
    final gateway = _LiveTransportGateway();
    final chat = await _afterAnsweredTurn(gateway);

    gateway.renewSocket();
    gateway.emit('message.start', replayed: true);
    await _settle();

    expect(chat.isStreaming, isFalse);
    expect(gateway.recoveryReads, 1);
  });

  test('an unsequenced start stays closed and reads nothing', () async {
    final gateway = _LiveTransportGateway();
    final chat = await _afterAnsweredTurn(gateway);

    gateway.renewSocket();
    gateway.emit('message.start', sequenced: false);
    await _settle();

    expect(chat.isStreaming, isFalse);
    expect(gateway.recoveryReads, 0);
  });

  test('a start not after the terminal seq stays closed', () async {
    final gateway = _LiveTransportGateway();
    final chat = await _afterAnsweredTurn(gateway);
    final terminalSequence = gateway.sequence;

    gateway.renewSocket();
    gateway.emit('message.start', sequenceOverride: terminalSequence);
    gateway.emit('message.start', sequenceOverride: terminalSequence - 1);
    await _settle();

    expect(chat.isStreaming, isFalse);
  });

  test('a start from a socket the gateway no longer holds stays closed',
      () async {
    final gateway = _LiveTransportGateway();
    final chat = await _afterAnsweredTurn(gateway);

    gateway.renewSocket();
    gateway.emit('message.start', generationOverride: gateway.generation - 1);
    await _settle();

    expect(chat.isStreaming, isFalse);
  });

  test('a rotated replay epoch (seq restarted) stays closed', () async {
    final gateway = _LiveTransportGateway();
    final chat = await _afterAnsweredTurn(gateway);

    gateway.renewSocket();
    gateway.epoch = 'epoch-2';
    gateway.emit('message.start');
    await _settle();

    expect(chat.isStreaming, isFalse);
  });

  test('after Stop a later start does not reopen the stopped chat', () async {
    final gateway = _LiveTransportGateway();
    final chat = await _afterAnsweredTurn(gateway);
    expect(
      await chat.send(
        fullText: 'Otro turno',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    gateway.emit('message.start');
    await _waitUntil(() => chat.isStreaming);
    await chat.cancel();
    await _waitUntil(() => !chat.isStreaming);
    expect(chat.state, ChatPipelineState.cancelled);

    gateway.renewSocket();
    gateway.emit('message.start');
    await _settle();

    expect(chat.isStreaming, isFalse);
  });

  test('a start on the same socket as the terminal still opens (fence)',
      () async {
    final gateway = _LiveTransportGateway();
    final chat = await _afterAnsweredTurn(gateway);

    gateway.emit('message.start');
    await _settle();

    expect(chat.isStreaming, isTrue);
    expect(gateway.recoveryReads, 0);
  });
}
