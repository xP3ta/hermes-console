import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SubagentGateway
    implements HermesDesktopGateway, HermesDesktopSubagentGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  DesktopGatewayCapabilityState subagentCapability =
      DesktopGatewayCapabilityState.supported;
  Completer<DesktopSubagentInterruptResult>? interruptGate;
  int interruptCalls = 0;
  final List<String> interruptedIds = [];

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
    runtimeSessionId: 'runtime-subagent',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  void emit(
    String type,
    Map<String, dynamic> payload, {
    String sessionId = 'runtime-subagent',
  }) => _events.add(
    TuiGatewayEvent(type: type, sessionId: sessionId, payload: payload),
  );

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => subagentCapability;

  @override
  Future<DesktopSubagentInterruptResult> interruptSubagent(String subagentId) {
    interruptCalls += 1;
    interruptedIds.add(subagentId);
    return interruptGate?.future ??
        Future.value(
          DesktopSubagentInterruptResult(found: true, subagentId: subagentId),
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
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

class _RecordingNotifications extends NotificationService {
  _RecordingNotifications(super.prefs, {this.eventLog});

  final approvalIds = <String>[];
  final List<String>? eventLog;

  @override
  Future<void> approvalPending({
    required String tool,
    String? instance,
    String? connId,
    String? sessionId,
    String? sessionTitle,
    String? runId,
    String? approvalId,
    String? base,
    NotificationChatSurface surface = NotificationChatSurface.normal,
    String? profile,
    String? roomId,
  }) async {
    if (approvalId != null) approvalIds.add(approvalId);
  }

  @override
  Future<void> replyReady({
    required String preview,
    String? instance,
    String? session,
    String? connId,
    String? sessionId,
    NotificationChatSurface surface = NotificationChatSurface.normal,
    String? profile,
    String? roomId,
  }) async {
    eventLog?.add('show');
  }
}

Future<ActiveChat> _start(
  _SubagentGateway gateway, {
  NotificationService? notifications,
  Future<void> Function()? beforeTerminalNotification,
}) async {
  final chat = ActiveChat(
    connection: SavedConnection(
      id: 'conn-subagent',
      label: 'Subagent',
      host: 'example.invalid',
      port: 443,
      apiKey: 'test-only',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-subagent',
    sessionTitle: 'Subagent',
    notifications: notifications,
    onTerminal: () {},
    beforeTerminalNotification: beforeTerminalNotification,
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-only',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
  );
  expect(
    await chat.send(
      fullText: 'delegar',
      model: 'hermes-agent',
      history: const [],
    ),
    isTrue,
  );
  return chat;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'eventos nativos actualizan un único hijo y nunca emiten token',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      final events = <ActiveChatEvent>[];
      final subscription = chat.changes.listen(events.add);
      addTearDown(subscription.cancel);

      gateway.emit('subagent.start', const {
        'subagent_id': 'child-a',
        'child_session_id': 'child-session-a',
        'status': 'running',
      });
      gateway.emit('subagent.progress', const {
        'subagent_id': 'child-a',
        'task_index': 1,
        'task_count': 3,
      });
      gateway.emit('subagent.complete', const {
        'subagent_id': 'child-a',
        'status': 'completed',
        'summary': 'Trabajo finalizado',
      });
      await _settle();

      expect(chat.subagentActivities, hasLength(1));
      expect(
        chat.subagentActivities.single.phase,
        SubagentActivityPhase.completed,
      );
      expect(
        chat.subagentActivities.single.resultPreview,
        'Trabajo finalizado',
      );
      expect(events, isNot(contains(ActiveChatEvent.token)));
      expect(
        events.where((event) => event == ActiveChatEvent.subagentActivity),
        hasLength(3),
      );
    },
  );

  test(
    'terminal nativo absorbe start tardío y runtime ajeno se ignora',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('subagent.start', const {
        'subagent_id': 'foreign',
      }, sessionId: 'runtime-other');
      gateway.emit('subagent.complete', const {
        'subagent_id': 'child-a',
        'status': 'failed',
      });
      gateway.emit('subagent.start', const {
        'subagent_id': 'child-a',
        'status': 'running',
      });
      await _settle();

      expect(chat.subagentActivities, hasLength(1));
      expect(
        chat.subagentActivities.single.phase,
        SubagentActivityPhase.failed,
      );
    },
  );

  test('delegate_task dispatched permanece visible por tool_id real', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('tool.start', const {
      'name': 'delegate_task',
      'tool_id': 'call-a',
    });
    gateway.emit('tool.complete', const {
      'name': 'delegate_task',
      'tool_id': 'call-a',
      'result': {
        'status': 'dispatched',
        'delegation_id': 'deleg_1234abcd',
        'subagent_ids': ['sa-0-1234abcd'],
      },
      'summary': 'Resumen básico',
    });
    await _settle();

    expect(chat.subagentActivities, hasLength(1));
    final activity = chat.subagentActivities.single;
    expect(activity.source, SubagentActivitySource.legacyDelegateTask);
    expect(activity.phase, SubagentActivityPhase.running);
    expect(activity.canResumeChildTranscript, isFalse);
  });

  test('interrupt es single-flight y espera el estado autoritativo', () async {
    final gateway = _SubagentGateway()
      ..interruptGate = Completer<DesktopSubagentInterruptResult>();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('subagent.start', const {
      'subagent_id': 'child-interrupt',
      'child_session_id': 'child-session-interrupt',
      'status': 'running',
    });
    await _settle();
    final activity = chat.subagentActivities.single;

    final first = chat.interruptSubagent(activity);
    expect(chat.isSubagentInterruptPending(activity), isTrue);
    expect(chat.subagentActivities.single.phase, SubagentActivityPhase.running);
    await expectLater(
      chat.interruptSubagent(activity),
      throwsA(isA<StateError>()),
    );
    expect(gateway.interruptCalls, 1);
    expect(gateway.interruptedIds, ['child-interrupt']);

    gateway.interruptGate!.complete(
      const DesktopSubagentInterruptResult(
        found: false,
        subagentId: 'child-interrupt',
      ),
    );
    expect(await first, isFalse);
    expect(chat.isSubagentInterruptPending(activity), isFalse);
    expect(chat.subagentActivities.single.phase, SubagentActivityPhase.running);

    gateway.emit('subagent.complete', const {
      'subagent_id': 'child-interrupt',
      'status': 'cancelled',
    });
    await _settle();
    expect(
      chat.subagentActivities.single.phase,
      SubagentActivityPhase.cancelled,
    );
  });

  test('terminal notification stops the FGS before platform show', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final events = <String>[];
    final notifications = _RecordingNotifications(prefs, eventLog: events);
    final gateway = _SubagentGateway();
    final chat = await _start(
      gateway,
      notifications: notifications,
      beforeTerminalNotification: () async => events.add('stop'),
    );
    addTearDown(chat.dispose);

    gateway.emit('message.delta', const {'text': 'resultado'});
    gateway.emit('message.complete', const {'text': 'resultado'});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(events, ['stop', 'show']);
  });
}
