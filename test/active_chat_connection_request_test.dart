// Connection prompts in the live chat: `connection.request` /
// `connection.update` events and the resume snapshot feed one open card per
// runtime session, bound to a tool row. Skip / Continue / wake go through
// the session owner; nothing is sent from a read-only connection. Fixtures
// are synthetic and links use an example host.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection_request.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/connection_request_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _runtime = 'runtime-conn';

class _Gateway implements HermesDesktopGateway, HermesConnectionRequestGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast(sync: true);

  /// Everything that reached the server, in order.
  final calls = <String>[];
  final responses =
      <({String runtime, String op, Map<String, dynamic> body})>[];
  final wakes = <({String runtime, String op})>[];
  Object? respondError;
  Completer<void>? respondGate;
  ConnectionRequest? pendingOnResume;

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
    runtimeSessionId: _runtime,
    storedSessionId: storedSessionId,
    created: false,
    pendingConnection: pendingOnResume,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    calls.add('submit:$text');
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
    String? requestId,
  }) async {}

  @override
  Future<void> respondToConnection(
    String runtimeSessionId,
    String opId,
    Map<String, dynamic> result,
  ) async {
    calls.add('respond');
    responses.add((runtime: runtimeSessionId, op: opId, body: result));
    final gate = respondGate;
    if (gate != null) await gate.future;
    if (respondError != null) throw respondError!;
  }

  @override
  Future<void> wakeConnectionOperation(
    String runtimeSessionId,
    String opId,
  ) async {
    calls.add('wake');
    wakes.add((runtime: runtimeSessionId, op: opId));
  }

  @override
  Future<void> close() async {}

  void emit(String type, Map<String, dynamic> payload) => _events.add(
    TuiGatewayEvent(
      type: type,
      sessionId: _runtime,
      payload: Map<String, dynamic>.unmodifiable(payload),
    ),
  );
}

Map<String, dynamic> _requestPayload({
  String opId = 'op-1',
  int seq = 1,
  String toolCallId = 'call-1',
  List<Map<String, dynamic>>? targets,
}) => {
  'op_id': opId,
  'seq': seq,
  'deadline_at': 1790000000.0,
  'timeout_seconds': 120,
  'tool_call_id': toolCallId,
  'targets':
      targets ??
      [
        {
          'name': 'gmail',
          'kind': 'connector',
          'action': 'authorize',
          'state': 'pending',
          'connect_url': 'https://connect.example.test/gmail',
        },
      ],
};

Map<String, dynamic> _updatePayload({
  String opId = 'op-1',
  int seq = 2,
  bool settled = false,
  String state = 'connected',
}) => {
  'op_id': opId,
  'seq': seq,
  'deadline_at': 1790000000.0,
  'settled': settled,
  if (settled) 'settled_by': 'all_resolved',
  'targets': [
    {'name': 'gmail', 'kind': 'connector', 'state': state},
  ],
};

