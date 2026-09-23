import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _RosterGateway
    implements HermesDesktopGateway, HermesDesktopSessionActivityGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  var interrupts = 0;

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
    runtimeSessionId: 'runtime-stop',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interrupts += 1;
  }

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async => const DesktopActiveSessionList(
    sessions: [
      DesktopActiveSession(
        runtimeSessionId: 'runtime-foreign',
        storedSessionId: 'stored-stop',
        status: 'working',
      ),
    ],
  );

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) => throw UnimplementedError();

  @override
  Future<void> close() async {
    await _events.close();
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
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}
}

ActiveChat _chat(_RosterGateway gateway) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: SavedConnection(
    id: 'conn-stop',
    label: 'Stop',
    host: 'example.invalid',
    port: 443,
    apiKey: 'test-key',
    useHttps: true,
    kind: InstanceKind.vps,
  ),
  sessionId: 'stored-stop',
  sessionTitle: 'Stop',
  initialStoredSessionId: 'stored-stop',
  notifications: null,
  onTerminal: () {},
  desktopGateway: gateway,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('roster working state is stoppable while the local pipeline is idle', () async {
    final gateway = _RosterGateway();
    final chat = _chat(gateway);
    addTearDown(chat.dispose);

    await chat.refreshPassiveRemoteActivity();

    expect(chat.state, ChatPipelineState.idle);
    expect(chat.sessionActivity.rosterTurn, isTrue);
    expect(chat.sending, isFalse);
    expect(chat.canStopSessionWork, isTrue);
  });
}
