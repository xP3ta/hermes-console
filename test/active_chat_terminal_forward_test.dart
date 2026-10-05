// ActiveChat hands agent.terminal.output / terminal.close to a listener the
// terminal page attaches, and keeps nothing when none is attached.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/terminal_exec.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _FakeDesktopGateway
    implements HermesDesktopGateway, HermesTerminalGateway {
  @override
  bool get shellExecAvailable => true;

  @override
  Future<ShellExecResult> shellExec(
    String command, {
    required String profile,
  }) async => const ShellExecResult(stdout: '', stderr: '', exitCode: 0);

  @override
  Future<void> terminalResize(String runtimeSessionId, int cols) async {}

  @override
  Future<List<AgentProcessSeed>> agentProcessSeeds(
    String runtimeSessionId, {
    String? profile,
  }) async => const [];

  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast(sync: true);

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
    runtimeSessionId: 'runtime-contract',
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

  @override
  Future<void> close() async {}

  void emit(String type, Map<String, dynamic> payload) => _events.add(
    TuiGatewayEvent(
      type: type,
      sessionId: 'runtime-contract',
      payload: Map<String, dynamic>.unmodifiable(payload),
    ),
  );
}

Future<ActiveChat> _liveChat(_FakeDesktopGateway gateway) async {
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: SavedConnection(
      id: 'conn-contract',
      label: 'Contract',
      host: 'example.invalid',
      port: 443,
      apiKey: 'unused',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-contract',
    sessionTitle: 'Contract',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'unused',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
  );
  addTearDown(chat.dispose);
  expect(
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []),
    isTrue,
  );
  return chat;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'an attached listener receives chunks and closes by process id',
    () async {
      final gateway = _FakeDesktopGateway();
      final chat = await _liveChat(gateway);
      final seen = <(String, String, String)>[];
      chat.setAgentTerminalListener(
        (type, id, chunk) => seen.add((type, id, chunk)),
      );
      gateway.emit('agent.terminal.output', {
        'process_id': 'p1',
        'chunk': 'hi',
      });
      gateway.emit('terminal.close', {'process_id': 'p1'});
      expect(seen, [
        ('agent.terminal.output', 'p1', 'hi'),
        ('terminal.close', 'p1', ''),
      ]);
    },
  );

  test('with no listener nothing is kept and behaviour is unchanged', () async {
    final gateway = _FakeDesktopGateway();
    final chat = await _liveChat(gateway);
    final emitted = <ActiveChatEvent>[];
    final sub = chat.changes.listen(emitted.add);
    addTearDown(sub.cancel);
    gateway.emit('agent.terminal.output', {
      'process_id': 'p1',
      'chunk': 'secret',
    });
    await Future<void>.delayed(Duration.zero);
    expect(emitted, contains(ActiveChatEvent.subagentActivity));
    final seen = <String>[];
    chat.setAgentTerminalListener((_, _, chunk) => seen.add(chunk));
    expect(seen, isEmpty, reason: 'earlier chunks are not replayed');
  });

  test('detaching stops delivery', () async {
    final gateway = _FakeDesktopGateway();
    final chat = await _liveChat(gateway);
    final seen = <String>[];
    chat.setAgentTerminalListener((_, _, chunk) => seen.add(chunk));
    chat.setAgentTerminalListener(null);
    gateway.emit('agent.terminal.output', {'process_id': 'p1', 'chunk': 'x'});
    expect(seen, isEmpty);
  });

  test('a malformed event is dropped', () async {
    final gateway = _FakeDesktopGateway();
    final chat = await _liveChat(gateway);
    final seen = <String>[];
    chat.setAgentTerminalListener((_, _, chunk) => seen.add(chunk));
    gateway.emit('agent.terminal.output', {'process_id': 3, 'chunk': 'x'});
    gateway.emit('agent.terminal.output', {'chunk': 'x'});
    expect(seen, isEmpty);
  });

  test('the chat exposes its terminal gateway', () async {
    final chat = await _liveChat(_FakeDesktopGateway());
    expect(chat.terminalGateway, isNotNull);
  });
}
