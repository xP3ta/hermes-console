import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _RunningResumeGateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  _RunningResumeGateway(this.turnStartedAt);

  final DateTime turnStartedAt;
  final _events = StreamController<TuiGatewayEvent>.broadcast();

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
    runtimeSessionId: 'runtime-auto-continue',
    storedSessionId: storedSessionId,
    created: false,
    running: true,
    status: 'running',
    turnStartedAt: turnStartedAt,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => resumeSession(storedSessionId, profile: profile);

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => throw UnimplementedError();

  @override
  Future<void> close() async {
    await _events.close();
  }

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
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cold resume flags a running turn older than fifteen minutes', () async {
    final gateway = _RunningResumeGateway(
      DateTime.now().toUtc().subtract(const Duration(minutes: 16)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-auto-continue',
        label: 'Auto continue',
        host: 'example.invalid',
        port: 443,
        apiKey: 'test-key',
        useHttps: true,
        kind: InstanceKind.vps,
      ),
      sessionId: 'stored-auto-continue',
      sessionTitle: 'Auto continue',
      initialStoredSessionId: 'stored-auto-continue',
      notifications: null,
      onTerminal: () {},
      api: ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{"messages":[]}', 200)),
      ),
      desktopGateway: gateway,
      storedMessageLoader: (_, _) async => const [],
      attachDesktopRuntimeOnLoad: true,
      allowUnownedDesktopSnapshotForTesting: true,
      wallClockMs: () => DateTime.now().millisecondsSinceEpoch,
    );
    addTearDown(chat.dispose);

    await chat.loadMessages();

    expect(chat.isStreaming, isTrue);
    expect(chat.offerStaleResumedSessionStop, isTrue);
  });
}
