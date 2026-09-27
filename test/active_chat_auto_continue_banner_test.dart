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

  ActiveChat openChat(DateTime turnStartedAt) {
    final gateway = _RunningResumeGateway(turnStartedAt);
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
        httpClient: MockClient(
          (_) async => http.Response('{"messages":[]}', 200),
        ),
      ),
      desktopGateway: gateway,
      storedMessageLoader: (_, _) async => const [],
      attachDesktopRuntimeOnLoad: true,
      allowUnownedDesktopSnapshotForTesting: true,
      wallClockMs: () => DateTime.now().millisecondsSinceEpoch,
    );
    addTearDown(chat.dispose);
    return chat;
  }

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
        httpClient: MockClient(
          (_) async => http.Response('{"messages":[]}', 200),
        ),
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

  test('closing the stale Stop notice keeps the turn running and it does not '
      'reappear for that same turn, but a new turn warns again', () async {
    ActiveChat.debugResetDismissedStaleTurns();
    addTearDown(ActiveChat.debugResetDismissedStaleTurns);
    final turn = DateTime.now().toUtc().subtract(const Duration(minutes: 16));

    final first = openChat(turn);
    await first.loadMessages();
    expect(first.offerStaleResumedSessionStop, isTrue);
    first.dismissStaleResumedSessionStopOffer();
    expect(first.offerStaleResumedSessionStop, isFalse);
    expect(first.isStreaming, isTrue, reason: 'dismiss must not stop work');

    final reopened = openChat(turn);
    await reopened.loadMessages();
    expect(reopened.isStreaming, isTrue);
    expect(reopened.offerStaleResumedSessionStop, isFalse);

    final newTurn = openChat(turn.add(const Duration(seconds: 30)));
    await newTurn.loadMessages();
    expect(newTurn.offerStaleResumedSessionStop, isTrue);
  });
}
