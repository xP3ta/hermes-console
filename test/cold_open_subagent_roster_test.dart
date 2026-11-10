// cold-subagents: after the app was closed with a subagent working, reopening
// the chat adopts the still-running runtime and reads `subagent.list` once.
// That first read can come back without the children (or be dropped by its
// own fences), and the screen's next read is its 30/60 s backstop, so the
// capsule only appeared after reopening the chat. The adopted viewer now
// re-reads the roster a bounded number of times while work may be missing.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

const _runtimeId = 'runtime-cold';
const _storedId = 'stored-cold';

const _child = DesktopSubagentSnapshot(
  subagentId: 'child-cold',
  status: 'running',
  goal: 'Revisar el informe',
);

/// Gateway of a reopened app: `session.resume` answers with the parent turn
/// still running, and each `subagent.list` answers the next queued roster.
class _ColdGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSubagentGateway {
  _ColdGateway({this.running = true});

  final bool running;
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<List<DesktopSubagentSnapshot>> rosters = [];
  bool connected = false;
  int listCalls = 0;
  int resumeCalls = 0;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumeCalls += 1;
    return DesktopSessionSnapshot.fromJson(
      {
        'session_id': _runtimeId,
        'session_key': _storedId,
        'messages': const <Object>[],
        'running': running,
      },
      requestedStoredSessionId: _storedId,
      created: false,
      method: 'session.resume',
    );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => throw StateError('a cold open never creates a session');

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => throw StateError('a cold open never uses the legacy resume');

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<List<DesktopSubagentSnapshot>> listSubagents(
    String runtimeSessionId,
  ) async {
    listCalls += 1;
    return rosters.isEmpty ? const [] : rosters.removeAt(0);
  }

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
  ) async => DesktopSubagentInterruptResult(found: true, subagentId: subagentId);

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
    connected = false;
    if (!_events.isClosed) await _events.close();
  }
}

/// The own-turn path: a plain gateway whose first submit binds the runtime.
class _OwnTurnGateway
    implements HermesDesktopGateway, HermesDesktopSubagentGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  int listCalls = 0;

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
    runtimeSessionId: 'runtime-own',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<List<DesktopSubagentSnapshot>> listSubagents(
    String runtimeSessionId,
  ) async {
    listCalls += 1;
    return const [];
  }

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
  ) async => DesktopSubagentInterruptResult(found: true, subagentId: subagentId);

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

ActiveChat _chat(HermesDesktopGateway gateway, {String sessionId = _storedId}) =>
    ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'cold-subagents',
        label: 'Cold subagents',
        host: 'example.invalid',
        port: 443,
        apiKey: 'test-only',
        useHttps: true,
        kind: InstanceKind.vps,
      ),
      sessionId: sessionId,
      sessionTitle: 'Cold',
      notifications: null,
      onTerminal: () {},
      api: testApiClient(
        baseUrl: 'https://example.invalid',
        httpClient: MockClient(
          (_) async => http.Response('{"messages":[]}', 200),
        ),
      ),
      desktopGateway: gateway,
      attachDesktopRuntimeOnLoad: true,
      allowUnownedDesktopSnapshotForTesting: true,
    );

/// Reopens the chat the way the screen does: the visible chat owns the
/// presentation lease, then attaches the runtime that is still running.
Future<(ActiveChat, SubagentPresentationOwnerToken)> _coldOpen(
  WidgetTester tester,
  _ColdGateway gateway,
) async {
  final chat = _chat(gateway);
  final token = chat.acquireSubagentForegroundPresentation();
  chat.messagesLoaded = true;
  final attached = chat.attachExistingRuntimeViewer();
  for (var i = 0; i < 6; i += 1) {
    await tester.pump();
  }
  expect(await attached, isTrue);
  expect(chat.desktopRuntimeSessionId, _runtimeId);
  expect(chat.isStreaming, isTrue, reason: 'the parent turn is still running');
  return (chat, token);
}

