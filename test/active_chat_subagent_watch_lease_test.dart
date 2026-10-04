import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/subagent_live_watch.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _Gateway
    implements
        HermesDesktopGateway,
        HermesDesktopSubagentGateway,
        SubagentWatchGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final submitted = <String>[];

  void emit(String type, Map<String, dynamic> payload) => _events.add(
    TuiGatewayEvent(type: type, sessionId: 'runtime-lease', payload: payload),
  );

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
    runtimeSessionId: 'runtime-lease',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async =>
      submitted.add(text);

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
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<List<DesktopSubagentSnapshot>> listSubagents(
    String runtimeSessionId,
  ) async => const [];

  @override
  Future<DesktopSubagentTailResult> tailSubagent(
    String runtimeSessionId,
    String subagentId,
  ) async => const DesktopSubagentTailResult(
    available: false,
    content: '',
    truncated: false,
  );

  @override
  Future<DesktopSubagentSteerResult> steerSubagent(
    String runtimeSessionId,
    String subagentId,
    String text,
  ) async => DesktopSubagentSteerResult(
    status: 'queued',
    subagentId: subagentId,
    text: text,
  );

  @override
  Future<DesktopSubagentInterruptResult> interruptSubagent(
    String runtimeSessionId,
    String subagentId,
  ) async =>
      DesktopSubagentInterruptResult(found: true, subagentId: subagentId);

  @override
  Future<DesktopSessionSnapshot> resumeWatchSession(
    String childSessionId, {
    required String profile,
  }) => throw UnimplementedError();

  @override
  Future<bool> closeSession(String runtimeSessionId) async => true;

  @override
  void retainSessionRuntime(String runtimeSessionId) {}

  @override
  void releaseSessionRuntime(String runtimeSessionId) {}

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

Future<ActiveChat> _start(HermesDesktopGateway gateway) async {
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: SavedConnection(
      id: 'conn-lease',
      label: 'Lease',
      host: 'example.invalid',
      port: 443,
      apiKey: 'test-only',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-lease',
    sessionTitle: 'Lease',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-only',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
  );
  chat.bindSessionProfile('parent-profile');
  chat.acquireSubagentForegroundPresentation();
  expect(
    await chat.send(fullText: 'delegar', model: 'hermes', history: const []),
    isTrue,
  );
  return chat;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('lends the chat gateway and its own profile for a live child', () async {
    final gateway = _Gateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    gateway.emit('subagent.start', const {
      'subagent_id': 'sa-lease',
      'child_session_id': 'child-lease',
      'status': 'running',
    });
    await _settle();
    final submittedBefore = gateway.submitted.length;

    final lease = chat.subagentWatchLease(chat.subagentActivities.single);

    expect(lease, isNotNull);
    expect(lease!.gateway, same(gateway), reason: 'no socket of its own');
    expect(lease.profile, 'parent-profile');
    expect(lease.isCurrent(), isTrue);
    expect(gateway.submitted, hasLength(submittedBefore));
  });

  test('the lease stops being current once the chat is disposed', () async {
    final gateway = _Gateway();
    final chat = await _start(gateway);
    gateway.emit('subagent.start', const {
      'subagent_id': 'sa-lease',
      'child_session_id': 'child-lease',
      'status': 'running',
    });
    await _settle();
    final activity = chat.subagentActivities.single;
    final lease = chat.subagentWatchLease(activity)!;

    chat.dispose();

    expect(lease.isCurrent(), isFalse);
    expect(chat.subagentWatchLease(activity), isNull);
  });

  test('no lease without a child session of its own', () async {
    final gateway = _Gateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    gateway.emit('subagent.start', const {
      'subagent_id': 'sa-no-child',
      'status': 'running',
    });
    await _settle();

    expect(chat.subagentWatchLease(chat.subagentActivities.single), isNull);
  });

  test(
    'a lease and a row captured before the child finished stop being valid',
    () async {
      final gateway = _Gateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      gateway.emit('subagent.start', const {
        'subagent_id': 'sa-old',
        'child_session_id': 'child-old',
        'status': 'running',
      });
      await _settle();
      final old = chat.subagentActivities.single;
      final lease = chat.subagentWatchLease(old)!;
      expect(lease.isCurrent(), isTrue);

      // The child ends in the same runtime and turn, with no message.complete.
      gateway.emit('subagent.complete', const {
        'subagent_id': 'sa-old',
        'child_session_id': 'child-old',
        'status': 'completed',
        'summary': 'listo',
      });
      await _settle();

      expect(chat.subagentWatchLease(old), isNull);
      expect(lease.isCurrent(), isFalse);
    },
  );

  test('no lease for a finished child', () async {
    final gateway = _Gateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    gateway.emit('subagent.start', const {
      'subagent_id': 'sa-done',
      'child_session_id': 'child-done',
      'status': 'running',
    });
    await _settle();
    gateway.emit('subagent.complete', const {
      'subagent_id': 'sa-done',
      'child_session_id': 'child-done',
      'status': 'completed',
      'summary': 'listo',
    });
    await _settle();

    expect(chat.subagentWatchLease(chat.subagentActivities.single), isNull);
  });
}
