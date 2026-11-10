import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart'
    show subagentElapsed, subagentCompletionTime;
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

import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

class _SubagentGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSubagentGateway,
        HermesDesktopFailedDelegationGateway,
        HermesDesktopSessionHistoryGateway {
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
  List<Map<String, dynamic>> history = const [];
  int historyCalls = 0;

  @override
  Future<SessionMessagesPage> sessionHistory({
    required String sessionId,
    String? profile,
  }) async {
    historyCalls++;
    return SessionMessagesPage(messages: history, pagination: null);
  }

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

  bool connected = true;

  @override
  bool get isConnected => connected;

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

  List<DesktopFailedDelegation> failedDelegations = const [];
  int failedDelegationCalls = 0;

  @override
  Future<List<DesktopFailedDelegation>> listFailedDelegations(
    String runtimeSessionId,
  ) async {
    failedDelegationCalls += 1;
    return failedDelegations;
  }

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
    List<String>? approvalChoices,
    String? command,
    String? description,
    bool blind = false,
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
    bool replyable = false,
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
    compressionRestoreStore: testCompressionRestoreStore(),
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
    api: testApiClient(
      baseUrl: 'https://example.invalid',
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
    'turn duration accepts seconds/milliseconds and rejects impossible origins',
    () async {
      for (final origin in <num>[
        0,
        1,
        -1,
        double.nan,
        DateTime.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch,
        DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
        DateTime.now()
                .subtract(const Duration(minutes: 1))
                .millisecondsSinceEpoch /
            1000,
      ]) {
        final gateway = _SubagentGateway();
        final chat = await _start(gateway);
        chat.internalMessagesForTesting = [
          {
            'role': 'assistant',
            'content': '',
            '_pipeline': true,
            '_activity_duration_seconds': 604800,
            '_activity_trace': [
              {
                'kind': 'tool',
                'label': 'terminal',
                'status': 'completed',
                'timestamp': origin,
              },
            ],
          },
          ...chat.internalMessagesForTesting.where(
            (m) => m['role'] != 'assistant',
          ),
        ];
        gateway.emit('message.complete', const {'text': 'finished'});
        await _settle();
        final measured = chat.messages.first['_activity_duration_seconds'];
        final originMs = origin < 1e11 ? origin * 1000 : origin;
        if (origin.isFinite &&
            (DateTime.now().millisecondsSinceEpoch - originMs).abs() < 120000) {
          expect(measured, inInclusiveRange(55, 65));
        } else {
          expect(measured, isNull);
        }
        chat.dispose();
      }
    },
  );

  group('turn duration after reconciling from the background', () {
    // The Pixel run: a ~41 s turn settled 186 s after its prompt, when the
    // app came back, read «Trabajó 186 s». The rows below are what the
    // recovery graft leaves before the terminal settles: the durable rows,
    // with the server's own times (seeded here as the graft would leave
    // them; the graft itself is covered by the recovery tests).
    double seconds(DateTime at) => at.millisecondsSinceEpoch / 1000;

    Future<Object?> settledDuration({required bool durableFinal}) async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      final prompt = DateTime.now().subtract(const Duration(seconds: 186));
      chat.internalMessagesForTesting = [
        {
          'role': 'assistant',
          'content': 'listo',
          if (durableFinal) ...{
            'id': 'a-final',
            'timestamp': seconds(prompt.add(const Duration(seconds: 41))),
          } else
            '_pipeline': true,
          '_activity_trace': [
            {
              'kind': 'tool',
              'label': 'terminal',
              'status': 'completed',
              'timestamp': prompt
                  .add(const Duration(seconds: 2))
                  .millisecondsSinceEpoch,
            },
          ],
        },
        {
          'role': 'tool',
          'id': 't-1',
          'content': 'ok',
          'timestamp': seconds(prompt.add(const Duration(seconds: 33))),
        },
        {
          'role': 'user',
          'id': 'u-1',
          'content': 'delegar',
          'timestamp': seconds(prompt),
        },
      ];
      gateway.emit('message.complete', const {'text': 'listo'});
      await _settle();
      final measured = chat.messages.first['_activity_duration_seconds'];
      chat.dispose();
      return measured;
    }

    test('a settled turn with durable rows gets the server duration', () async {
      expect(
        await settledDuration(durableFinal: true),
        closeTo(41, 0.01),
        reason: 'final row − prompt, not the reconcile time (186 s)',
      );
    });

    test('without the durable final row it keeps the local measure', () async {
      expect(
        await settledDuration(durableFinal: false),
        inInclusiveRange(180, 190),
        reason: 'no server end: never mixes server and phone clocks',
      );
    });
  });

  test(
    'failed delegations read on refresh stay out of the live roster',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      expect(chat.failedDelegations, isEmpty);

      gateway.failedDelegations = [
        DesktopFailedDelegation.tryParse({
          'delegation_id': 'deleg-x',
          'task_index': 0,
          'status': 'failed',
          'goal': 'Contar archivos',
          'error': 'boom',
        })!,
      ];
      await chat.refreshSubagentsForTesting();
      await chat.refreshFailedDelegations();

      expect(chat.failedDelegations.map((r) => r.stableId), ['deleg-x#0']);
      expect(chat.failedDelegationScope, isNotNull);
      // They never become live children or take a control authority.
      expect(chat.conversationSubagents, isEmpty);
      expect(gateway.failedDelegationCalls, greaterThan(0));
    },
  );

  test(
    'one conversation roster retains two children across disconnect and completion',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      expect(
        SubagentGroupCount.of(chat.conversationSubagents),
        SubagentGroupCount.none,
      );
      for (var i = 1; i <= 2; i++) {
        gateway.emit('subagent.start', {
          'subagent_id': 'child-$i',
          'delegation_id': 'deleg-$i',
          'started_at': '2026-11-03T12:31:00Z',
          'status': 'running',
        });
        await _settle();
        expect(
          SubagentGroupCount.of(chat.conversationSubagents),
          SubagentGroupCount(0, i),
        );
      }
      gateway.connected = false;
      expect(
        chat.conversationSubagents.map((a) => a.phase),
        everyElement(SubagentActivityPhase.unknown),
      );
      // The first completion was lost while offline: the repaired roster no
      // longer lists it. Absence must never manufacture "cancelled" or a clock.
      gateway.connected = true;
      gateway.listGate = Completer<List<DesktopSubagentSnapshot>>()
        ..complete(const [
          DesktopSubagentSnapshot(
            subagentId: 'child-2',
            delegationId: 'deleg-2',
            status: 'running',
          ),
        ]);
      await chat.refreshSubagentsForTesting();
      expect(chat.conversationSubagents.map((a) => a.phase), [
        SubagentActivityPhase.unknown,
        SubagentActivityPhase.running,
      ]);
      gateway.emit('subagent.complete', const {
        'subagent_id': 'child-1',
        'delegation_id': 'deleg-1',
        'status': 'completed',
        'completed_at': '2026-11-03T12:32:00Z',
      });
      await _settle();
      expect(
        SubagentGroupCount.of(chat.conversationSubagents),
        const SubagentGroupCount(1, 2),
      );
      expect(
        chat.conversationSubagents.first.details.completedAt,
        DateTime.utc(2026, 11, 3, 12, 32),
      );
      gateway.emit('subagent.complete', const {
        'subagent_id': 'child-2',
        'delegation_id': 'deleg-2',
        'status': 'failed',
      });
      await _settle();
      expect(
        SubagentGroupCount.of(chat.conversationSubagents),
        const SubagentGroupCount(2, 2),
      );
    },
  );

  // subagent-roster (REPORT-MODELO-DESKTOP plan E): was «native proof after
  // list failure confirms only that identity», which emptied the proof on a
  // failed read. Desktop use-subagent-snapshot.ts keeps the event-fed frame
  // when `subagent.list` fails: rows, phases and controls stay as they were.
  test('a failed list keeps the roster and its controls', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);
    for (final id in ['known', 'untouched']) {
      gateway.emit('subagent.start', {'subagent_id': id, 'goal': 'Goal $id'});
    }
    await _settle();
    expect(chat.conversationSubagents, hasLength(2));
    final failed = Completer<List<DesktopSubagentSnapshot>>();
    gateway.listGate = failed;
    final refresh = chat.refreshSubagentsForTesting();
    failed.completeError(StateError('list failed'));
    await refresh;
    expect(chat.conversationSubagents, hasLength(2));
    expect(
      chat.conversationSubagents.every(
        (a) => a.phase == SubagentActivityPhase.running,
      ),
      isTrue,
    );
    expect(chat.subagentActivities, hasLength(2));
    expect(chat.activeSubagentCount, 2);
    expect(chat.subagentListFailureRevision, 1);
    gateway.emit('subagent.start', {
      'subagent_id': 'known',
      'goal': 'Goal known',
    });
    gateway.emit('subagent.start', {'subagent_id': 'new', 'goal': 'New goal'});
    await _settle();
    final roster = {
      for (final a in chat.conversationSubagents) a.subagentId: a,
    };
    expect(roster, hasLength(3));
    expect(roster['known']!.phase, SubagentActivityPhase.running);
    expect(roster['new']!.phase, SubagentActivityPhase.running);
    expect(roster['untouched']!.phase, SubagentActivityPhase.running);
    expect(chat.canInterruptSubagent(roster['known']!), isTrue);
    expect(chat.canInterruptSubagent(roster['untouched']!), isTrue);
  });

  test(
    'unchanged absent identities read history once per runtime and evidence',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      gateway.emit('subagent.start', {
        'subagent_id': 'mixed',
        'delegation_id': 'deleg-mixed',
      });
      await _settle();
      expect(chat.conversationSubagents, hasLength(1));
      gateway.history = [
        {
          'role': 'user',
          'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg-mixed]',
          'display_kind': 'async_delegation_complete',
          'display_metadata': {
            'delegation_id': 'deleg-mixed',
            'task_count': 2,
            'completed_count': 1,
            'failed_count': 1,
          },
        },
      ];
      final before = gateway.historyCalls;
      for (var i = 0; i < 4; i++) {
        await chat.refreshSubagentsForTesting();
        await _settle();
      }
      expect(gateway.historyCalls - before, 1);
      expect(
        chat.conversationSubagents.single.phase,
        SubagentActivityPhase.unknown,
      );
      gateway.emit('subagent.thinking', {
        'subagent_id': 'mixed',
        'delegation_id': 'deleg-mixed',
      });
      await _settle();
      await chat.refreshSubagentsForTesting();
      await _settle();
      expect(gateway.historyCalls - before, 2);
      chat.adoptDesktopRuntimeForTesting('runtime-retry');
      await chat.refreshSubagentsForTesting();
      await _settle();
      expect(gateway.historyCalls - before, 3);
      await chat.refreshSubagentsForTesting();
      await _settle();
      expect(gateway.historyCalls - before, 3);
    },
  );

  test(
    'a child completed offline is reconciled from durable history with its end time',
    () async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      gateway.emit('subagent.start', const {
        'subagent_id': 'sa-offline',
        'delegation_id': 'deleg_deadbeef',
        'started_at': '2026-11-03T12:31:00Z',
      });
      await _settle();
      expect(
        chat.conversationSubagents.single.phase,
        SubagentActivityPhase.running,
      );
      gateway.connected = false;
      expect(
        chat.conversationSubagents.single.phase,
        SubagentActivityPhase.unknown,
      );
      gateway.history = [
        {'role': 'user', 'content': 'delegate', 'message_id': 'u-start'},
        {
          'role': 'tool',
          'tool_name': 'delegate_task',
          'tool_call_id': 'delegate-call',
          'content':
              '{"status":"dispatched","delegation_id":"deleg_deadbeef","subagent_ids":["sa-offline"]}',
        },
        {
          'role': 'user',
          'message_id': 'u-complete',
          'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_deadbeef]',
          'display_kind': 'async_delegation_complete',
          'timestamp':
              DateTime.utc(2026, 11, 3, 12, 32).millisecondsSinceEpoch / 1000,
          'display_metadata': {
            'delegation_id': 'deleg_deadbeef',
            'task_count': 1,
            'completed_count': 1,
            'failed_count': 0,
          },
        },
        // Completion belongs to an earlier turn, while the parent works on.
        {'role': 'user', 'content': 'continue', 'message_id': 'u-next'},
      ];
      chat.adoptDesktopRuntimeForTesting('runtime-reconnected');
      gateway.connected = true;
      await chat.refreshSubagentsForTesting();
      await _settle();
      expect(gateway.historyCalls, greaterThan(0));
      expect(
        subagentElapsed(
          chat.conversationSubagents.single,
          DateTime.utc(2026, 11, 3, 13),
        ),
        const Duration(minutes: 1),
      );
      expect(
        subagentCompletionTime(chat.conversationSubagents.single),
        isNotNull,
      );
      expect(
        chat.conversationSubagents.single.phase,
        SubagentActivityPhase.completed,
      );
      expect(
        chat.conversationSubagents.single.details.completedAt,
        DateTime.utc(2026, 11, 3, 12, 32),
      );
    },
  );

  test(
    'presentation owner tokens isolate sibling release and scrub only on 1 to 0',
    () async {
      final gateway = _SubagentGateway();
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
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
        api: testApiClient(
          baseUrl: 'https://example.invalid',
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
        compressionRestoreStore: testCompressionRestoreStore(),
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
        api: testApiClient(
          baseUrl: 'https://example.invalid',
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
    'a live roster row with no status or a future one reaches the chat',
    () async {
      // subagent.list rows are parsed by the contract defaults (82261b3);
      // the roster consumer must not narrow them back to a live allowlist.
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      addTearDown(chat.dispose);
      await _settle();
      final rows = [
        for (final raw in const [
          {'subagent_id': 'child-unstated', 'goal': 'sin estado'},
          {
            'subagent_id': 'child-future',
            'status': 'paused_for_input',
            'goal': 'estado futuro',
          },
        ])
          DesktopSubagentSnapshot.tryParse(raw)!,
      ];

      gateway.listGate = Completer<List<DesktopSubagentSnapshot>>();
      final refresh = chat.refreshSubagentsForTesting();
      gateway.listGate!.complete(rows);
      await refresh;

      expect(
        chat.subagentActivities.map((activity) => activity.subagentId),
        unorderedEquals(['child-unstated', 'child-future']),
      );
      expect(
        chat.subagentActivities.every((activity) => !activity.isTerminal),
        isTrue,
      );
      expect(chat.activeSubagentCount, 2);
    },
  );

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

  // subagent-roster: was «…starts a mounted successor row in next turn».
  // The roster is per session now and, as Desktop's retired set
  // (store/subagents.ts upsertSubagent), a finished child's id is retired:
  // a later start for it, in any turn, never brings a second row back.
  test(
    'same runtime finished subagent id stays retired in the next turn',
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

      expect(
        chat.subagentActivities.where((activity) => !activity.isTerminal),
        isEmpty,
      );
      expect(chat.activeSubagentCount, 0);
      expect(chat.safeActiveSubagentCount, 0);
    },
  );

  // subagent-roster: the roster is per session (Desktop store/subagents.ts).
  // A child that outlives the turn that spawned it keeps the same key in the
  // next turn: its later events update that one row, never add a second.
  // The finished sibling is pruned into the retired set at the new turn
  // (pruneFinishedSessionSubagents) and cannot come back.
  test('a child that outlives its turn stays one row in the next turn', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('subagent.start', const {
      'subagent_id': 'outliving',
      'goal': 'Long job',
      'status': 'running',
    });
    gateway.emit('subagent.complete', const {
      'subagent_id': 'finished-before',
      'goal': 'Short job',
      'status': 'completed',
    });
    gateway.emit('message.complete', const {'text': 'parent done'});
    await _settle();
    final key = chat.subagentActivities
        .singleWhere((a) => a.subagentId == 'outliving')
        .key;

    expect(
      await chat.send(
        fullText: 'next turn',
        model: 'hermes-agent',
        history: chat.messages,
      ),
      isTrue,
    );
    gateway.emit('subagent.tool', const {
      'subagent_id': 'outliving',
      'status': 'tool',
      'tool_name': 'terminal',
    });
    gateway.emit('subagent.start', const {
      'subagent_id': 'finished-before',
      'status': 'running',
    });
    await _settle();

    final roster = chat.conversationSubagents;
    expect(roster.where((a) => a.subagentId == 'outliving'), hasLength(1));
    final outliving = roster.singleWhere((a) => a.subagentId == 'outliving');
    expect(outliving.key, key);
    expect(outliving.phase, SubagentActivityPhase.tool);
    expect(
      roster.where(
        (a) => a.subagentId == 'finished-before' && !a.isTerminal,
      ),
      isEmpty,
    );
    expect(chat.activeSubagentCount, 1);
  });

  // clean-stopped: a «Detenido» child of the previous turn leaves the live
  // block of the new turn (it is reported as finished in an earlier turn) but
  // stays in the roster the capsule and the sheet read; a child still running
  // and one that stops inside the new turn are not reported.
  test('a stopped child of the previous turn is not live in the next', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('subagent.start', const {
      'subagent_id': 'running-on',
      'status': 'running',
    });
    gateway.emit('subagent.complete', const {
      'subagent_id': 'stopped-before',
      'status': 'interrupted',
    });
    gateway.emit('message.complete', const {'text': 'parent done'});
    await _settle();
    expect(
      chat.conversationSubagents.singleWhere(
        (a) => a.subagentId == 'stopped-before',
      ).phase,
      SubagentActivityPhase.cancelled,
    );

    expect(
      await chat.send(
        fullText: 'next turn',
        model: 'hermes-agent',
        history: chat.messages,
      ),
      isTrue,
    );
    gateway.emit('subagent.complete', const {
      'subagent_id': 'stopped-now',
      'status': 'interrupted',
    });
    await _settle();

    final roster = chat.conversationSubagents;
    SubagentActivity of(String id) =>
        roster.singleWhere((a) => a.subagentId == id);
    expect(chat.isFinishedInEarlierTurn(of('stopped-before')), isTrue);
    expect(chat.isFinishedInEarlierTurn(of('running-on')), isFalse);
    expect(chat.isFinishedInEarlierTurn(of('stopped-now')), isFalse);
  });

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

  // subagent-roster: was «subagent id alone cannot tombstone a successor
  // turn». The roster is per session and, as Desktop's retired set
  // (store/subagents.ts upsertSubagent), the finished child's subagent_id is
  // retired for the session: a later start for it never reopens a live row.
  test(
    '[console-state 7/7] a finished subagent id stays retired in a successor turn',
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
        isFalse,
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

  // subagent-roster: was «native terminal old epoch yields to the next
  // epoch child». One roster per session (Desktop store/subagents.ts): both
  // children share the session scope, and a late duplicate completion of
  // the first one updates its row instead of adding a third.
  test('a finished child and the next turn\'s child share one session roster', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('subagent.start', const {
      'subagent_id': 'native-epoch-a',
      'status': 'running',
      'event_id': 'native-epoch-a-start',
    });
    await _settle();
    final scopeA = chat.subagentActivities.single.key.scope;

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
    expect(epochBActivity.key.scope, scopeA);

    gateway.emit('subagent.complete', const {
      'subagent_id': 'native-epoch-a',
      'status': 'completed',
      'event_id': 'native-epoch-a-complete-late-duplicate',
    });
    await _settle();
    expect(chat.subagentActivities, hasLength(2));
    expect(
      chat.subagentActivities.where(
        (activity) => activity.subagentId == 'native-epoch-a',
      ),
      hasLength(1),
    );
    expect(
      chat.subagentActivities
          .singleWhere((activity) => activity.subagentId == 'native-epoch-b')
          .phase,
      SubagentActivityPhase.running,
    );
  });

  // subagent-roster: was «…yields to the next epoch delegate». Both
  // delegate_task rows live in the one session roster now (same scope);
  // the late duplicate completion of the first still adds nothing.
  test('legacy terminal and the next turn\'s delegate share one session roster', () async {
    final gateway = _SubagentGateway();
    final chat = await _start(gateway);
    addTearDown(chat.dispose);

    gateway.emit('tool.start', const {
      'name': 'delegate_task',
      'tool_id': 'legacy-epoch-a',
    });
    await _settle();
    final scopeA = chat.subagentActivities.single.key.scope;

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
    expect(epochBActivity.key.scope, scopeA);

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
      // Spec 080: the in-chat row is one flat, stable transcript row; its
      // element must survive submit and completion without remounting.
      final rowFinder = find.byKey(const ValueKey('subagent-work-pill'));
      expect(rowFinder, findsOneWidget);
      expect(stableKey, isNotNull);
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
      final rowBFinder = rowFinder;
      expect(currentB.key, isNot(stableKey));
      expect(rowFinder, findsOneWidget);
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

  // P0-1 (official comparison, 8 nov): one async delegation painted as
  // «2 subagentes». The `delegate_task` call's placeholder and its child must
  // stay ONE row in the roster every surface reads, read after every event
  // as the chat does. Payload shapes are the real server's.
  group('one delegation is one subagent in the conversation roster', () {
    const goal = 'Ejecuta exactamente el bucle for';

    Future<(ActiveChat, _SubagentGateway, List<int>)> begin() async {
      final gateway = _SubagentGateway();
      final chat = await _start(gateway);
      await chat.refreshSubagentsForTesting();
      return (chat, gateway, <int>[]);
    }

    Map<String, dynamic> child(String id, {String? goalText, int index = 0}) =>
        {
          'subagent_id': id,
          'goal': goalText ?? goal,
          'task_index': index,
          'task_count': 1,
          'depth': 0,
          'tool_count': 0,
        };

    test('placeholder, spawn, start, tool, dispatch result: always 1', () async {
      final (chat, gateway, seen) = await begin();
      addTearDown(chat.dispose);
      Future<void> step(String type, Map<String, dynamic> payload) async {
        gateway.emit(type, payload);
        await _settle();
        seen.add(chat.conversationSubagents.length);
      }

      await step('tool.start', {'name': 'delegate_task', 'tool_id': 'call-1'});
      await step('subagent.spawn_requested', child('sa-0-aaaa'));
      await step('subagent.start', {
        ...child('sa-0-aaaa'),
        'child_session_id': 'child-aaaa',
      });
      await step('subagent.tool', {
        ...child('sa-0-aaaa'),
        'child_session_id': 'child-aaaa',
        'tool_name': 'terminal',
        'tool_preview': 'for',
      });
      await step('tool.complete', {
        'name': 'delegate_task',
        'tool_id': 'call-1',
        'result': {
          'status': 'dispatched',
          'mode': 'background',
          'count': 1,
          'delegation_id': 'deleg-1',
          'goals': [goal],
          'subagent_ids': ['sa-0-aaaa'],
        },
      });
      await step('message.complete', {'text': 'Lanzado 1 subagente'});

      expect(seen, [1, 1, 1, 1, 1, 1]);
      final roster = chat.conversationSubagents;
      expect(roster.single.subagentId, 'sa-0-aaaa');
      expect(roster.single.goalPreview, goal);
      expect(SubagentGroupCount.of(roster), const SubagentGroupCount(0, 1));
      expect(chat.safeActiveSubagentCount, 1);
      // P0-2: the parent ended and only the child works.
      expect(chat.isStreaming, isFalse);
      expect(chat.canStopSessionWork, isTrue);
      expect(chat.onlySubagentsWork, isTrue);

      await step('subagent.complete', {
        ...child('sa-0-aaaa'),
        'child_session_id': 'child-aaaa',
        'status': 'completed',
        'summary': 'paso 1..6',
      });
      expect(seen.last, 1);
      expect(
        SubagentGroupCount.of(chat.conversationSubagents),
        const SubagentGroupCount(1, 1),
      );
      expect(chat.onlySubagentsWork, isFalse);
    });

    // REVISION-4 (P0 guard): the placeholder and its own child in one batch
    // (no read in between) are still one subagent.
    test('placeholder and its child back-to-back, one read: 1', () async {
      final (chat, gateway, _) = await begin();
      addTearDown(chat.dispose);
      gateway.emit('tool.start', {'name': 'delegate_task', 'tool_id': 'call-b'});
      gateway.emit('subagent.start', {
        ...child('sa-0-bbbb'),
        'child_session_id': 'child-bbbb',
      });
      await _settle();
      expect(chat.conversationSubagents, hasLength(1));
      expect(chat.conversationSubagents.single.subagentId, 'sa-0-bbbb');
    });

    test('a batch of two goals in one call stays two (no phantom third)',
        () async {
      final (chat, gateway, seen) = await begin();
      addTearDown(chat.dispose);
      Future<void> step(String type, Map<String, dynamic> payload) async {
        gateway.emit(type, payload);
        await _settle();
        seen.add(chat.conversationSubagents.length);
      }

      await step('tool.start', {'name': 'delegate_task', 'tool_id': 'call-2'});
      await step(
        'subagent.spawn_requested',
        {...child('sa-0-a', goalText: 'goal A'), 'task_count': 2},
      );
      await step('subagent.spawn_requested', {
        ...child('sa-1-b', goalText: 'goal B', index: 1),
        'task_count': 2,
      });
      for (final id in ['sa-0-a', 'sa-1-b']) {
        await step('subagent.start', {
          'subagent_id': id,
          'child_session_id': 'child-$id',
          'task_count': 2,
        });
      }
      await step('tool.complete', {
        'name': 'delegate_task',
        'tool_id': 'call-2',
        'result': {
          'status': 'dispatched',
          'mode': 'background',
          'count': 2,
          'delegation_id': 'deleg-2',
          'goals': ['goal A', 'goal B'],
          'subagent_ids': ['sa-0-a', 'sa-1-b'],
        },
      });

      expect(seen, [1, 1, 2, 2, 2, 2]);
      expect(
        chat.conversationSubagents.map((a) => a.subagentId).toSet(),
        {'sa-0-a', 'sa-1-b'},
      );
      expect(
        SubagentGroupCount.of(chat.conversationSubagents),
        const SubagentGroupCount(0, 2),
      );
    });

    test('a retry of the same goal after a failure is two: failed + running',
        () async {
      final (chat, gateway, seen) = await begin();
      addTearDown(chat.dispose);
      Future<void> step(String type, Map<String, dynamic> payload) async {
        gateway.emit(type, payload);
        await _settle();
        seen.add(chat.conversationSubagents.length);
      }

      await step('tool.start', {'name': 'delegate_task', 'tool_id': 'call-a'});
      await step('subagent.spawn_requested', child('sa-0-first'));
      await step('subagent.complete', {
        ...child('sa-0-first'),
        'status': 'failed',
      });
      await step('tool.complete', {
        'name': 'delegate_task',
        'tool_id': 'call-a',
        'result': {
          'status': 'failed',
          'delegation_id': 'deleg-a',
          'subagent_ids': ['sa-0-first'],
        },
        'success': false,
      });
      await step('tool.start', {'name': 'delegate_task', 'tool_id': 'call-b'});
      await step('subagent.spawn_requested', child('sa-0-second'));
      await step('subagent.start', {
        ...child('sa-0-second'),
        'child_session_id': 'child-second',
      });

      expect(seen, [1, 1, 1, 1, 1, 2, 2]);
      final phases = {
        for (final a in chat.conversationSubagents) a.subagentId: a.phase,
      };
      expect(phases, {
        'sa-0-first': SubagentActivityPhase.failed,
        'sa-0-second': SubagentActivityPhase.running,
      });
    });
  });
}
