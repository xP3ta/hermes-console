import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

void main() {
  const scope = GlobalActivityScope(
    connectionId: 'connection-a',
    profile: 'default',
    durableSessionId: 'durable-a',
    runtimeSessionId: 'runtime-a',
    replayEpoch: 'epoch-a',
  );

  test(
    'authoritative roster exposes unopened remote work and closes absence',
    () {
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => DateTime.utc(2026),
      );
      final request = aggregate.beginRosterRequest('connection-a', 'default');

      aggregate.applyRoster(
        connectionId: 'connection-a',
        profile: 'default',
        replayEpoch: 'epoch-a',
        requestGeneration: request,
        roster: const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-a',
              storedSessionId: 'durable-a',
              status: 'working',
            ),
          ],
        ),
      );

      expect(
        aggregate.activityFor('connection-a', 'default', 'durable-a')?.phase,
        GlobalActivityPhase.generating,
      );
      expect(
        aggregate.isActive('connection-a', 'default', 'durable-a'),
        isTrue,
      );

      aggregate.applyRoster(
        connectionId: 'connection-a',
        profile: 'default',
        replayEpoch: 'epoch-a',
        requestGeneration: aggregate.beginRosterRequest(
          'connection-a',
          'default',
        ),
        roster: const DesktopActiveSessionList(),
      );
      expect(
        aggregate.activityFor('connection-a', 'default', 'durable-a'),
        isNull,
      );
    },
  );

  test('event detail wins over an older roster response', () {
    final aggregate = GlobalActivityAggregate.inMemory(
      now: () => DateTime.utc(2026),
    );
    final slowRequest = aggregate.beginRosterRequest('connection-a', 'default');
    aggregate.observeEvent(
      scope: scope,
      event: const TuiGatewayEvent(
        type: 'tool.start',
        sessionId: 'runtime-a',
        sequence: 8,
        payload: {'name': 'private_tool', 'arguments': 'private'},
      ),
    );
    aggregate.applyRoster(
      connectionId: 'connection-a',
      profile: 'default',
      replayEpoch: 'epoch-a',
      requestGeneration: slowRequest,
      roster: const DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-a',
            storedSessionId: 'durable-a',
            status: 'working',
          ),
        ],
      ),
    );
    final activity = aggregate.activityFor(
      'connection-a',
      'default',
      'durable-a',
    )!;
    expect(activity.phase, GlobalActivityPhase.usingTools);
    expect(activity.toolCount, 1);
    expect(activity.sequence, 8);
  });

  test('runtime recycling cannot inherit phase or sequence', () {
    final aggregate = GlobalActivityAggregate.inMemory(
      now: () => DateTime.utc(2026),
    );
    aggregate.observeEvent(
      scope: scope,
      event: const TuiGatewayEvent(
        type: 'tool.start',
        sessionId: 'runtime-a',
        sequence: 8,
        payload: {},
      ),
    );
    final request = aggregate.beginRosterRequest('connection-a', 'default');
    aggregate.applyRoster(
      connectionId: 'connection-a',
      profile: 'default',
      replayEpoch: 'epoch-a',
      requestGeneration: request,
      roster: const DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-b',
            storedSessionId: 'durable-a',
            status: 'working',
          ),
        ],
      ),
    );
    final activity = aggregate.activityFor(
      'connection-a',
      'default',
      'durable-a',
    )!;
    expect(activity.scope.runtimeSessionId, 'runtime-b');
    expect(activity.phase, GlobalActivityPhase.generating);
    expect(activity.toolCount, 0);
    expect(activity.sequence, isNull);
  });

  test(
    'private bounded journal restores stale public progress after process death',
    () async {
      String? encryptedEnvelope;
      final journal = GlobalActivityJournal(
        read: () async => encryptedEnvelope,
        write: (value) async => encryptedEnvelope = value,
        now: () => DateTime.utc(2026, 1, 1, 12),
        maxEntries: 2,
        ttl: const Duration(hours: 1),
      );
      final writer = GlobalActivityAggregate(
        journal: journal,
        now: () => DateTime.utc(2026, 1, 1, 12),
      );
      await writer.initialize();
      writer.observeEvent(
        scope: scope,
        event: const TuiGatewayEvent(
          type: 'approval.request',
          sessionId: 'runtime-a',
          sequence: 9,
          payload: {
            'prompt': 'PRIVATE_MARKER',
            'tool': 'PRIVATE_TOOL',
            'path': '/private/path',
          },
        ),
      );
      await writer.flushJournal();
      expect(encryptedEnvelope, isNot(contains('PRIVATE_MARKER')));
      expect(encryptedEnvelope, isNot(contains('PRIVATE_TOOL')));
      expect(encryptedEnvelope, isNot(contains('/private/path')));

      final reader = GlobalActivityAggregate(
        journal: GlobalActivityJournal(
          read: () async => encryptedEnvelope,
          write: (_) async {},
          now: () => DateTime.utc(2026, 1, 1, 12, 30),
          maxEntries: 2,
          ttl: const Duration(hours: 1),
        ),
        now: () => DateTime.utc(2026, 1, 1, 12, 30),
      );
      await reader.initialize();
      final restored = reader.activityFor(
        'connection-a',
        'default',
        'durable-a',
      )!;
      expect(restored.phase, GlobalActivityPhase.waitingForUser);
      expect(restored.requiresAction, isTrue);
      expect(restored.stale, isTrue);
      expect(restored.authority, GlobalActivityAuthority.journal);
    },
  );

  test(
    'journal fails closed for expired, corrupt, terminal and foreign-profile rows',
    () async {
      final journal = GlobalActivityJournal(
        read: () async => '''{"version":1,"entries":[
        {"connection":"connection-a","profile":"default","durable":"expired","runtime":"r","epoch":"e","phase":"generating","terminal":false,"requires_action":false,"tools":0,"subagents":0,"processes":0,"observed_at":1},
        {"connection":"connection-a","profile":"other","durable":"other","runtime":"r","epoch":"e","phase":"generating","terminal":false,"requires_action":false,"tools":0,"subagents":0,"processes":0,"observed_at":1767268800000},
        {"connection":"connection-a","profile":"default","durable":"terminal","runtime":"r","epoch":"e","phase":"completed","terminal":true,"requires_action":false,"tools":0,"subagents":0,"processes":0,"observed_at":1767268800000},
        {"connection":"connection-a","profile":"default","durable":"bad","runtime":"r","epoch":"e","phase":"prompt text","terminal":false,"requires_action":false,"tools":0,"subagents":0,"processes":0,"observed_at":1767268800000}
      ]}''',
        write: (_) async {},
        now: () => DateTime.utc(2026, 1, 1, 13),
        ttl: const Duration(minutes: 30),
      );
      final aggregate = GlobalActivityAggregate(
        journal: journal,
        now: () => DateTime.utc(2026, 1, 1, 13),
      );
      await aggregate.initialize(
        connectionId: 'connection-a',
        profile: 'default',
      );
      expect(aggregate.activities, isEmpty);
    },
  );

  test(
    'recovery retains live state then invalidates watermark on epoch rotation',
    () {
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => DateTime.utc(2026),
      );
      aggregate.observeEvent(
        scope: scope,
        event: const TuiGatewayEvent(
          type: 'tool.start',
          sessionId: 'runtime-a',
          sequence: 8,
          payload: {},
        ),
      );
      aggregate.beginRecovery('connection-a', 'default');
      expect(
        aggregate.activityFor('connection-a', 'default', 'durable-a')?.phase,
        GlobalActivityPhase.usingTools,
      );

      aggregate.applyRecoverySnapshot(
        scope: const GlobalActivityScope(
          connectionId: 'connection-a',
          profile: 'default',
          durableSessionId: 'durable-a',
          runtimeSessionId: 'runtime-a',
          replayEpoch: 'epoch-b',
        ),
        running: true,
        waitingForUser: false,
        replayTruncated: true,
        processCount: 0,
      );
      final recovered = aggregate.activityFor(
        'connection-a',
        'default',
        'durable-a',
      )!;
      expect(recovered.phase, GlobalActivityPhase.unknown);
      expect(recovered.authority, GlobalActivityAuthority.snapshot);
      expect(recovered.sequence, isNull);
      expect(recovered.scope.replayEpoch, 'epoch-b');
    },
  );

  test(
    'authoritative process list reconciles background continuity by count',
    () {
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => DateTime.utc(2026),
      );
      aggregate.observeEvent(
        scope: scope,
        event: const TuiGatewayEvent(
          type: 'message.start',
          sessionId: 'runtime-a',
          sequence: 1,
          payload: {},
        ),
      );
      aggregate.applyProcessList(scope: scope, activeProcessCount: 2);
      expect(
        aggregate.activityFor('connection-a', 'default', 'durable-a')?.phase,
        GlobalActivityPhase.backgroundWork,
      );
      expect(
        aggregate
            .activityFor('connection-a', 'default', 'durable-a')
            ?.processCount,
        2,
      );
      aggregate.applyProcessList(scope: scope, activeProcessCount: 0);
      expect(
        aggregate.activityFor('connection-a', 'default', 'durable-a')?.phase,
        GlobalActivityPhase.generating,
      );
    },
  );

  test(
    'a newer roster observation starts a second turn in the same runtime',
    () {
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => DateTime.utc(2026),
      );
      var request = aggregate.beginRosterRequest('connection-a', 'default');
      aggregate.applyRoster(
        connectionId: 'connection-a',
        profile: 'default',
        replayEpoch: 'epoch-a',
        requestGeneration: request,
        roster: const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-a',
              storedSessionId: 'durable-a',
              status: 'working',
            ),
          ],
        ),
      );
      aggregate.observeEvent(
        scope: scope,
        event: const TuiGatewayEvent(
          type: 'message.complete',
          sessionId: 'runtime-a',
          sequence: 4,
          payload: {'status': 'completed'},
        ),
      );
      request = aggregate.beginRosterRequest('connection-a', 'default');
      aggregate.applyRoster(
        connectionId: 'connection-a',
        profile: 'default',
        replayEpoch: 'epoch-a',
        requestGeneration: request,
        roster: const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-a',
              storedSessionId: 'durable-a',
              status: 'working',
            ),
          ],
        ),
      );
      expect(
        aggregate.isActive('connection-a', 'default', 'durable-a'),
        isTrue,
      );
    },
  );

  test('an older roster response cannot revive terminal evidence', () {
    final aggregate = GlobalActivityAggregate.inMemory(
      now: () => DateTime.utc(2026),
    );
    final oldRequest = aggregate.beginRosterRequest('connection-a', 'default');
    aggregate.observeEvent(
      scope: scope,
      event: const TuiGatewayEvent(
        type: 'message.complete',
        sessionId: 'runtime-a',
        sequence: 4,
        payload: {'status': 'interrupted'},
      ),
    );
    aggregate.applyRoster(
      connectionId: 'connection-a',
      profile: 'default',
      replayEpoch: 'epoch-a',
      requestGeneration: oldRequest,
      roster: const DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-a',
            storedSessionId: 'durable-a',
            status: 'working',
          ),
        ],
      ),
    );
    expect(
      aggregate.activityFor('connection-a', 'default', 'durable-a'),
      isNull,
    );
  });

  test('real blocking request and expiry families reduce as public state', () {
    const requestTypes = <String>[
      'approval.request',
      'clarify.request',
      'input.request',
      'sudo.request',
      'secret.request',
      'handoff.request',
      'tour.request',
      'vault.login.request',
      'terminal.read.request',
      'preview.open.request',
      'window.read.request',
      'mcp.setup.request',
    ];
    for (final type in requestTypes) {
      final aggregate = GlobalActivityAggregate.inMemory();
      aggregate.observeEvent(
        scope: scope,
        event: TuiGatewayEvent(
          type: type,
          sessionId: 'runtime-a',
          payload: const {},
        ),
      );
      var activity = aggregate.activityFor(
        'connection-a',
        'default',
        'durable-a',
      )!;
      expect(activity.phase, GlobalActivityPhase.waitingForUser, reason: type);
      expect(activity.requiresAction, isTrue, reason: type);
      aggregate.observeEvent(
        scope: scope,
        event: TuiGatewayEvent(
          type: type.replaceFirst(RegExp(r'\.request$'), '.expire'),
          sessionId: 'runtime-a',
          payload: const {},
        ),
      );
      activity = aggregate.activityFor('connection-a', 'default', 'durable-a')!;
      expect(activity.phase, GlobalActivityPhase.generating, reason: type);
      expect(activity.requiresAction, isFalse, reason: type);
    }
  });

  test('waiting roster is actionable and subagent.text is delegated', () {
    final aggregate = GlobalActivityAggregate.inMemory();
    final generation = aggregate.beginRosterRequest('connection-a', 'default');
    aggregate.applyRoster(
      connectionId: 'connection-a',
      profile: 'default',
      replayEpoch: 'epoch-a',
      requestGeneration: generation,
      roster: const DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-a',
            storedSessionId: 'durable-a',
            status: 'waiting',
          ),
        ],
      ),
    );
    expect(
      aggregate
          .activityFor('connection-a', 'default', 'durable-a')
          ?.requiresAction,
      isTrue,
    );
    aggregate.observeGatewayEvent(
      connectionId: 'connection-a',
      profile: 'default',
      event: const TuiGatewayEvent(
        type: 'subagent.text',
        sessionId: 'runtime-a',
        payload: {},
      ),
    );
    expect(
      aggregate.activityFor('connection-a', 'default', 'durable-a')?.phase,
      GlobalActivityPhase.delegated,
    );
  });

  test('stale public projection stops claiming liveness after its ceiling', () {
    var now = DateTime.utc(2026);
    final aggregate = GlobalActivityAggregate.inMemory(now: () => now);
    aggregate.observeEvent(
      scope: scope,
      event: const TuiGatewayEvent(
        type: 'message.start',
        sessionId: 'runtime-a',
        payload: {},
      ),
    );
    aggregate.markTransportStale('connection-a', 'default');
    expect(aggregate.isActive('connection-a', 'default', 'durable-a'), isTrue);
    now = now.add(const Duration(minutes: 2));
    expect(aggregate.isActive('connection-a', 'default', 'durable-a'), isFalse);
  });

  test(
    'terminal exact incarnation is absorbing but a proven successor may work',
    () {
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => DateTime.utc(2026),
      );
      var generation = aggregate.beginRosterRequest('connection-a', 'default');
      aggregate.observeEvent(
        scope: scope,
        event: const TuiGatewayEvent(
          type: 'message.complete',
          sessionId: 'runtime-a',
          sequence: 4,
          payload: {'status': 'interrupted'},
        ),
      );
      aggregate.applyRoster(
        connectionId: 'connection-a',
        profile: 'default',
        replayEpoch: 'epoch-a',
        requestGeneration: generation,
        roster: const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-a',
              storedSessionId: 'durable-a',
              status: 'working',
            ),
          ],
        ),
      );
      expect(
        aggregate.activityFor('connection-a', 'default', 'durable-a'),
        isNull,
      );

      generation = aggregate.beginRosterRequest('connection-a', 'default');
      aggregate.applyRoster(
        connectionId: 'connection-a',
        profile: 'default',
        replayEpoch: 'epoch-b',
        requestGeneration: generation,
        roster: const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-b',
              storedSessionId: 'durable-a',
              status: 'working',
            ),
          ],
        ),
      );
      expect(
        aggregate.activityFor('connection-a', 'default', 'durable-a')?.active,
        isTrue,
      );
    },
  );

  group('onTerminal', () {
    test('fires once for a proven busy→terminal transition', () {
      final seen = <(GlobalActivityScope, GlobalActivityPhase)>[];
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => DateTime.utc(2026),
        onTerminal: (scope, phase) => seen.add((scope, phase)),
      );
      aggregate.observeEvent(
        scope: scope,
        event: const TuiGatewayEvent(
          type: 'tool.start',
          sessionId: 'runtime-a',
          sequence: 1,
          payload: {},
        ),
      );
      aggregate.observeEvent(
        scope: scope,
        event: const TuiGatewayEvent(
          type: 'message.complete',
          sessionId: 'runtime-a',
          sequence: 2,
          payload: {'status': 'ok'},
        ),
      );
      expect(seen, hasLength(1));
      expect(seen.single.$1.durableSessionId, 'durable-a');
      expect(seen.single.$2, GlobalActivityPhase.completed);
    });

    test('does not fire for a terminal event with no prior busy activity', () {
      final seen = <(GlobalActivityScope, GlobalActivityPhase)>[];
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => DateTime.utc(2026),
        onTerminal: (scope, phase) => seen.add((scope, phase)),
      );
      aggregate.observeEvent(
        scope: scope,
        event: const TuiGatewayEvent(
          type: 'message.complete',
          sessionId: 'runtime-a',
          sequence: 1,
          payload: {'status': 'ok'},
        ),
      );
      expect(seen, isEmpty);
    });

    test('does not fire for a non-terminal (live) event', () {
      final seen = <(GlobalActivityScope, GlobalActivityPhase)>[];
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => DateTime.utc(2026),
        onTerminal: (scope, phase) => seen.add((scope, phase)),
      );
      aggregate.observeEvent(
        scope: scope,
        event: const TuiGatewayEvent(
          type: 'tool.start',
          sessionId: 'runtime-a',
          sequence: 1,
          payload: {},
        ),
      );
      aggregate.observeEvent(
        scope: scope,
        event: const TuiGatewayEvent(
          type: 'tool.complete',
          sessionId: 'runtime-a',
          sequence: 2,
          payload: {},
        ),
      );
      expect(seen, isEmpty);
    });

    test('maps failed and interrupted phases to their wire state', () {
      expect(
        sessionActivityPhaseWire(GlobalActivityPhase.completed),
        'completed',
      );
      expect(sessionActivityPhaseWire(GlobalActivityPhase.failed), 'failed');
      expect(
        sessionActivityPhaseWire(GlobalActivityPhase.interrupted),
        'interrupted',
      );
    });
  });
}