/// Disposes the chat, then lets every fake timer it left behind fire inertly.
Future<void> _close(
  WidgetTester tester,
  ActiveChat chat,
  HermesDesktopGateway gateway,
) async {
  chat.dispose();
  await tester.pump(const Duration(minutes: 10));
  await gateway.close();
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'cold open with a running parent shows the roster that answers on the '
    'retry, without a manual refresh',
    (tester) async {
      final gateway = _ColdGateway()
        ..rosters.addAll([
          const <DesktopSubagentSnapshot>[],
          const [_child],
        ]);
      final (chat, _) = await _coldOpen(tester, gateway);

      expect(gateway.listCalls, 1, reason: 'one read when the runtime lands');
      expect(chat.subagentActivities, isEmpty);
      expect(chat.coldRosterRetryArmedForTesting, isTrue);

      await tester.pump(const Duration(milliseconds: 1499));
      expect(gateway.listCalls, 1);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(gateway.listCalls, 2);
      expect(chat.subagentActivities.map((a) => a.subagentId), [
        'child-cold',
      ]);
      expect(chat.conversationSubagents.map((a) => a.subagentId), [
        'child-cold',
      ]);

      // Visible: the ladder is over, no further reads.
      await tester.pump(const Duration(seconds: 20));
      expect(gateway.listCalls, 2);
      expect(chat.coldRosterRetryArmedForTesting, isFalse);
      expect(chat.subagentActivities, hasLength(1));

      await _close(tester, chat, gateway);
    },
  );

  testWidgets(
    'a roster that stays empty is re-read exactly three times, then stops',
    (tester) async {
      final gateway = _ColdGateway();
      final (chat, _) = await _coldOpen(tester, gateway);
      expect(gateway.listCalls, 1);

      await tester.pump(const Duration(milliseconds: 1500));
      expect(gateway.listCalls, 2);
      await tester.pump(const Duration(milliseconds: 2500));
      expect(gateway.listCalls, 3);
      await tester.pump(const Duration(seconds: 4));
      expect(gateway.listCalls, 4);

      await tester.pump(const Duration(seconds: 60));
      expect(gateway.listCalls, 4, reason: 'bounded: no storm, no poll');
      expect(chat.coldRosterRetryArmedForTesting, isFalse);
      expect(chat.subagentActivities, isEmpty);

      await _close(tester, chat, gateway);
    },
  );

  testWidgets('going to the background cancels the retries', (tester) async {
    final gateway = _ColdGateway();
    final (chat, _) = await _coldOpen(tester, gateway);
    expect(gateway.listCalls, 1);
    expect(chat.coldRosterRetryArmedForTesting, isTrue);

    chat.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(chat.coldRosterRetryArmedForTesting, isFalse);
    await tester.pump(const Duration(seconds: 20));
    expect(gateway.listCalls, 1);

    await _close(tester, chat, gateway);
  });

  testWidgets('covering the chat (lease released) cancels the retries', (
    tester,
  ) async {
    final gateway = _ColdGateway();
    final (chat, token) = await _coldOpen(tester, gateway);
    expect(chat.coldRosterRetryArmedForTesting, isTrue);

    expect(chat.releaseSubagentForegroundPresentation(token), isTrue);
    expect(chat.coldRosterRetryArmedForTesting, isFalse);
    await tester.pump(const Duration(seconds: 20));
    expect(gateway.listCalls, 1);

    await _close(tester, chat, gateway);
  });

  testWidgets('an idle reopened parent with nothing pending is not re-read', (
    tester,
  ) async {
    final gateway = _ColdGateway(running: false);
    final chat = _chat(gateway);
    chat.acquireSubagentForegroundPresentation();
    chat.messagesLoaded = true;
    final attached = chat.attachExistingRuntimeViewer();
    for (var i = 0; i < 6; i += 1) {
      await tester.pump();
    }
    expect(await attached, isTrue);
    expect(chat.isStreaming, isFalse);
    expect(gateway.listCalls, 1);

    await tester.pump(const Duration(seconds: 20));
    expect(gateway.listCalls, 1);

    await _close(tester, chat, gateway);
  });

  // subagent-roster (P0 composer at rest): the roster finds a child still
  // running in an idle reopened chat. The parent is NOT busy: Desktop's
  // composer reads only the session's busy (use-prompt-actions/utils.ts);
  // the child is reached through its own «Ejecutando 1 subagente» entry.
  testWidgets('an idle reopened parent with a running child stays at rest', (
    tester,
  ) async {
    final gateway = _ColdGateway(running: false)..rosters.add(const [_child]);
    final chat = _chat(gateway);
    chat.acquireSubagentForegroundPresentation();
    chat.messagesLoaded = true;
    final attached = chat.attachExistingRuntimeViewer();
    for (var i = 0; i < 6; i += 1) {
      await tester.pump();
    }
    expect(await attached, isTrue);
    expect(gateway.listCalls, 1);
    expect(chat.subagentActivities.map((a) => a.subagentId), ['child-cold']);
    expect(chat.safeActiveSubagentCount, 1);
    expect(chat.isStreaming, isFalse);
    expect(chat.onlySubagentsWork, isTrue);

    await _close(tester, chat, gateway);
  });

  testWidgets('the own-turn path never arms the retries', (tester) async {
    final gateway = _OwnTurnGateway();
    final chat = _chat(gateway, sessionId: 'stored-own');
    chat.acquireSubagentForegroundPresentation();
    expect(
      await chat.send(
        fullText: 'delegar',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    await tester.pump();
    expect(chat.isStreaming, isTrue);
    expect(chat.coldRosterRetryArmedForTesting, isFalse);
    final reads = gateway.listCalls;

    await tester.pump(const Duration(seconds: 20));
    expect(gateway.listCalls, reads);

    await _close(tester, chat, gateway);
  });
}
