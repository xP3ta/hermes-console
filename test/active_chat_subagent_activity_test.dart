import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/subagent_transcript_projection.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_fence_storage.dart';

class _SubagentGateway
    implements HermesDesktopGateway, HermesDesktopSubagentGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  DesktopGatewayCapabilityState subagentCapability =
      DesktopGatewayCapabilityState.supported;
  Completer<DesktopSubagentInterruptResult>? interruptGate;
  Completer<List<DesktopSubagentSnapshot>>? listGate;
  int interruptCalls = 0;
  int listCalls = 0;
  final List<String> interruptedIds = [];
  final steerCalls = <({String runtimeId, String subagentId, String text})>[];
  DesktopSubagentSteerResult steerResult = const DesktopSubagentSteerResult(
    status: 'queued',
    subagentId: 'child-steer',
    text: '',
  );
  DesktopSubagentTailResult tailResult = const DesktopSubagentTailResult(
    available: false,
    content: '',
    truncated: false,
  );

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
  Future<List<DesktopSubagentSnapshot>> listSubagents(String runtimeSessionId) {
    listCalls += 1;
    return listGate?.future ?? Future.value(const []);
  }

  @override
  Future<DesktopSubagentTailResult> tailSubagent(
    String runtimeSessionId,
    String subagentId,
  ) async => tailResult;

  @override
  Future<DesktopSubagentSteerResult> steerSubagent(
    String runtimeSessionId,
    String subagentId,
    String text,
  ) async {
    steerCalls.add((
      runtimeId: runtimeSessionId,
      subagentId: subagentId,
      text: text,
    ));
    return DesktopSubagentSteerResult(
      status: steerResult.status,
      subagentId: subagentId,
      text: text,
    );
  }

  @override
  Future<DesktopSubagentInterruptResult> interruptSubagent(
    String runtimeSessionId,
    String subagentId,
  ) {
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
    compressionFenceStore: testCompressionFenceStore(),
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
  chat.acquireSubagentForegroundPresentation();
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

String _publicSubagentCanaryHaystack(Iterable<SubagentActivity> activities) =>
    activities
        .map(
          (activity) => [
            activity.key.scope.connectionId,
            activity.key.scope.profile,
            activity.key.scope.parentSessionId,
            activity.key.scope.runtimeSessionId,
            activity.key.scope.turnEpoch,
            activity.key.stableId,
            activity.subagentId,
            activity.delegationId,
            activity.childSessionId,
            activity.legacyToolCallId,
            activity.seenEventIds,
            activity.details.goalPreview,
            activity.details.detailPreview,
            activity.details.summaryPreview,
            activity.details.outputTailPreview,
            activity.details.parentId,
            activity.details.depth,
            activity.details.model,
            activity.details.progress,
            activity.details.toolCount,
            activity.details.toolsets,
            activity.details.filesReadCount,
            activity.details.filesWrittenCount,
            activity.details.activeToolName,
            activity.details.activeToolPreview,
            activity.details.acceptingSteer,
            activity.details.usage,
            activity.details.durationSeconds,
            activity.details.startedAt,
            activity.details.completedAt,
          ].join('|'),
        )
        .join('\n');

class _MountedSubagentProbe extends StatefulWidget {
  final ActiveChat chat;

  const _MountedSubagentProbe({required this.chat, super.key});

  @override
  State<_MountedSubagentProbe> createState() => _MountedSubagentProbeState();
}

class _MountedSubagentProbeState extends State<_MountedSubagentProbe> {
  StreamSubscription<ActiveChatEvent>? _subscription;
  int activityRebuilds = 0;

  @override
  void initState() {
    super.initState();
    _subscription = widget.chat.changes.listen((event) {
      if (event != ActiveChatEvent.subagentActivity || !mounted) return;
      setState(() => activityRebuilds += 1);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activities = widget.chat.subagentActivities;
    return MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      home: Scaffold(
        body: activities.isEmpty
            ? const SizedBox.shrink()
            : SubagentActivityCard(
                activities: activities,
                canInterrupt: (_) => false,
              ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'presentation owner tokens isolate sibling release and scrub only on 1 to 0',
    () async {
      final gateway = _SubagentGateway();
      final chat = ActiveChat(
        compressionFenceStore: testCompressionFenceStore(),
        connection: SavedConnection(
          id: 'conn-subagent',
          label: 'Subagent',
          host: 'example.invalid',
          port: 443,
          apiKey: 'test-key',
          useHttps: true,
          kind: InstanceKind.vps,
        ),
        sessionId: 'stored-subagent',
        sessionTitle: 'Subagent',
        notifications: null,
        onTerminal: () {},
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'test-key',
          httpClient: MockClient((_) async => http.Response('unused', 500)),
        ),
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);

      final ownerA = chat.acquireSubagentForegroundPresentation();
      expect(
        await chat.send(
          fullText: 'delegar',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      gateway.emit('subagent.start', const {
        'subagent_id': 'shared-owner-child',
        'status': 'running',
      });
      await _settle();
      expect(chat.subagentActivities, hasLength(1));

      final ownerB = chat.acquireSubagentForegroundPresentation();
      expect(ownerB, isNot(same(ownerA)));
      expect(chat.releaseSubagentForegroundPresentation(ownerA), isTrue);
      expect(chat.subagentActivities, hasLength(1));
      expect(chat.canTailSubagent(chat.subagentActivities.single), isTrue);

      final activity = chat.subagentActivities.single;
      expect(chat.releaseSubagentForegroundPresentation(ownerA), isFalse);
      expect(chat.subagentActivities, hasLength(1));
      expect(chat.releaseSubagentForegroundPresentation(ownerB), isTrue);
      expect(chat.subagentActivities, isEmpty);
      expect(chat.canTailSubagent(activity), isFalse);
    },
  );

  test(
    'zero-owner ingestion stays private and fresh empty proof publishes terminal history',
    () async {
      final gateway = _SubagentGateway()
        ..listGate = Completer<List<DesktopSubagentSnapshot>>();
      final chat = ActiveChat(
        compressionFenceStore: testCompressionFenceStore(),
        connection: SavedConnection(
          id: 'conn-private-ingestion',
          label: 'Private ingestion',
          host: 'example.invalid',
          port: 443,
          apiKey: 'test-key',
          useHttps: true,
          kind: InstanceKind.vps,
        ),
        sessionId: 'stored-private-ingestion',
        sessionTitle: 'Private ingestion',
        notifications: null,
        onTerminal: () {},
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'test-key',
          httpClient: MockClient((_) async => http.Response('unused', 500)),
        ),
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);
      expect(
        await chat.send(
          fullText: 'delegar en privado',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );

      gateway.emit('subagent.start', const {
        'subagent_id': 'PRIVATE_RETAINED_ID',
        'delegation_id': 'PRIVATE_RETAINED_DELEGATION',
        'goal': 'PRIVATE_RETAINED_GOAL',
        'model': 'PRIVATE_RETAINED_MODEL',
        'status': 'running',
      });
      await _settle();
      expect(chat.subagentActivities, isEmpty);
      expect(chat.subagentAggregate.activeCount, 1);
      expect(chat.subagentAggregate.phase, SubagentAggregatePhase.active);

      gateway.emit('subagent.complete', const {
        'subagent_id': 'PRIVATE_RETAINED_ID',
        'delegation_id': 'PRIVATE_RETAINED_DELEGATION',
        'summary': 'PRIVATE_TERMINAL_SUMMARY',
        'status': 'completed',
      });
      await _settle();
      expect(chat.subagentActivities, isEmpty);
      expect(chat.subagentAggregate.activeCount, 0);
      expect(chat.subagentAggregate.terminalCount, 1);
      expect(chat.subagentAggregate.phase, SubagentAggregatePhase.terminalOnly);

      final owner = chat.acquireSubagentForegroundPresentation();
      expect(chat.subagentActivities, isEmpty);
      final proof = chat.refreshSubagentsForTesting();
      gateway.listGate!.complete(const []);
      await proof;

      expect(chat.subagentActivities, hasLength(1));
      expect(chat.subagentActivities.single.isTerminal, isTrue);
      expect(
        chat.subagentActivities.single.resultPreview,
        'PRIVATE_TERMINAL_SUMMARY',
      );
      expect(chat.releaseSubagentForegroundPresentation(owner), isTrue);
      expect(chat.subagentActivities, isEmpty);
    },
  );

  test(
    'revoking an empty foreground fences pending list and later native canaries',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      await _settle();
      gateway.listGate = Completer<List<DesktopSubagentSnapshot>>();
      final pending = chat.refreshSubagentsForTesting();
      chat.suspendSubagentForegroundPresentation();
      gateway.listGate!.complete(const [
        DesktopSubagentSnapshot(
          subagentId: 'CANARY_SUBAGENT_ID',
          parentId: 'CANARY_PARENT_ID',
          depth: 7,
          goal: 'CANARY_GOAL_PROMPT',
          delegationId: 'CANARY_DELEGATION_ID',
          model: 'CANARY_MODEL',
          status: 'tool',
          toolCount: 9,
          lastTool: 'CANARY_TOOL_PATH',
          acceptingSteer: true,
        ),
      ]);
      await pending;
      gateway.emit('subagent.complete', const {
        'subagent_id': 'CANARY_POST_REVOKE_ID',
        'delegation_id': 'CANARY_POST_REVOKE_DELEGATION',
        'child_session_id': 'CANARY_CHILD_SESSION',
        'parent_id': 'CANARY_POST_REVOKE_PARENT',
        'goal': 'CANARY_POST_REVOKE_GOAL',
        'summary': 'CANARY_RAW_ERROR_RESULT',
        'output_tail': 'CANARY_POST_REVOKE_TAIL',
        'tool_name': 'CANARY_POST_REVOKE_TOOL',
        'tool_preview': '/CANARY/private/path',
        'model': 'CANARY_POST_REVOKE_MODEL',
        'status': 'failed',
      });
      await _settle();

      final projection = chat.subagentActivities;
      expect(projection, isEmpty);
      final haystack = _publicSubagentCanaryHaystack(projection);
      for (final canary in const [
        'CANARY_',
        '/CANARY/private/path',
        'runtime-subagent',
        'stored-subagent',
        'conn-subagent',
      ]) {
        expect(haystack, isNot(contains(canary)));
      }
    },
  );

  test('subagent list hydrates only live normalized rows after bind', () async {
    final gateway = _SubagentGateway()
      ..listGate = Completer<List<DesktopSubagentSnapshot>>();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.listGate!.complete(const [
      DesktopSubagentSnapshot(
        subagentId: 'child-hydrated',
        parentId: 'parent-agent',
        goal: 'Verificar hidratación',
        delegationId: 'deleg-hydrated',
        model: 'hermes-3',
        status: 'running',
        toolCount: 1,
        lastTool: 'terminal',
        acceptingSteer: true,
      ),
    ]);
    await _settle();

    expect(gateway.listCalls, 1);
    expect(chat.subagentActivities, hasLength(1));
    final activity = chat.subagentActivities.single;
    expect(activity.subagentId, 'child-hydrated');
    expect(activity.phase, SubagentActivityPhase.running);
    expect(activity.details.activeToolName, 'terminal');
    expect(activity.details.acceptingSteer, isTrue);
  });

  test('stale list response cannot overwrite newer live stream', () async {
    final gateway = _SubagentGateway()
      ..listGate = Completer<List<DesktopSubagentSnapshot>>();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('subagent.tool', const {
      'subagent_id': 'child-race',
      'status': 'tool',
      'tool_name': 'new-live-tool',
      'accepting_steer': true,
    });
    await _settle();
    gateway.listGate!.complete(const [
      DesktopSubagentSnapshot(
        subagentId: 'child-race',
        status: 'running',
        lastTool: 'old-snapshot-tool',
        acceptingSteer: true,
      ),
    ]);
    await _settle();

    expect(chat.subagentActivities.single.phase, SubagentActivityPhase.tool);
    expect(
      chat.subagentActivities.single.details.activeToolName,
      'new-live-tool',
    );
  });

  test(
    'delayed list from the preceding turn cannot populate the next turn',
    () async {
      final gateway = _SubagentGateway()
        ..listGate = Completer<List<DesktopSubagentSnapshot>>();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('message.complete', const {'text': 'first turn done'});
      await _settle();
      expect(
        await chat.send(
          fullText: 'next turn',
          model: 'hermes-agent',
          history: chat.messages,
        ),
        isTrue,
      );
      gateway.listGate!.complete(const [
        DesktopSubagentSnapshot(
          subagentId: 'stale-previous-turn-child',
          status: 'running',
          goal: 'must remain fenced',
        ),
      ]);
      await _settle();

      expect(chat.subagentActivities, isEmpty);
    },
  );

  test('empty list preserves useful local terminal state', () async {
    final gateway = _SubagentGateway()
      ..listGate = Completer<List<DesktopSubagentSnapshot>>();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    gateway.emit('subagent.complete', const {
      'subagent_id': 'child-terminal-local',
      'status': 'completed',
    });
    await _settle();

    gateway.listGate!.complete(const []);
    await _settle();

    expect(
      chat.subagentActivities.single.phase,
      SubagentActivityPhase.completed,
    );
  });

  test(
    'successor bind with the same runtime queues one fenced fresh list',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      await _settle();

      final gateA = Completer<List<DesktopSubagentSnapshot>>();
      gateway.listGate = gateA;
      final requestA = chat.refreshSubagentsForTesting();
      final callsWithA = gateway.listCalls;

      chat.suspendSubagentForegroundPresentation();
      chat.adoptDesktopRuntimeForTesting('runtime-transient');
      chat.adoptDesktopRuntimeForTesting('runtime-subagent');
      chat.acquireSubagentForegroundPresentation();
      final gateB = Completer<List<DesktopSubagentSnapshot>>();
      gateway.listGate = gateB;
      var requestBCompleted = false;
      final requestB = chat.refreshSubagentsForTesting().whenComplete(
        () => requestBCompleted = true,
      );

      // Distinct authority cuts supersede one another while the transport
      // request remains single-flight. Only the latest exact proof may run.
      expect(gateway.listCalls, callsWithA);
      gateA.complete(const [
        DesktopSubagentSnapshot(
          subagentId: 'stale-bind-a-child',
          status: 'running',
          goal: 'must not enter successor B',
        ),
      ]);
      await requestA;
      await _settle();
      expect(requestBCompleted, isFalse);
      expect(gateway.listCalls, callsWithA + 1);
      expect(chat.subagentActivities, isEmpty);

      gateB.complete(const [
        DesktopSubagentSnapshot(
          subagentId: 'fresh-bind-b-child',
          status: 'running',
          goal: 'fresh successor roster',
          acceptingSteer: true,
        ),
      ]);
      await requestB;

      expect(chat.subagentActivities, hasLength(1));
      final fresh = chat.subagentActivities.single;
      expect(fresh.subagentId, 'fresh-bind-b-child');
      expect(fresh.goalPreview, 'fresh successor roster');
      expect(fresh.phase, SubagentActivityPhase.running);
      expect(chat.canSteerSubagent(fresh), isTrue);
    },
  );

  test('authoritative empty list removes an absent running child', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    gateway.emit('subagent.start', const {
      'subagent_id': 'child-absent-from-roster',
      'delegation_id': 'deleg-absent-from-roster',
      'status': 'running',
      'event_revision': 1,
      'goal': 'stale live goal',
    });
    await _settle();
    expect(chat.activeSubagentCount, 1);

    gateway.listGate = Completer<List<DesktopSubagentSnapshot>>();
    final refresh = chat.refreshSubagentsForTesting();
    gateway.listGate!.complete(const []);
    await refresh;

    expect(chat.subagentActivities, isEmpty);
    expect(chat.activeSubagentCount, 0);
  });

  test('authoritative mixed list retains only present live rows', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    gateway.emit('subagent.start', const {
      'subagent_id': 'child-present',
      'delegation_id': 'deleg-present',
      'status': 'running',
      'goal': 'old present goal',
    });
    gateway.emit('subagent.start', const {
      'subagent_id': 'child-missing',
      'delegation_id': 'deleg-missing',
      'status': 'running',
      'goal': 'must be removed',
    });
    await _settle();
    expect(chat.subagentActivities, hasLength(2));

    gateway.listGate = Completer<List<DesktopSubagentSnapshot>>();
    final refresh = chat.refreshSubagentsForTesting();
    gateway.listGate!.complete(const [
      DesktopSubagentSnapshot(
        subagentId: 'child-present',
        delegationId: 'deleg-present',
        status: 'running',
        goal: 'authoritative present goal',
        acceptingSteer: true,
      ),
    ]);
    await refresh;

    expect(chat.subagentActivities, hasLength(1));
    final present = chat.subagentActivities.single;
    expect(present.subagentId, 'child-present');
    expect(present.delegationId, 'deleg-present');
    expect(present.goalPreview, 'authoritative present goal');
    expect(present.phase, SubagentActivityPhase.running);
    expect(chat.canSteerSubagent(present), isTrue);
    expect(chat.activeSubagentCount, 1);
  });

  test(
    'recycled child id without secondary proof remains distinct across runtimes',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('subagent.start', const {
        'subagent_id': 'recycled-x',
        'status': 'running',
        'goal': 'runtime R1 row',
      });
      await _settle();
      chat.adoptDesktopRuntimeForTesting('runtime-r2-distinct');
      gateway.emit('subagent.start', const {
        'subagent_id': 'recycled-x',
        'status': 'running',
        'goal': 'runtime R2 row',
      }, sessionId: 'runtime-r2-distinct');
      await _settle();

      // Runtime rotation revokes the predecessor disclosure cut. The exact R2
      // event proves only the successor incarnation; retained R1 evidence stays
      // private until an authoritative current roster proves it publishable.
      expect(chat.subagentActivities, hasLength(1));
      final successor = chat.subagentActivities.single;
      expect(successor.goalPreview, 'runtime R2 row');
      expect(successor.phase, SubagentActivityPhase.running);
      expect(successor.key.scope.runtimeSessionId, 'runtime-r2-distinct');
    },
  );

  test(
    'runtime rotation starts a clean incarnation for a reused child id',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      gateway.emit('subagent.start', const {
        'subagent_id': 'reused-child',
        'status': 'running',
        'revision': 99,
        'goal': 'R1 private-safe goal',
        'tool_name': 'r1-tool',
        'accepting_steer': true,
      });
      await _settle();
      expect(chat.canSteerSubagent(chat.subagentActivities.single), isTrue);

      chat.adoptDesktopRuntimeForTesting('runtime-r2');
      await _settle();
      // A successor runtime starts in mandatory pending-proof state. Keeping a
      // neutralized R1 row public here would still disclose its goal/key before
      // R2 proves the current presentation cut.
      expect(chat.subagentActivities, isEmpty);

      gateway.emit('subagent.complete', const {
        'subagent_id': 'reused-child',
        'status': 'completed',
      }, sessionId: 'runtime-subagent');
      await _settle();
      expect(chat.subagentActivities, isEmpty);

      gateway.emit('subagent.start', const {
        'subagent_id': 'reused-child',
        'status': 'running',
        'revision': 1,
        'goal': 'R2 authoritative goal',
        'tool_name': 'r2-tool',
        'accepting_steer': true,
      }, sessionId: 'runtime-r2');
      await _settle();
      final r2 = chat.subagentActivities.singleWhere(
        (activity) => activity.key.scope.runtimeSessionId == 'runtime-r2',
      );
      expect(r2.eventRevision, 1);
      expect(r2.goalPreview, 'R2 authoritative goal');
      expect(r2.details.activeToolName, 'r2-tool');
      expect(r2.seenEventIds, isEmpty);
      expect(chat.canSteerSubagent(r2), isTrue);
      expect(chat.canTailSubagent(r2), isTrue);
      expect(chat.canInterruptSubagent(r2), isTrue);

      gateway.emit('subagent.tool', const {
        'subagent_id': 'reused-child',
        'status': 'tool',
        'revision': 100,
        'goal': 'late R1 goal',
        'tool_name': 'late-r1-tool',
      }, sessionId: 'runtime-subagent');
      await _settle();
      final unchangedR2 = chat.subagentActivities.singleWhere(
        (activity) => activity.key.scope.runtimeSessionId == 'runtime-r2',
      );
      expect(unchangedR2.goalPreview, 'R2 authoritative goal');
      expect(unchangedR2.details.activeToolName, 'r2-tool');

      gateway.listGate = Completer<List<DesktopSubagentSnapshot>>();
      final emptyList = chat.refreshSubagentsForTesting();
      gateway.listGate!.complete(const []);
      await emptyList;
      expect(chat.subagentActivities, isEmpty);
      expect(chat.canSteerSubagent(r2), isFalse);
      expect(chat.canTailSubagent(r2), isFalse);
      expect(chat.canInterruptSubagent(r2), isFalse);
    },
  );

  test(
    'steer gates ownership and accepting flag without optimistic activity',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      gateway.emit('subagent.start', const {
        'subagent_id': 'child-steer',
        'status': 'running',
        'accepting_steer': false,
      });
      await _settle();
      final rejectedLocally = chat.subagentActivities.single;

      await expectLater(
        chat.steerSubagent(rejectedLocally, 'draft retained'),
        throwsA(isA<StateError>()),
      );
      expect(gateway.steerCalls, isEmpty);

      gateway.emit('subagent.progress', const {
        'subagent_id': 'child-steer',
        'status': 'running',
        'accepting_steer': true,
      });
      await _settle();
      final live = chat.subagentActivities.single;
      final before = chat.subagentActivities.single;
      gateway.steerResult = const DesktopSubagentSteerResult(
        status: 'queued',
        subagentId: 'child-steer',
        text: 'keep this draft',
      );

      final queued = await chat.steerSubagent(live, 'keep this draft');

      expect(queued.queued, isTrue);
      expect(gateway.steerCalls.single, (
        runtimeId: 'runtime-subagent',
        subagentId: 'child-steer',
        text: 'keep this draft',
      ));
      expect(identical(chat.subagentActivities.single, before), isTrue);
    },
  );

  test('tail requires an exact current native child', () async {
    final gateway = _SubagentGateway()
      ..tailResult = const DesktopSubagentTailResult(
        available: true,
        content: 'safe tail',
        truncated: false,
      );
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    gateway.emit('subagent.start', const {
      'subagent_id': 'child-tail',
      'status': 'running',
    });
    await _settle();

    final tail = await chat.tailSubagent(chat.subagentActivities.single);

    expect(tail.available, isTrue);
    expect(tail.content, 'safe tail');
  });

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
    'same runtime recycled subagent id starts a mounted successor row in next turn',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('subagent.complete', const {
        'subagent_id': 'turn-recycled-child',
        'status': 'completed',
        'event_revision': 1,
      });
      gateway.emit('message.complete', const {'text': 'turn E complete'});
      await _settle();
      expect(
        chat.subagentActivities.single.phase,
        SubagentActivityPhase.completed,
      );

      expect(
        await chat.send(
          fullText: 'turn E plus one',
          model: 'hermes-agent',
          history: chat.messages,
        ),
        isTrue,
      );
      gateway.emit('subagent.start', const {
        'subagent_id': 'turn-recycled-child',
        'status': 'running',
        'event_revision': 1,
      });
      await _settle();

      expect(chat.subagentActivities, hasLength(2));
      final successor = chat.subagentActivities.singleWhere(
        (activity) => activity.phase == SubagentActivityPhase.running,
      );
      expect(successor.subagentId, 'turn-recycled-child');
      expect(successor.key.scope.turnEpoch, greaterThan(0));
    },
  );

  test(
    '[console-state 6/7] terminal subagent tombstone absorbs late live event',
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

  test('durable completion hides the matching live activity', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('subagent.start', {
      'event_id': 'evt-durable-start',
      'subagent_id': 'sa-durable',
      'delegation_id': 'deleg_c0ffee12',
      'revision': 1,
    });
    await _settle();
    expect(chat.subagentActivities, hasLength(1));

    chat.internalMessagesForTesting = projectHistoricalSubagentCompletions(
      messagesNewestFirst: [
        {
          'message_id': 'durable-marker',
          'role': 'user',
          'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_c0ffee12]',
          'display_kind': 'async_delegation_complete',
          'display_metadata': {
            'delegation_id': 'deleg_c0ffee12',
            'task_count': 1,
            'completed_count': 1,
            'failed_count': 0,
            'subagent_ids': ['sa-durable'],
          },
        },
      ],
    );

    expect(chat.subagentActivities, isEmpty);
    expect(
      chat.messages
          .map(historicalSubagentCompletionOf)
          .whereType<SubagentCompletionCardData>(),
      hasLength(1),
    );
  });

  test(
    'durable completion matches delegation and exact child identity',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('subagent.start', const {
        'subagent_id': 'child-b',
        'delegation_id': 'delegation-reused',
        'child_session_id': 'child-session-b',
        'status': 'running',
        'goal': 'new live child B',
      });
      await _settle();

      chat.internalMessagesForTesting = projectHistoricalSubagentCompletions(
        messagesNewestFirst: [
          {
            'message_id': 'old-card-a',
            'role': 'user',
            'content': '[ASYNC DELEGATION BATCH COMPLETE — delegation-reused]',
            'display_kind': 'async_delegation_complete',
            'display_metadata': {
              'delegation_id': 'delegation-reused',
              'task_count': 1,
              'completed_count': 1,
              'failed_count': 0,
              'subagent_ids': ['child-a'],
            },
          },
        ],
      );

      expect(chat.subagentActivities, hasLength(1));
      final live = chat.subagentActivities.single;
      expect(live.subagentId, 'child-b');
      expect(live.childSessionId, 'child-session-b');
      expect(live.delegationId, 'delegation-reused');
      expect(live.phase, SubagentActivityPhase.running);
      expect(live.goalPreview, 'new live child B');
    },
  );

  test('historical dispatched row never enables interrupt', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('tool.complete', const {
      'name': 'delegate_task',
      'tool_id': 'call-historical',
      'result': {
        'status': 'dispatched',
        'delegation_id': 'deleg_deadbeef',
        'subagent_ids': ['sa-0-deadbeef'],
      },
    });
    await _settle();

    final activity = chat.subagentActivities.single;
    expect(activity.phase, SubagentActivityPhase.unknown);
    expect(chat.canInterruptSubagent(activity), isFalse);
    await expectLater(
      chat.interruptSubagent(activity),
      throwsA(isA<StateError>()),
    );
    expect(gateway.interruptCalls, 0);
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

  test(
    'retired interrupt A cannot clear or receive successor B pending state',
    () async {
      final gateA = Completer<DesktopSubagentInterruptResult>();
      final gateway = _SubagentGateway()..interruptGate = gateA;
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('subagent.start', const {
        'subagent_id': 'recycled-interrupt-child',
        'delegation_id': 'delegation-a',
        'child_session_id': 'child-session-a',
        'status': 'running',
      });
      await _settle();
      final activityA = chat.subagentActivities.single;
      final requestA = chat.interruptSubagent(activityA);
      expect(chat.isSubagentInterruptPending(activityA), isTrue);

      chat.suspendSubagentForegroundPresentation();
      chat.adoptDesktopRuntimeForTesting('runtime-transient');
      chat.adoptDesktopRuntimeForTesting('runtime-subagent');
      chat.acquireSubagentForegroundPresentation();
      gateway.emit('subagent.start', const {
        'subagent_id': 'recycled-interrupt-child',
        'delegation_id': 'delegation-b',
        'child_session_id': 'child-session-b',
        'status': 'running',
      });
      await _settle();
      final activityB = chat.subagentActivities.single;
      final gateB = Completer<DesktopSubagentInterruptResult>();
      gateway.interruptGate = gateB;
      final requestB = chat.interruptSubagent(activityB);
      expect(chat.isSubagentInterruptPending(activityB), isTrue);

      gateA.complete(
        const DesktopSubagentInterruptResult(
          found: true,
          subagentId: 'recycled-interrupt-child',
        ),
      );
      expect(await requestA, isFalse);
      expect(chat.isSubagentInterruptPending(activityB), isTrue);

      gateB.complete(
        const DesktopSubagentInterruptResult(
          found: true,
          subagentId: 'recycled-interrupt-child',
        ),
      );
      expect(await requestB, isTrue);
      expect(chat.isSubagentInterruptPending(activityB), isFalse);
    },
  );

  test('parent terminal does not complete live child', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('subagent.start', const {
      'subagent_id': 'child-late-complete',
      'status': 'running',
      'event_id': 'late-start-1',
      'event_revision': 1,
    });
    await _settle();
    expect(chat.subagentActivities.single.phase, SubagentActivityPhase.running);

    gateway.emit('message.complete', const {'text': 'respuesta final'});
    await _settle();

    expect(chat.subagentActivities, hasLength(1));
    expect(chat.isStreaming, isFalse);
    expect(chat.subagentActivities.single.phase, SubagentActivityPhase.running);
  });

  test('background child progress stays live after parent terminal', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('subagent.start', const {
      'subagent_id': 'child-background-progress',
      'status': 'running',
      'event_id': 'background-start',
      'event_revision': 1,
    });
    gateway.emit('message.complete', const {'text': 'parent finished'});
    await _settle();
    expect(chat.isStreaming, isFalse);

    gateway.emit('subagent.progress', const {
      'subagent_id': 'child-background-progress',
      'status': 'running',
      'event_id': 'background-progress',
      'event_revision': 2,
      'task_index': 1,
      'task_count': 3,
    });
    await _settle();

    expect(chat.isStreaming, isFalse);
    expect(chat.subagentActivities, hasLength(1));
    expect(chat.subagentActivities.single.eventRevision, 2);
    expect(chat.subagentActivities.single.phase, SubagentActivityPhase.running);
    expect(chat.subagentActivities.single.details.progress?.taskIndex, 1);
  });

  test(
    '[console-state 1/7] session.info never seals a turn by itself',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('session.info', const {
        'info': {'running': false},
      });
      await _settle();

      expect(chat.isStreaming, isTrue);
    },
  );

  test(
    'session.info running then idle still cannot seal without terminal event',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('subagent.start', const {
        'subagent_id': 'child-session-info-terminal',
        'status': 'running',
      });
      gateway.emit('status.update', const {'kind': 'compacting'});
      gateway.emit('session.info', const {
        'info': {'running': true},
      });
      gateway.emit('session.info', const {
        'info': {'running': false},
      });
      await _settle();

      expect(chat.isStreaming, isTrue);
      expect(chat.activeSubagentCount, 1);
      expect(
        chat.subagentActivities.single.phase,
        SubagentActivityPhase.running,
      );
    },
  );

  test(
    '[console-state 3/7] post-terminal complete cannot rewrite by position',
    () async {
      SharedPreferences.setMockInitialValues(const {});
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('message.complete', const {'text': 'terminal original'});
      await _settle();
      gateway.emit('message.complete', const {
        'text': 'late positional rewrite',
      });
      await _settle();

      expect(chat.isStreaming, isFalse);
      expect(
        chat.messages.firstWhere(
          (message) => message['role'] == 'assistant',
        )['content'],
        'terminal original',
      );
    },
  );

  test(
    '[console-state 2/7] late terminal from A cannot affect successor B',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('message.complete', const {'text': 'A final'});
      await _settle();
      expect(
        await chat.send(
          fullText: 'turn B',
          model: 'hermes-agent',
          history: chat.messages,
        ),
        isTrue,
      );
      gateway.emit('message.complete', const {'status': 'error'});
      await _settle();

      expect(chat.isStreaming, isTrue);
      expect(chat.state, isNot(ChatPipelineState.failed));
    },
  );

  test(
    '[console-state 6/7] active subagent rows are deterministically bounded',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      for (var index = 0; index < 40; index++) {
        gateway.emit('subagent.start', {
          'subagent_id': 'bounded-$index',
          'status': 'running',
        });
      }
      await _settle();

      expect(chat.subagentActivities, hasLength(32));
      expect(
        chat.subagentActivities.map((activity) => activity.subagentId),
        orderedEquals(List.generate(32, (index) => 'bounded-$index')),
      );
    },
  );

  test(
    'completed child survives next local turn until exact durable card dedupes it',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('subagent.start', const {
        'subagent_id': 'child-terminal-history',
        'delegation_id': 'deleg_terminal_history',
        'child_session_id': 'child-session-terminal-history',
        'status': 'running',
        'event_revision': 1,
        'goal': 'Historical child evidence',
      });
      gateway.emit('subagent.complete', const {
        'subagent_id': 'child-terminal-history',
        'delegation_id': 'deleg_terminal_history',
        'child_session_id': 'child-session-terminal-history',
        'status': 'completed',
        'event_revision': 2,
        'summary': 'Historical completion',
      });
      gateway.emit('message.complete', const {'text': 'parent completed'});
      await _settle();
      final terminal = chat.subagentActivities.single;

      expect(
        await chat.send(
          fullText: 'next local turn',
          model: 'hermes-agent',
          history: chat.messages,
        ),
        isTrue,
      );

      expect(chat.subagentActivities, hasLength(1));
      expect(chat.subagentActivities.single, same(terminal));
      expect(chat.subagentActivities.single.isTerminal, isTrue);
      expect(chat.canSteerSubagent(terminal), isFalse);
      expect(chat.canTailSubagent(terminal), isFalse);
      expect(chat.canInterruptSubagent(terminal), isFalse);

      chat.internalMessagesForTesting = projectHistoricalSubagentCompletions(
        messagesNewestFirst: [
          {
            'message_id': 'durable-terminal-history',
            'role': 'user',
            'content':
                '[ASYNC DELEGATION BATCH COMPLETE — deleg_terminal_history]',
            'display_kind': 'async_delegation_complete',
            'display_metadata': {
              'delegation_id': 'deleg_terminal_history',
              'task_count': 1,
              'completed_count': 1,
              'failed_count': 0,
              'subagent_ids': ['child-terminal-history'],
            },
          },
          ...chat.internalMessagesForTesting,
        ],
      );

      expect(chat.subagentActivities, isEmpty);
      expect(
        chat.messages
            .map(historicalSubagentCompletionOf)
            .whereType<SubagentCompletionCardData>(),
        hasLength(1),
      );
    },
  );

  test(
    'runtime rotation withholds predecessor evidence until B proves one live row',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('subagent.start', const {
        'subagent_id': 'child-rotation',
        'delegation_id': 'deleg_rotation',
        'goal': 'inspect continuity',
        'status': 'running',
        'event_id': 'rotation-a-start',
        'event_revision': 1,
      });
      await _settle();
      expect(
        chat.subagentActivities.single.phase,
        SubagentActivityPhase.running,
      );

      gateway.listGate = Completer<List<DesktopSubagentSnapshot>>();
      chat.adoptDesktopRuntimeForTesting('runtime-2');
      await _settle();

      expect(chat.subagentActivities, isEmpty);

      gateway.listGate!.complete(const []);
      await _settle();
      expect(chat.subagentActivities, isEmpty);

      gateway.emit('subagent.progress', const {
        'subagent_id': 'child-rotation',
        'delegation_id': 'deleg_rotation',
        'status': 'running',
        'event_id': 'rotation-b-progress',
        'event_revision': 2,
        'tool_count': 3,
      }, sessionId: 'runtime-2');
      await _settle();

      expect(chat.subagentActivities, hasLength(1));
      expect(
        chat.subagentActivities.single.phase,
        SubagentActivityPhase.running,
      );
      expect(chat.subagentActivities.single.eventRevision, 2);
      expect(chat.subagentActivities.single.details.toolCount, 3);
      expect(chat.canInterruptSubagent(chat.subagentActivities.single), isTrue);
    },
  );

  test(
    '[console-state 7/7] subagent id alone cannot tombstone a successor turn',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('subagent.complete', const {
        'subagent_id': 'retired-child',
        'status': 'completed',
      });
      gateway.emit('message.complete', const {'text': 'parent done'});
      await _settle();
      expect(
        await chat.send(
          fullText: 'successor',
          model: 'hermes-agent',
          history: chat.messages,
        ),
        isTrue,
      );
      gateway.emit('subagent.start', const {
        'subagent_id': 'retired-child',
        'status': 'running',
      });
      await _settle();

      expect(
        chat.subagentActivities.any(
          (activity) =>
              activity.subagentId == 'retired-child' && !activity.isTerminal,
        ),
        isTrue,
      );
    },
  );

  test(
    'message.complete error wins terminal race against session.info',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);

      gateway.emit('session.info', const {
        'info': {'running': true},
      });
      gateway.emit('session.info', const {
        'info': {'running': false},
      });
      gateway.emit('message.complete', const {'status': 'error'});
      await _settle();

      expect(chat.state, ChatPipelineState.failed);
    },
  );

  test(
    'live child survives a new user turn and completes the same row once',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      var activityChanges = 0;
      final subscription = chat.changes.listen((event) {
        if (event == ActiveChatEvent.subagentActivity) activityChanges += 1;
      });
      addTearDown(subscription.cancel);

      gateway.emit('subagent.start', const {
        'subagent_id': 'child-cross-turn',
        'delegation_id': 'deleg_cross_turn',
        'status': 'running',
        'event_id': 'cross-turn-start',
        'event_revision': 1,
      });
      await _settle();

      expect(chat.subagentActivities, hasLength(1));
      final originalKey = chat.subagentActivities.single.key;
      expect(
        chat.subagentActivities.single.phase,
        SubagentActivityPhase.running,
      );

      gateway.emit('message.complete', const {'text': 'parent finished'});
      await _settle();
      expect(
        await chat.send(
          fullText: 'a normal follow-up',
          model: 'hermes-agent',
          history: chat.messages,
        ),
        isTrue,
      );

      expect(chat.subagentActivities, hasLength(1));
      expect(chat.subagentActivities.single.key, originalKey);
      expect(
        chat.subagentActivities.single.phase,
        SubagentActivityPhase.running,
      );

      activityChanges = 0;
      gateway.emit('subagent.complete', const {
        'subagent_id': 'child-cross-turn',
        'delegation_id': 'deleg_cross_turn',
        'status': 'completed',
        'event_id': 'cross-turn-complete',
        'event_revision': 2,
      });
      gateway.emit('subagent.complete', const {
        'subagent_id': 'child-cross-turn',
        'delegation_id': 'deleg_cross_turn',
        'status': 'completed',
        'event_id': 'cross-turn-complete',
        'event_revision': 2,
      });
      await _settle();

      expect(activityChanges, 1);
      expect(chat.subagentActivities, hasLength(1));
      expect(chat.subagentActivities.single.key, originalKey);
      expect(
        chat.subagentActivities.single.phase,
        SubagentActivityPhase.completed,
      );
    },
  );

  test('native terminal old epoch yields to the next epoch child', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('subagent.start', const {
      'subagent_id': 'native-epoch-a',
      'status': 'running',
      'event_id': 'native-epoch-a-start',
    });
    await _settle();
    final epochA = chat.subagentActivities.single.key.scope.turnEpoch;

    gateway.emit('message.complete', const {'text': 'parent finished'});
    await _settle();
    expect(
      await chat.send(
        fullText: 'next turn',
        model: 'hermes-agent',
        history: chat.messages,
      ),
      isTrue,
    );
    gateway.emit('subagent.complete', const {
      'subagent_id': 'native-epoch-a',
      'status': 'completed',
      'event_id': 'native-epoch-a-complete',
    });
    await _settle();
    expect(
      chat.subagentActivities.single.phase,
      SubagentActivityPhase.completed,
    );

    gateway.emit('subagent.start', const {
      'subagent_id': 'native-epoch-b',
      'status': 'running',
      'event_id': 'native-epoch-b-start',
    });
    await _settle();

    expect(chat.subagentActivities, hasLength(2));
    final epochBActivity = chat.subagentActivities.singleWhere(
      (activity) => activity.subagentId == 'native-epoch-b',
    );
    expect(epochBActivity.phase, SubagentActivityPhase.running);
    expect(epochBActivity.key.scope.turnEpoch, greaterThan(epochA));

    gateway.emit('subagent.complete', const {
      'subagent_id': 'native-epoch-a',
      'status': 'completed',
      'event_id': 'native-epoch-a-complete-late-duplicate',
    });
    await _settle();
    expect(chat.subagentActivities, hasLength(3));
    expect(
      chat.subagentActivities.where(
        (activity) => activity.subagentId == 'native-epoch-a',
      ),
      hasLength(2),
    );
    expect(
      chat.subagentActivities
          .singleWhere((activity) => activity.subagentId == 'native-epoch-b')
          .phase,
      SubagentActivityPhase.running,
    );
  });

  test('legacy terminal old epoch yields to the next epoch delegate', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('tool.start', const {
      'name': 'delegate_task',
      'tool_id': 'legacy-epoch-a',
    });
    await _settle();
    final epochA = chat.subagentActivities.single.key.scope.turnEpoch;

    gateway.emit('message.complete', const {'text': 'parent finished'});
    await _settle();
    expect(
      await chat.send(
        fullText: 'next turn',
        model: 'hermes-agent',
        history: chat.messages,
      ),
      isTrue,
    );
    gateway.emit('tool.complete', const {
      'name': 'delegate_task',
      'tool_id': 'legacy-epoch-a',
      'result': {'status': 'completed'},
    });
    await _settle();
    expect(
      chat.subagentActivities.single.phase,
      SubagentActivityPhase.completed,
    );

    gateway.emit('tool.start', const {
      'name': 'delegate_task',
      'tool_id': 'legacy-epoch-b',
    });
    await _settle();

    expect(chat.subagentActivities, hasLength(2));
    final epochBActivity = chat.subagentActivities.singleWhere(
      (activity) => activity.legacyToolCallId == 'legacy-epoch-b',
    );
    expect(epochBActivity.phase, SubagentActivityPhase.running);
    expect(epochBActivity.key.scope.turnEpoch, greaterThan(epochA));

    gateway.emit('tool.complete', const {
      'name': 'delegate_task',
      'tool_id': 'legacy-epoch-a',
      'result': {'status': 'completed'},
    });
    await _settle();
    expect(chat.subagentActivities, hasLength(2));
    expect(
      chat.subagentActivities
          .singleWhere(
            (activity) => activity.legacyToolCallId == 'legacy-epoch-b',
          )
          .phase,
      SubagentActivityPhase.running,
    );
  });

  testWidgets(
    'mounted card survives submit and completion updates its stable row once',
    (tester) async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      final probeKey = GlobalKey<_MountedSubagentProbeState>();
      await tester.pumpWidget(_MountedSubagentProbe(key: probeKey, chat: chat));

      gateway.emit('subagent.start', const {
        'subagent_id': 'mounted-epoch-a',
        'status': 'running',
        'event_id': 'mounted-epoch-a-start',
        'event_revision': 1,
      });
      await tester.pump();
      final stableKey = chat.subagentActivities.single.key;
      expect(find.byType(SubagentActivityCard), findsOneWidget);
      await tester.tap(find.text('ver detalles'));
      await tester.pumpAndSettle();
      final rowFinder = find.byKey(ValueKey(stableKey));
      expect(rowFinder, findsOneWidget);
      final stableElement = tester.element(rowFinder);

      gateway.emit('message.complete', const {'text': 'parent finished'});
      await tester.pump();
      expect(
        await chat.send(
          fullText: 'next turn',
          model: 'hermes-agent',
          history: chat.messages,
        ),
        isTrue,
      );
      await tester.pump();
      expect(find.byType(SubagentActivityCard), findsOneWidget);
      expect(rowFinder, findsOneWidget);
      expect(tester.element(rowFinder), same(stableElement));

      final rebuildsBeforeCompletion = probeKey.currentState!.activityRebuilds;
      gateway.emit('subagent.complete', const {
        'subagent_id': 'mounted-epoch-a',
        'status': 'completed',
        'event_id': 'mounted-epoch-a-complete',
        'event_revision': 2,
      });
      gateway.emit('subagent.complete', const {
        'subagent_id': 'mounted-epoch-a',
        'status': 'completed',
        'event_id': 'mounted-epoch-a-complete',
        'event_revision': 2,
      });
      await tester.pump();

      expect(
        probeKey.currentState!.activityRebuilds - rebuildsBeforeCompletion,
        1,
      );
      expect(find.byType(SubagentActivityCard), findsOneWidget);
      expect(rowFinder, findsOneWidget);
      expect(tester.element(rowFinder), same(stableElement));
      expect(
        chat.subagentActivities.single.phase,
        SubagentActivityPhase.completed,
      );

      gateway.emit('subagent.start', const {
        'subagent_id': 'mounted-epoch-b',
        'status': 'running',
        'event_id': 'mounted-epoch-b-start',
      });
      await tester.pump();
      expect(find.byType(SubagentActivityCard), findsOneWidget);
      expect(chat.subagentActivities, hasLength(2));
      final currentB = chat.subagentActivities.singleWhere(
        (activity) => activity.subagentId == 'mounted-epoch-b',
      );
      expect(currentB.phase, SubagentActivityPhase.running);
      final rowBFinder = find.byKey(ValueKey(currentB.key));
      expect(rowFinder, findsOneWidget);
      expect(rowBFinder, findsOneWidget);
      final currentBElement = tester.element(rowBFinder);

      gateway.emit('subagent.complete', const {
        'subagent_id': 'mounted-epoch-a',
        'status': 'completed',
        'event_id': 'mounted-epoch-a-complete',
        'event_revision': 2,
      });
      await tester.pump();
      expect(rowFinder, findsOneWidget);
      expect(rowBFinder, findsOneWidget);
      expect(tester.element(rowBFinder), same(currentBElement));
      expect(
        chat.subagentActivities
            .where((activity) => activity.subagentId == 'mounted-epoch-a')
            .every(
              (activity) => activity.phase == SubagentActivityPhase.completed,
            ),
        isTrue,
      );
      expect(
        chat.subagentActivities
            .singleWhere((activity) => activity.subagentId == 'mounted-epoch-b')
            .phase,
        SubagentActivityPhase.running,
      );

      chat.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
