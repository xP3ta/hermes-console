import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/mission_organization_store.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session _session({
  String id = 's-1',
  String? profile = 'infra',
  int input = 0,
  int output = 0,
  int reasoning = 0,
  int? cacheRead,
  double? estimated,
  double? actual,
  double updated = 100,
}) => Session(
  id: id,
  title: 'Session $id',
  model: 'model-a',
  source: 'gateway',
  messageCount: 2,
  isActive: true,
  preview: '',
  startedAt: 90,
  updatedAt: updated,
  profile: profile,
  inputTokens: input,
  outputTokens: output,
  reasoningTokens: reasoning,
  cacheReadTokens: cacheRead,
  estimatedCostUsd: estimated,
  actualCostUsd: actual,
);

const _profiles = [
  AgentProfile(name: 'infra', model: 'qwen', provider: 'local'),
  AgentProfile(name: 'security', model: 'cloud-small', provider: 'router'),
];

MissionBackendSnapshot _snapshot({
  List<Session> sessions = const [],
  List<KanbanTask> tasks = const [],
}) => MissionBackendSnapshot(
  profiles: _profiles,
  sessions: sessions,
  board: KanbanBoard(
    columns: [KanbanColumn(name: 'all', tasks: tasks)],
  ),
  profilesCapability: MissionCapabilityState.available,
  sessionsCapability: MissionCapabilityState.available,
  kanbanCapability: MissionCapabilityState.available,
  loadedAt: DateTime.fromMillisecondsSinceEpoch(100000),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MissionOrganization', () {
    test('bounds profile data and clears an invalid manager', () {
      final organization = MissionOrganization(
        id: 'org-1',
        connectionId: 'connection-a',
        name: 'Homelab',
        profileNames: const ['infra', 'INVALID PROFILE', 'security'],
        managerProfile: 'manager-that-is-not-a-member',
        createdAtMs: 1,
        updatedAtMs: 2,
      );

      expect(organization.profileNames, {'infra', 'security'});
      expect(organization.managerProfile, isNull);
      expect(
        organization
            .copyWith(profileNames: const ['infra'], managerProfile: 'security')
            .managerProfile,
        isNull,
      );
    });

    test('rejects malformed payloads without throwing', () {
      expect(MissionOrganization.tryParse('not-a-map'), isNull);
      expect(MissionOrganization.tryParse({'id': 'missing-fields'}), isNull);
      final parsed = MissionOrganization.tryParse({
        'id': 'org-1',
        'connection_id': 'connection-a',
        'name': 'Homelab',
        'profile_names': ['infra', 42, '../escape'],
        'manager_profile': '../escape',
        'created_at_ms': -10,
      });
      expect(parsed?.profileNames, {'infra'});
      expect(parsed?.managerProfile, isNull);
      expect(parsed?.createdAtMs, 0);
    });
  });

  group('MissionOrganizationStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test(
      'isolates organizations by connection and survives new instances',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final store = MissionOrganizationStore(prefs);
        await store.save(
          connectionId: 'connection-a',
          name: 'Homelab',
          profileNames: const ['infra'],
        );

        final reopened = MissionOrganizationStore(prefs);
        expect(reopened.load('connection-a').single.name, 'Homelab');
        expect(reopened.load('connection-b'), isEmpty);
      },
    );

    test('treats corrupt or cross-instance storage as empty', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'mission_control.organizations.v1.connection-a',
        '{broken json',
      );
      final store = MissionOrganizationStore(prefs);
      expect(store.load('connection-a'), isEmpty);

      await prefs.setString(
        'mission_control.organizations.v1.connection-a',
        jsonEncode([
          {
            'id': 'org-b',
            'connection_id': 'connection-b',
            'name': 'Wrong instance',
            'profile_names': ['infra'],
          },
        ]),
      );
      expect(store.load('connection-a'), isEmpty);
    });

    test('concurrent organization saves preserve both rows', () async {
      final store = MissionOrganizationStore(
        await SharedPreferences.getInstance(),
      );

      await Future.wait([
        store.save(
          connectionId: 'connection-a',
          name: 'Homelab',
          profileNames: const ['infra'],
        ),
        store.save(
          connectionId: 'connection-a',
          name: 'Business',
          profileNames: const ['developer'],
        ),
      ]);

      expect(
        store.load('connection-a').map((value) => value.name),
        containsAll(['Homelab', 'Business']),
      );
    });

    test(
      'fails closed when organization persistence is not confirmed',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final store = MissionOrganizationStore(
          prefs,
          setString: (_, _) async => false,
        );

        await expectLater(
          store.save(
            connectionId: 'connection-a',
            name: 'Homelab',
            profileNames: const ['infra'],
          ),
          throwsA(isA<StateError>()),
        );
        expect(store.load('connection-a'), isEmpty);
      },
    );
  });

  group('MissionProjector', () {
    test('prefers running work regardless of blocked task age', () {
      MissionAgent project(List<KanbanTask> tasks) => MissionProjector.build(
        snapshot: _snapshot(tasks: tasks),
      ).agents.firstWhere((agent) => agent.profile.name == 'infra');

      final newerRunning = project(const [
        KanbanTask(
          id: 'blocked-old',
          title: 'Historical blocker',
          body: '',
          status: 'blocked',
          assignee: 'infra',
          createdAt: 10,
        ),
        KanbanTask(
          id: 'running-new',
          title: 'Live work',
          body: '',
          status: 'running',
          assignee: 'infra',
          createdAt: 20,
          startedAt: 30,
        ),
      ]);

      expect(newerRunning.status, MissionAgentStatus.working);
      expect(newerRunning.statusEvidence, 'kanban.running:running-new');
      expect(newerRunning.currentTask?.id, 'running-new');

      final olderRunning = project(const [
        KanbanTask(
          id: 'running-old',
          title: 'Live work',
          body: '',
          status: 'running',
          assignee: 'infra',
          startedAt: 10,
        ),
        KanbanTask(
          id: 'blocked-new',
          title: 'New blocker',
          body: '',
          status: 'blocked',
          assignee: 'infra',
          createdAt: 30,
        ),
      ]);

      expect(olderRunning.status, MissionAgentStatus.working);
      expect(olderRunning.statusEvidence, 'kanban.running:running-old');
      expect(olderRunning.currentTask?.id, 'running-old');
    });

    test('fresh official worker outranks a blocked task', () {
      final snapshot = MissionBackendSnapshot(
        profiles: const [
          AgentProfile(
            name: 'infra',
            workerSession: AgentProfileWorkerSession(
              id: 'worker-kanban-42',
              source: 'kanban',
              title: 'Live worker',
              lastActive: 100,
            ),
          ),
        ],
        board: const KanbanBoard(
          columns: [
            KanbanColumn(
              name: 'blocked',
              tasks: [
                KanbanTask(
                  id: 'blocked-1',
                  title: 'Historical blocker',
                  body: '',
                  status: 'blocked',
                  assignee: 'infra',
                ),
              ],
            ),
          ],
        ),
        loadedAt: DateTime.fromMillisecondsSinceEpoch(100000),
      );
      final agent = MissionProjector.build(
        snapshot: snapshot,
        liveChats: const [
          MissionLiveChat(
            profileName: 'infra',
            sessionId: 'idle-chat',
            title: 'Idle chat',
            phase: MissionLivePhase.idle,
          ),
        ],
        now: DateTime.fromMillisecondsSinceEpoch(200000),
      ).agents.single;

      expect(agent.status, MissionAgentStatus.working);
      expect(agent.statusEvidence, 'worker.kanban:worker-kanban-42');

      final stale = MissionProjector.build(
        snapshot: snapshot,
        now: DateTime.fromMillisecondsSinceEpoch(251000),
      ).agents.single;
      expect(stale.status, MissionAgentStatus.blocked);
      expect(stale.statusEvidence, 'kanban.blocked:blocked-1');
    });

    test('never promotes ready work without live evidence', () {
      final agent = MissionProjector.build(
        snapshot: _snapshot(
          tasks: const [
            KanbanTask(
              id: 'ready-1',
              title: 'Queued work',
              body: '',
              status: 'ready',
              assignee: 'infra',
            ),
          ],
        ),
      ).agents.firstWhere((agent) => agent.profile.name == 'infra');

      expect(agent.status, MissionAgentStatus.idle);
      expect(agent.statusEvidence, 'no-live-evidence');
    });

    test(
      'uses strict status precedence and never treats an open session as work',
      () {
        final tasks = [
          const KanbanTask(
            id: 'blocked-1',
            title: 'Waiting for host',
            body: '',
            status: 'blocked',
            assignee: 'infra',
          ),
          const KanbanTask(
            id: 'running-1',
            title: 'Audit',
            body: '',
            status: 'running',
            assignee: 'security',
          ),
        ];
        final base = _snapshot(
          sessions: [
            _session(),
            _session(id: 's-2', profile: 'security'),
          ],
          tasks: tasks,
        );

        final noLive = MissionProjector.build(snapshot: base);
        expect(
          noLive.agents.firstWhere((a) => a.profile.name == 'infra').status,
          MissionAgentStatus.blocked,
        );
        expect(
          noLive.agents.firstWhere((a) => a.profile.name == 'security').status,
          MissionAgentStatus.working,
        );

        final live = MissionProjector.build(
          snapshot: base,
          liveChats: const [
            MissionLiveChat(
              profileName: 'infra',
              sessionId: 's-1',
              title: 'Infra',
              phase: MissionLivePhase.approvalRequired,
              approval: {'command': 'restart node'},
            ),
            MissionLiveChat(
              profileName: 'security',
              sessionId: 's-2',
              title: 'Security',
              phase: MissionLivePhase.error,
            ),
          ],
        );
        expect(live.agents[0].status, MissionAgentStatus.approvalRequired);
        expect(live.agents[1].status, MissionAgentStatus.error);

        final idle = MissionProjector.build(
          snapshot: _snapshot(sessions: [_session()]),
        );
        expect(idle.agents.first.status, MissionAgentStatus.idle);
        expect(idle.agents.first.statusEvidence, 'no-live-evidence');
      },
    );

    test('uses a fresh official worker session as work without polling', () {
      MissionBackendSnapshot withWorker(double lastActive) =>
          MissionBackendSnapshot(
            profiles: [
              AgentProfile(
                name: 'infra',
                workerSession: AgentProfileWorkerSession(
                  id: 'worker-kanban-42',
                  source: 'kanban',
                  title: 'Auditar backups',
                  lastActive: lastActive,
                ),
              ),
            ],
            board: const KanbanBoard(columns: []),
            profilesCapability: MissionCapabilityState.available,
            sessionsCapability: MissionCapabilityState.available,
            kanbanCapability: MissionCapabilityState.available,
            loadedAt: DateTime.fromMillisecondsSinceEpoch(200000),
          );

      final active = MissionProjector.build(
        snapshot: withWorker(100),
        now: DateTime.fromMillisecondsSinceEpoch(240000),
      ).agents.single;
      expect(active.status, MissionAgentStatus.working);
      expect(active.statusEvidence, 'worker.kanban:worker-kanban-42');
      expect(active.lastActivityAt?.millisecondsSinceEpoch, 100000);

      final stale = MissionProjector.build(
        snapshot: withWorker(100),
        now: DateTime.fromMillisecondsSinceEpoch(251000),
      ).agents.single;
      expect(stale.status, MissionAgentStatus.idle);
      expect(stale.statusEvidence, 'no-live-evidence');
    });

    test('aggregates token dimensions and preserves partial cost coverage', () {
      final usage = MissionUsage.fromSessions([
        _session(
          input: 100,
          output: 40,
          reasoning: 7,
          cacheRead: 20,
          estimated: 0.02,
        ),
        _session(id: 's-2', input: 50, output: 10),
      ]);

      expect(usage.inputTokens, 150);
      expect(usage.outputTokens, 50);
      expect(usage.totalTokens, 200);
      expect(usage.reasoningTokens, 7);
      expect(usage.cacheReadTokens, 20);
      expect(usage.estimatedCostUsd, closeTo(0.02, 0.00001));
      expect(usage.actualCostUsd, isNull);
      expect(usage.costCoverage, MissionCostCoverage.partial);
    });

    test('keeps absent usage distinct from a published zero', () {
      final absent = MissionUsage.fromSessions([_session()]);
      expect(absent.inputTokens, isNull);
      expect(absent.outputTokens, isNull);
      expect(absent.reasoningTokens, isNull);
      expect(absent.totalTokens, isNull);
      expect(absent.estimatedCostUsd, isNull);
      expect(absent.actualCostUsd, isNull);

      final publishedZero = MissionUsage.fromSamples([
        MissionUsageSample.fromSession(_session(), tokenFieldsPublished: true),
      ]);
      expect(publishedZero.inputTokens, 0);
      expect(publishedZero.outputTokens, 0);
      expect(publishedZero.reasoningTokens, 0);
      expect(publishedZero.totalTokens, 0);
      expect(publishedZero.estimatedCostUsd, isNull);
      expect(publishedZero.actualCostUsd, isNull);
      expect(publishedZero.estimatedCostCoverage, MissionCostCoverage.none);
      expect(publishedZero.actualCostCoverage, MissionCostCoverage.none);

      final parsedZero = MissionUsage.fromSessions([
        Session.fromJson({
          'id': 'published-zero',
          'input_tokens': 0,
          'output_tokens': 0,
          'reasoning_tokens': 0,
        }),
      ]);
      expect(parsedZero.inputTokens, 0);
      expect(parsedZero.outputTokens, 0);
      expect(parsedZero.reasoningTokens, 0);

      final publishedZeroCost = MissionUsage.fromSamples(const [
        MissionUsageSample(estimatedCostUsd: 0),
      ]);
      expect(publishedZeroCost.estimatedCostUsd, 0);
      expect(
        publishedZeroCost.estimatedCostCoverage,
        MissionCostCoverage.complete,
      );
    });

    test('does not infer token publication from cost alone', () {
      final usage = MissionUsage.fromSessions([_session(estimated: 0.02)]);

      expect(usage.inputTokens, isNull);
      expect(usage.outputTokens, isNull);
      expect(usage.reasoningTokens, isNull);
      expect(usage.estimatedCostUsd, closeTo(0.02, 0.00001));
      expect(usage.actualCostUsd, isNull);
    });

    test('aggregates estimated and actual cost independently', () {
      final usage = MissionUsage.fromSamples(const [
        MissionUsageSample(estimatedCostUsd: 0.02),
        MissionUsageSample(actualCostUsd: 0.03),
      ]);

      expect(usage.estimatedCostUsd, closeTo(0.02, 0.00001));
      expect(usage.actualCostUsd, closeTo(0.03, 0.00001));
      expect(usage.estimatedCostCoverage, MissionCostCoverage.partial);
      expect(usage.actualCostCoverage, MissionCostCoverage.partial);
      expect(usage.costCoverage, MissionCostCoverage.partial);
    });

    test('retains every concurrent approval for a profile', () {
      final projection = MissionProjector.build(
        snapshot: _snapshot(),
        liveChats: const [
          MissionLiveChat(
            profileName: 'infra',
            sessionId: 's-approval-1',
            title: 'First approval',
            phase: MissionLivePhase.approvalRequired,
            approval: {'request_id': 'approval-1', 'tool': 'shell'},
          ),
          MissionLiveChat(
            profileName: 'infra',
            sessionId: 's-approval-2',
            title: 'Second approval',
            phase: MissionLivePhase.approvalRequired,
            approval: {'request_id': 'approval-2', 'tool': 'browser'},
          ),
        ],
      );

      expect(projection.approvals, hasLength(2));
      expect(
        projection.approvals.map((approval) => approval.requestId),
        containsAll(const ['approval-1', 'approval-2']),
      );
      expect(
        projection.agents
            .firstWhere((agent) => agent.profile.name == 'infra')
            .status,
        MissionAgentStatus.approvalRequired,
      );
    });

    test('retains an observed approval when the profile roster is stale', () {
      final projection = MissionProjector.build(
        snapshot: _snapshot(),
        liveChats: const [
          MissionLiveChat(
            profileName: 'renamed-worker',
            sessionId: 's-approval',
            title: 'Pending command',
            phase: MissionLivePhase.approvalRequired,
            approval: {'request_id': 'approval-stale', 'tool': 'shell'},
          ),
        ],
      );

      expect(projection.approvals.single.requestId, 'approval-stale');
      expect(
        projection.agents.where(
          (agent) => agent.profile.name == 'renamed-worker',
        ),
        isEmpty,
      );
    });

    test('does not attribute an ownerless session to default', () {
      final ownerless = _session(
        id: 's-ownerless',
        profile: null,
        input: 10,
        output: 4,
      );
      final projection = MissionProjector.build(
        snapshot: _snapshot(sessions: [ownerless]),
      );

      expect(projection.unattributedSessionCount, 1);
      expect(projection.usage.totalTokens, 14);
      expect(
        projection.agents.every((agent) => agent.currentSession == null),
        isTrue,
      );
      expect(projection.activity.single.profileName, isNull);
    });

    test('uses a live chat identity to attribute an ownerless session', () {
      final ownerless = _session(id: 's-live-owner', profile: null);
      final projection = MissionProjector.build(
        snapshot: _snapshot(sessions: [ownerless]),
        liveChats: const [
          MissionLiveChat(
            profileName: 'security',
            sessionId: 's-live-owner',
            title: 'Security work',
            phase: MissionLivePhase.working,
            model: 'routed-model',
            provider: 'routed-provider',
          ),
        ],
      );
      final security = projection.agents.firstWhere(
        (agent) => agent.profile.name == 'security',
      );

      expect(projection.unattributedSessionCount, 0);
      expect(security.currentSession, same(ownerless));
      expect(security.model, 'routed-model');
      expect(security.provider, 'routed-provider');
    });

    test('a Bot Chat title alone never becomes the canonical profile chat', () {
      final canonical = Session(
        id: 'bot-chat',
        title: 'Bot Chat',
        model: 'bot-model',
        source: 'gateway',
        messageCount: 2,
        isActive: false,
        preview: 'Canonical inbox',
        startedAt: 10,
        updatedAt: 20,
        profile: 'infra',
      );
      final newer = Session(
        id: 'scratch',
        title: 'Scratch work',
        model: 'scratch-model',
        source: 'gateway',
        messageCount: 1,
        isActive: false,
        preview: 'Newer work',
        startedAt: 30,
        updatedAt: 40,
        profile: 'infra',
      );

      final projection = MissionProjector.build(
        snapshot: _snapshot(sessions: [newer, canonical]),
      );

      expect(
        projection.agents
            .firstWhere((agent) => agent.profile.name == 'infra')
            .currentSession,
        same(newer),
      );
    });

    test('prefers the official hidden Bot Chat pin over visible sessions', () {
      final snapshot = MissionBackendSnapshot(
        profiles: const [
          AgentProfile(
            name: 'infra',
            model: 'bot-model',
            botChatSessionId: 'hidden-bot-chat',
          ),
        ],
        sessions: [_session(id: 'visible-newer', profile: 'infra')],
        profilesCapability: MissionCapabilityState.available,
        sessionsCapability: MissionCapabilityState.available,
        loadedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

      final agent = MissionProjector.build(snapshot: snapshot).agents.single;

      expect(agent.currentSession?.id, 'hidden-bot-chat');
      expect(agent.currentSession?.title, 'Bot Chat');
      expect(agent.currentSession?.source, 'bot-mode');
      expect(agent.currentSession?.profile, 'infra');
    });

    test('does not invent a blocked transition timestamp', () {
      final projection = MissionProjector.build(
        snapshot: _snapshot(
          tasks: const [
            KanbanTask(
              id: 'blocked-1',
              title: 'Waiting for host',
              body: '',
              status: 'blocked',
              assignee: 'infra',
              createdAt: 10,
              startedAt: 20,
            ),
          ],
        ),
      );

      expect(
        projection.activity.map((activity) => activity.kind),
        isNot(contains(MissionActivityKind.taskBlocked)),
      );
      expect(
        projection.activity.map((activity) => activity.kind),
        containsAll(const [
          MissionActivityKind.taskCreated,
          MissionActivityKind.taskStarted,
        ]),
      );
    });

    test('bounds malformed approval text and keeps review identity', () {
      final approval = MissionApproval.fromLiveChat(
        MissionLiveChat(
          profileName: 'infra',
          sessionId: 's-1',
          title: 'Infra task',
          phase: MissionLivePhase.approvalRequired,
          approval: {
            'request_id': 99,
            'description': '${'x' * 300}\u0000secret',
            'risk': ['not', 'text'],
          },
        ),
      );

      expect(approval.requestId, isNull);
      expect(approval.description.runes.length, 240);
      expect(approval.description, isNot(contains('\u0000')));
      expect(approval.risk, isNull);
      expect(approval.sessionId, 's-1');
    });
  });

  group('MissionControlRepository', () {
    test('loads Desktop aggregate sessions with every profile owner', () async {
      var fallbackCalls = 0;
      String? endpoint;
      final sessions = await loadMissionControlSessions(
        dashboardGet: (value) async {
          endpoint = value;
          return {
            'sessions': [
              {'id': 'shared-id', 'title': 'Infra', 'profile': 'infra'},
              {'id': 'shared-id', 'title': 'Security', 'profile': 'security'},
            ],
          };
        },
        legacyGatewayLoader: () async {
          fallbackCalls++;
          return const [];
        },
      );

      expect(endpoint, startsWith('profiles/sessions?'));
      expect(Uri.splitQueryString(endpoint!.split('?').last)['profile'], 'all');
      expect(sessions.map((session) => session.profile), ['infra', 'security']);
      expect(sessions.map((session) => session.id), ['shared-id', 'shared-id']);
      expect(fallbackCalls, 0);
    });

    test('falls back to Gateway sessions only for a legacy route', () async {
      var fallbackCalls = 0;
      final sessions = await loadMissionControlSessions(
        dashboardGet: (_) async => throw const DashboardHttpException(404),
        legacyGatewayLoader: () async {
          fallbackCalls++;
          return [_session(id: 'legacy', profile: 'default')];
        },
      );

      expect(fallbackCalls, 1);
      expect(sessions.single.id, 'legacy');
    });

    test(
      'aggregate auth, network and malformed failures never fall back',
      () async {
        final failures = <Future<Map<String, dynamic>> Function()>[
          () async => throw const DashboardHttpException(401),
          () async => throw StateError('offline'),
          () async => {'sessions': 'not-a-list'},
          () async => {
            'sessions': [
              {'id': 'ownerless'},
            ],
          },
          () async => {
            'sessions': [
              {'id': 'partial', 'profile': 'infra'},
            ],
            'errors': ['security unavailable'],
          },
        ];
        for (final failure in failures) {
          var fallbackCalls = 0;
          await expectLater(
            loadMissionControlSessions(
              dashboardGet: (_) => failure(),
              legacyGatewayLoader: () async {
                fallbackCalls++;
                return [_session(id: 'must-not-leak')];
              },
            ),
            throwsA(anything),
          );
          expect(fallbackCalls, 0);
        }
      },
    );

    test('profile fallback is limited to an unsupported Desktop RPC', () async {
      var fallbackCalls = 0;
      final profiles = await loadMissionControlProfiles(
        desktopLoader: () async => throw const TuiGatewayRpcError(
          'profiles.list',
          'unsupported',
          code: -32601,
        ),
        legacyDashboardLoader: () async {
          fallbackCalls++;
          return _profiles;
        },
      );
      expect(profiles, _profiles);
      expect(fallbackCalls, 1);

      for (final error in <Object>[
        const TuiGatewayRpcError('profiles.list', 'forbidden', code: 401),
        StateError('offline'),
      ]) {
        fallbackCalls = 0;
        await expectLater(
          loadMissionControlProfiles(
            desktopLoader: () async => throw error,
            legacyDashboardLoader: () async {
              fallbackCalls++;
              return _profiles;
            },
          ),
          throwsA(anything),
        );
        expect(fallbackCalls, 0);
      }
    });

    test(
      'starts independent loads concurrently and merges their results',
      () async {
        final profiles = Completer<List<AgentProfile>>();
        final sessions = Completer<List<Session>>();
        final board = Completer<KanbanBoard>();
        var started = 0;
        final repository = MissionControlRepository(
          profilesLoader: () {
            started++;
            return profiles.future;
          },
          sessionsLoader: () {
            started++;
            return sessions.future;
          },
          boardLoader: () {
            started++;
            return board.future;
          },
        );

        final pending = repository.load();
        await Future<void>.delayed(Duration.zero);
        expect(started, 3);
        profiles.complete(_profiles);
        sessions.complete([_session()]);
        board.complete(const KanbanBoard(columns: []));
        final result = await pending;

        expect(result.profiles, hasLength(2));
        expect(result.sessions, hasLength(1));
        expect(result.kanbanCapability, MissionCapabilityState.available);
      },
    );

    test('distinguishes unsupported APIs from an offline failure', () async {
      final repository = MissionControlRepository(
        profilesLoader: () async => throw const DashboardHttpException(404),
        sessionsLoader: () async => throw StateError('offline'),
        boardLoader: () async => throw const DashboardHttpException(405),
      );

      final result = await repository.load();
      expect(result.profilesCapability, MissionCapabilityState.unsupported);
      expect(result.sessionsCapability, MissionCapabilityState.unavailable);
      expect(result.kanbanCapability, MissionCapabilityState.unsupported);
      expect(result.failures.keys, {'profiles', 'sessions', 'kanban'});
    });

    test('close is idempotent and prevents later reads', () async {
      var closes = 0;
      final repository = MissionControlRepository(
        profilesLoader: () async => const [],
        sessionsLoader: () async => const [],
        boardLoader: () async => const KanbanBoard(columns: []),
        onClose: () => closes++,
      );
      repository.close();
      repository.close();

      expect(closes, 1);
      await expectLater(repository.load(), throwsStateError);
    });
  });
}
