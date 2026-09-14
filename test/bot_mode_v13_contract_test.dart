import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/bot_mode_v13.dart';

void main() {
  group('V13 work authority and privacy', () {
    final snapshot = MissionBackendSnapshot(
      profiles: const [AgentProfile(name: 'infra')],
      board: const KanbanBoard(
        boardId: 'ops',
        columns: [
          KanbanColumn(
            name: 'running',
            tasks: [
              KanbanTask(
                id: 'same-id',
                title: 'Deploy services',
                body: '',
                status: 'running',
              ),
            ],
          ),
        ],
      ),
      profilesCapability: MissionCapabilityState.available,
      sessionsCapability: MissionCapabilityState.available,
      kanbanCapability: MissionCapabilityState.available,
      loadedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    const mission = MissionProjection();

    test('hostile approval projects only bounded generic copy', () {
      const approval = MissionApproval(
        profileName: 'infra',
        sessionId: 'session-secret-7',
        sessionTitle: 'https://secret.invalid/session',
        requestId: 'request-secret-9',
        description: 'rm -rf /private/path data:image/png;base64,SECRET',
        risk: 'tool: shell args: --force',
      );
      final source = ApprovalSourcePrivate(
        approval: approval,
        candidateRoute: const CanonicalHandoffRoute(
          connectionId: 'owner-a',
          profile: 'infra',
          runtimeSessionId: 'session-secret-7',
          requestId: 'request-secret-9',
          kind: HandoffKind.approval,
          sourceGeneration: 4,
        ),
        sourceGeneration: 4,
      );

      final view = projectApprovalPublic(source);
      final item = WorkItem.approval(
        stableKey: 'approval-public-1',
        view: view,
      );
      final publicText =
          '${item.title}|${item.decisionCopy}|${item.attention.name}';

      expect(item.approvalView, same(view));
      expect(item.destination, isNull);
      expect(
        publicText,
        'Aprobación pendiente|Decide si quieres continuar|needsDecision',
      );
      for (final secret in const [
        'rm -rf',
        '/private/path',
        'data:image',
        'session-secret',
        'request-secret',
        'https://',
        'tool',
        'args',
      ]) {
        expect(publicText, isNot(contains(secret)));
      }
    });

    test('approval destination encodes read/write and fails closed', () {
      const route = CanonicalHandoffRoute(
        connectionId: 'owner-a',
        profile: 'infra',
        runtimeSessionId: 'runtime-1',
        requestId: 'request-1',
        kind: HandoffKind.approval,
        sourceGeneration: 7,
      );
      const approval = MissionApproval(
        profileName: 'infra',
        sessionId: 'runtime-1',
        sessionTitle: 'Bot Chat',
        requestId: 'request-1',
        description: 'private',
      );
      final item = WorkItem.approval(
        stableKey: 'approval-1',
        view: ApprovalPublicViewData.pending(),
      );
      final source = ApprovalSourcePrivate(
        approval: approval,
        candidateRoute: route,
        sourceGeneration: 7,
      );

      final writable = resolveWorkDestination(
        item: item,
        privateSource: source,
        snapshot: snapshot,
        mission: mission,
        capabilities: RouteCapabilities.complete(
          connectionId: 'owner-a',
          generation: 7,
          availability: CapabilityAvailability.available,
        ),
        liveHandoffs: const [route],
      );
      expect(writable, isA<ApprovalDestination>());
      expect((writable! as ApprovalDestination).mode, WorkRouteMode.write);

      final readOnly = resolveWorkDestination(
        item: item,
        privateSource: source,
        snapshot: snapshot,
        mission: mission,
        capabilities: RouteCapabilities.complete(
          connectionId: 'owner-a',
          generation: 7,
          availability: CapabilityAvailability.readOnly,
        ),
        liveHandoffs: const [route],
        previouslyValidatedDestination: writable,
      );
      expect((readOnly! as ApprovalDestination).mode, WorkRouteMode.read);

      final readOnlyWithoutPrior = resolveWorkDestination(
        item: item,
        privateSource: source,
        snapshot: snapshot,
        mission: mission,
        capabilities: RouteCapabilities.complete(
          connectionId: 'owner-a',
          generation: 7,
          availability: CapabilityAvailability.readOnly,
        ),
        liveHandoffs: const [route],
      );
      expect(readOnlyWithoutPrior, isNull);

      final staleGeneration = resolveWorkDestination(
        item: item,
        privateSource: source,
        snapshot: snapshot,
        mission: mission,
        capabilities: RouteCapabilities.complete(
          connectionId: 'owner-a',
          generation: 8,
          availability: CapabilityAvailability.available,
        ),
        liveHandoffs: const [route],
      );
      expect(staleGeneration, isNull);
    });

    test('task destination is board-qualified and never falls back by id', () {
      const item = WorkItem.task(
        stableKey: 'task-ops-same-id',
        title: 'Deploy services',
        decisionCopy: 'En curso',
        attention: WorkAttention.running,
        taskRef: BoardTaskRef(boardId: 'ops', taskId: 'same-id'),
      );
      final capabilities = RouteCapabilities.complete(
        connectionId: 'owner-a',
        generation: 3,
        availability: CapabilityAvailability.available,
      );
      final exact = resolveWorkDestination(
        item: item,
        privateSource: const BoardTaskSourcePrivate(
          connectionId: 'owner-a',
          boardId: 'ops',
          taskId: 'same-id',
          sourceGeneration: 3,
        ),
        snapshot: snapshot,
        mission: mission,
        capabilities: capabilities,
        liveHandoffs: const [],
      );
      expect(exact, isA<TaskDestination>());
      expect((exact! as TaskDestination).mode, WorkRouteMode.write);

      final staleWithoutPrior = resolveWorkDestination(
        item: item,
        privateSource: const BoardTaskSourcePrivate(
          connectionId: 'owner-a',
          boardId: 'ops',
          taskId: 'same-id',
          sourceGeneration: 3,
        ),
        snapshot: snapshot,
        mission: mission,
        capabilities: RouteCapabilities.complete(
          connectionId: 'owner-a',
          generation: 3,
          availability: CapabilityAvailability.stale,
        ),
        liveHandoffs: const [],
      );
      expect(staleWithoutPrior, isNull);

      final staleWithPrior = resolveWorkDestination(
        item: item,
        privateSource: const BoardTaskSourcePrivate(
          connectionId: 'owner-a',
          boardId: 'ops',
          taskId: 'same-id',
          sourceGeneration: 3,
        ),
        snapshot: snapshot,
        mission: mission,
        capabilities: RouteCapabilities.complete(
          connectionId: 'owner-a',
          generation: 3,
          availability: CapabilityAvailability.stale,
        ),
        liveHandoffs: const [],
        previouslyValidatedDestination: exact,
      );
      expect((staleWithPrior! as TaskDestination).mode, WorkRouteMode.read);

      final wrongBoard = resolveWorkDestination(
        item: item,
        privateSource: const BoardTaskSourcePrivate(
          connectionId: 'owner-a',
          boardId: 'other',
          taskId: 'same-id',
          sourceGeneration: 3,
        ),
        snapshot: snapshot,
        mission: mission,
        capabilities: capabilities,
        liveHandoffs: const [],
      );
      expect(wrongBoard, isNull);
    });
  });
}