Future<(ActiveChat, _Gateway, List<ActiveChatEvent>)> _liveChat({
  bool readOnly = false,
  ConnectionRequest? pendingOnResume,
}) async {
  final gateway = _Gateway()..pendingOnResume = pendingOnResume;
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: SavedConnection(
      id: 'conn-connection-request',
      label: 'Connection request',
      host: 'example.invalid',
      port: 443,
      apiKey: 'unused',
      useHttps: true,
      kind: InstanceKind.vps,
      readOnly: readOnly,
    ),
    sessionId: 'stored-conn',
    sessionTitle: 'Connection request',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'unused',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
  );
  final emitted = <ActiveChatEvent>[];
  chat.changes.listen(emitted.add);
  addTearDown(chat.dispose);
  // A read-only connection may not submit; the runtime still binds on the
  // first send attempt in the other tests, so bind through it either way.
  await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);
  gateway.calls.clear();
  return (chat, gateway, emitted);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a request binds a card to its tool row and re-renders it', () async {
    final (chat, gateway, emitted) = await _liveChat();
    emitted.clear();
    gateway.emit('connection.request', _requestPayload());
    await Future<void>.delayed(Duration.zero);

    final request = chat.connectionRequest!;
    expect(request.toolCallId, 'call-1');
    expect(request.targets.single.name, 'gmail');
    expect(emitted, contains(ActiveChatEvent.toolProgress));
  });

  test('unusable requests change nothing', () async {
    final (chat, gateway, _) = await _liveChat();
    gateway.emit('connection.request', {'op_id': 'op-1'});
    gateway.emit('connection.request', _requestPayload(toolCallId: ''));
    expect(chat.connectionRequest, isNull);
  });

  test(
    'updates follow seq order and a settled card keeps its final state',
    () async {
      final (chat, gateway, _) = await _liveChat();
      gateway.emit('connection.request', _requestPayload(seq: 3));
      gateway.emit(
        'connection.update',
        _updatePayload(seq: 2, state: 'failed'),
      );
      expect(
        chat.connectionRequest!.targets.single.state,
        ConnectionTargetState.pending,
      );
      gateway.emit('connection.update', _updatePayload(seq: 4, settled: true));
      expect(chat.connectionRequest!.settled, isTrue);
      expect(
        chat.connectionRequest!.targets.single.state,
        ConnectionTargetState.connected,
      );
      gateway.emit(
        'connection.update',
        _updatePayload(seq: 9, state: 'failed'),
      );
      expect(
        chat.connectionRequest!.targets.single.state,
        ConnectionTargetState.connected,
      );
      expect(chat.canActOnConnection, isFalse);
    },
  );

  test(
    'Not now and Continue send the exact bodies with the session owner',
    () async {
      final (chat, gateway, _) = await _liveChat();
      gateway.emit('connection.request', _requestPayload());
      expect(chat.canActOnConnection, isTrue);

      await chat.skipConnectionTarget('gmail');
      await chat.continueConnection();

      expect(
        gateway.responses.map(
          (r) => '${r.runtime}|${r.op}|${jsonEncode(r.body)}',
        ),
        [
          'runtime-conn|op-1|{"targets":[{"name":"gmail","status":"skipped"}]}',
          'runtime-conn|op-1|{"settled_by":"continue"}',
        ],
      );
    },
  );

  test('a read-only connection shows the card but never answers it', () async {
    final (chat, gateway, _) = await _liveChat(readOnly: true);
    gateway.emit('connection.request', _requestPayload());

    expect(chat.connectionRequest, isNotNull);
    expect(chat.canActOnConnection, isFalse);
    await chat.skipConnectionTarget('gmail');
    await chat.continueConnection();
    chat.noteConnectionLinkOpened();
    chat.connectionAppResumed();
    expect(gateway.calls, isEmpty);
  });

  test('coming back after opening a link wakes the operation once', () async {
    final (chat, gateway, _) = await _liveChat();
    gateway.emit('connection.request', _requestPayload());

    chat.connectionAppResumed();
    expect(gateway.wakes, isEmpty, reason: 'no link was opened');

    chat.noteConnectionLinkOpened();
    chat.connectionAppResumed();
    chat.connectionAppResumed();
    expect(gateway.wakes.map((w) => (w.runtime, w.op)), [(_runtime, 'op-1')]);

    // The next link opened earns the next wake.
    chat.noteConnectionLinkOpened();
    chat.connectionAppResumed();
    expect(gateway.wakes, hasLength(2));
  });

  test('a settled card is never woken', () async {
    final (chat, gateway, _) = await _liveChat();
    gateway.emit('connection.request', _requestPayload());
    chat.noteConnectionLinkOpened();
    gateway.emit('connection.update', _updatePayload(settled: true));
    chat.connectionAppResumed();
    expect(gateway.wakes, isEmpty);
  });

  test('a typed message sends Continue first and never waits for it', () async {
    final (chat, gateway, _) = await _liveChat();
    gateway.emit('connection.request', _requestPayload());
    gateway.respondGate = Completer<void>();

    expect(chat.enqueue('typed'), isTrue);
    expect(gateway.responses.single.body, {'settled_by': 'continue'});

    // The turn ends; the queued text goes out even though Continue is stuck.
    gateway.emit('message.complete', {'status': 'complete', 'text': 'ok'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(gateway.calls, ['respond', 'submit:typed']);
  });

  test('a failing Continue does not block the typed message', () async {
    final (chat, gateway, _) = await _liveChat();
    gateway.emit('connection.request', _requestPayload());
    gateway.respondError = const TuiGatewayRpcError(
      'connection.respond',
      'nope',
    );

    expect(chat.enqueue('typed'), isTrue);
    gateway.emit('message.complete', {'status': 'complete', 'text': 'ok'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(gateway.calls, contains('submit:typed'));
  });

  test('no card, no Continue', () async {
    final (chat, gateway, _) = await _liveChat();
    expect(chat.enqueue('typed'), isTrue);
    expect(gateway.responses, isEmpty);
  });

  test('a resume restores the pending card with the server deadline', () async {
    final pending = normalizeConnectionRequest(_requestPayload(seq: 7))!;
    final (chat, _, _) = await _liveChat(pendingOnResume: pending);

    final restored = chat.connectionRequest!;
    expect(restored.opId, 'op-1');
    expect(restored.seq, 7);
    expect(restored.deadlineAt, 1790000000.0);
  });

  test('a resume never revives an operation that already settled', () async {
    final (chat, gateway, _) = await _liveChat();
    gateway.emit('connection.request', _requestPayload());
    gateway.emit('connection.update', _updatePayload(settled: true));
    expect(chat.connectionRequest!.settled, isTrue);

    gateway.emit('connection.request', _requestPayload(seq: 9));
    expect(chat.connectionRequest!.seq, 2);
  });

  test(
    'late frames after dispose are ignored and nothing is emitted',
    () async {
      final (chat, gateway, emitted) = await _liveChat();
      gateway.emit('connection.request', _requestPayload());
      chat.dispose();
      emitted.clear();

      expect(
        () => gateway.emit('connection.update', _updatePayload(seq: 5)),
        returnsNormally,
      );
      expect(emitted, isEmpty);
      expect(chat.connectionRequest, isNull);
    },
  );
}
