import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_fence_storage.dart';

/// Minimal fake — only what `ActiveChat` needs to reach a live desktop
/// runtime and let a `TuiGatewayEvent` through `_onDesktopEvent`.
class _FakeDesktopGateway implements HermesDesktopGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

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
    runtimeSessionId: 'runtime-bg',
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

  void emit(
    String type,
    Map<String, dynamic> payload, {
    String sessionId = 'runtime-bg',
  }) => _events.add(
    TuiGatewayEvent(type: type, sessionId: sessionId, payload: payload),
  );
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

ActiveChat _buildChat(_FakeDesktopGateway gateway) => ActiveChat(
  compressionFenceStore: testCompressionFenceStore(),
  connection: SavedConnection(
    id: 'conn-bg',
    label: 'Background',
    host: 'example.invalid',
    port: 443,
    apiKey: 'test-key',
    useHttps: true,
    kind: InstanceKind.vps,
  ),
  sessionId: 'stored-bg',
  sessionTitle: 'Background',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'test-key',
    httpClient: MockClient((_) async => http.Response('unused', 500)),
  ),
  desktopGateway: gateway,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('background.complete records a successful outcome by task_id', () async {
    final gateway = _FakeDesktopGateway();
    final chat = _buildChat(gateway);
    addTearDown(chat.dispose);

    expect(
      await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []),
      isTrue,
    );
    expect(chat.backgroundTaskOutcomes, isEmpty);

    gateway.emit('background.complete', const {
      'task_id': 'bg_abc123',
      'text': 'Listo: encontré 3 coincidencias.',
    });
    await _settle();

    expect(chat.backgroundTaskOutcomes, hasLength(1));
    final outcome = chat.backgroundTaskOutcomes['bg_abc123'];
    expect(outcome, isNotNull);
    expect(outcome!.isError, isFalse);
    expect(outcome.text, 'Listo: encontré 3 coincidencias.');
  });

  test('an "error:"-prefixed result is recorded as an error outcome', () async {
    final gateway = _FakeDesktopGateway();
    final chat = _buildChat(gateway);
    addTearDown(chat.dispose);

    expect(
      await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []),
      isTrue,
    );

    gateway.emit('background.complete', const {
      'task_id': 'bg_err1',
      'text': 'error: task timed out',
    });
    await _settle();

    final outcome = chat.backgroundTaskOutcomes['bg_err1'];
    expect(outcome, isNotNull);
    expect(outcome!.isError, isTrue);
  });

  test('dismissing a background task outcome removes only that entry', () async {
    final gateway = _FakeDesktopGateway();
    final chat = _buildChat(gateway);
    addTearDown(chat.dispose);

    expect(
      await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []),
      isTrue,
    );

    gateway.emit('background.complete', const {'task_id': 'bg_1', 'text': 'uno'});
    gateway.emit('background.complete', const {'task_id': 'bg_2', 'text': 'dos'});
    await _settle();
    expect(chat.backgroundTaskOutcomes, hasLength(2));

    chat.dismissBackgroundTaskOutcome('bg_1');
    expect(chat.backgroundTaskOutcomes.containsKey('bg_1'), isFalse);
    expect(chat.backgroundTaskOutcomes.containsKey('bg_2'), isTrue);
  });

  test('an event with a blank task_id is ignored', () async {
    final gateway = _FakeDesktopGateway();
    final chat = _buildChat(gateway);
    addTearDown(chat.dispose);

    expect(
      await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []),
      isTrue,
    );

    gateway.emit('background.complete', const {'task_id': '  ', 'text': 'x'});
    await _settle();

    expect(chat.backgroundTaskOutcomes, isEmpty);
  });
}
