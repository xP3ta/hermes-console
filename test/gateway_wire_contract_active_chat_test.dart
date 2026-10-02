// Every event Hermes' wire contract publishes, in every generated shape, is
// delivered to a live ActiveChat through the real `_onDesktopEvent` dispatch.
// The chat may ignore an event it does not render, but no contract-valid
// payload may throw inside the handler (an uncaught error in the event
// listener fails the test) and the ones it renders must still land.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/contract/gateway_contract.dart';
import 'support/in_memory_compression_restore_storage.dart';

class _FakeDesktopGateway implements HermesDesktopGateway {
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
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final contract = GatewayContract.load();
  final sampler = ContractSampler(contract);

  // Terminal events end the live turn, after which the chat (correctly)
  // ignores later turn events; run them last so every other one is seen by
  // an open turn.
  const terminal = {'message.complete', 'error'};
  final events = contract.eventNames.toList()
    ..sort((a, b) {
      final rank =
          (terminal.contains(a) ? 1 : 0) - (terminal.contains(b) ? 1 : 0);
      return rank != 0 ? rank : a.compareTo(b);
    });

  for (final event in events) {
    test('ActiveChat handles every contract shape of $event', () async {
      for (final sample in sampler.samples(
        contract.eventPayloadSchema(event),
      )) {
        // A fresh live turn per sample: one shape must not hide another.
        final gateway = _FakeDesktopGateway();
        final chat = await _liveChat(gateway);
        gateway.emit(event, sample.value);
        await Future<void>.delayed(Duration.zero);
        expect(chat.sessionId, 'stored-contract', reason: sample.label);
      }
    });
  }

  test('a rendered event still lands with every contract shape', () async {
    for (final sample in sampler.samples(
      contract.eventPayloadSchema('background.complete'),
    )) {
      final gateway = _FakeDesktopGateway();
      final chat = await _liveChat(gateway);
      gateway.emit('background.complete', sample.value);
      await Future<void>.delayed(Duration.zero);
      final taskId = sample.value['task_id'];
      if (taskId is String && taskId.trim().isNotEmpty) {
        expect(
          chat.backgroundTaskOutcomes.containsKey(taskId),
          isTrue,
          reason: sample.label,
        );
      }
    }
  });
}
