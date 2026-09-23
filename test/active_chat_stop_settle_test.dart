import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _SettleGateway implements HermesDesktopGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  var interruptCalls = 0;

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
    runtimeSessionId: 'runtime-settle',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interruptCalls++;
    _events.add(
      const TuiGatewayEvent(
        type: 'message.complete',
        sessionId: 'runtime-settle',
        payload: {'text': '', 'status': 'interrupted'},
      ),
    );
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
  Future<void> close() => _events.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('blank interrupted message.complete settles Stop without retiring runtime', () async {
    final gateway = _SettleGateway();
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-stop-settle',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: 'test-only',
        useHttps: true,
      ),
      sessionId: 'session-stop-settle',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'test-only',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      ),
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
    expect(chat.desktopRuntimeSessionId, 'runtime-settle');
    final bindEpoch = chat.desktopBindEpochForTesting;

    await chat.cancel();

    expect(gateway.interruptCalls, 1);
    expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
    expect(chat.desktopRuntimeSessionId, 'runtime-settle');
    expect(chat.desktopBindEpochForTesting, bindEpoch);
  });
}
