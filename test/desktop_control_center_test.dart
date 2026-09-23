import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';

void main() {
  group('desktop control centre projections', () {
    test('recovery keeps only bounded render fields', () {
      final result = RecoveryTimeline.fromJson({
        'enabled': true,
        'api_key': 'must-not-survive',
        'checkpoints': [
          {
            'hash': 'abc123',
            'timestamp': '2026-07-22T10:00:00Z',
            'message': 'before edit',
            'secret': 'must-not-survive',
          },
          {'message': 'missing identity'},
        ],
      });

      expect(result.enabled, isTrue);
      expect(result.checkpoints, hasLength(1));
      expect(result.checkpoints.single.hash, 'abc123');
      expect(result.checkpoints.single.toString(), isNot(contains('secret')));
    });

    test('extensions understands modern and legacy plugin rows', () {
      final result = ExtensionsInventory.fromJson(
        plugins: {
          'plugins': [
            {
              'name': 'memory-plus',
              'status': 'enabled',
              'description': 'Local memory provider',
              'source': 'bundled',
            },
            {'name': 'legacy', 'enabled': false},
          ],
        },
        toolsets: {
          'toolsets': [
            {
              'name': 'web',
              'description': 'Web tools',
              'enabled': true,
              'tool_count': 2,
              'tools': ['search', 'fetch'],
            },
          ],
        },
      );

      expect(result.plugins.first.enabled, isTrue);
      expect(result.plugins.last.enabled, isFalse);
      expect(result.toolsets.single.tools, ['search', 'fetch']);
    });

    test('extension management projections discard unallowlisted fields', () {
      final plugin = DesktopPluginManagementEntry.tryParse({
        'name': 'git-plugin',
        'source': 'git',
        'runtime_status': 'enabled',
        'can_update_git': true,
        'can_remove': true,
        'auth_required': false,
        'path': '/home/alice/.hermes/plugins/git-plugin',
        'token': 'secret-that-must-not-survive',
      });
      final catalog = DesktopMcpCatalogEntry.tryParse({
        'name': 'safe-server',
        'description': 'Catalog server',
        'source': 'hermes-catalog',
        'transport': 'stdio',
        'command': 'npx',
        'args': ['server-package'],
        'required_env': [
          {
            'name': 'MCP_TOKEN',
            'prompt': 'Token',
            'required': true,
            'value': 'secret-that-must-not-survive',
          },
        ],
        'env': {'MCP_TOKEN': 'secret-that-must-not-survive'},
      });

      expect(plugin?.name, 'git-plugin');
      expect(plugin.toString(), isNot(contains('/home/alice')));
      expect(plugin.toString(), isNot(contains('secret-that')));
      expect(catalog?.requiredEnv.single.name, 'MCP_TOKEN');
      expect(catalog.toString(), isNot(contains('secret-that')));
    });

    test(
      'plugin installer accepts only bounded credential-free Git sources',
      () {
        for (final value in [
          'nousresearch/example-plugin',
          'https://github.com/nousresearch/example-plugin',
          'https://git.example.test/team/example-plugin.git',
        ]) {
          expect(isSafePluginInstallIdentifier(value), isTrue, reason: value);
        }
        for (final value in [
          '',
          '../plugin',
          '/srv/plugin',
          'http://example.test/plugin',
          'https://user:pass@example.test/plugin',
          'https://example.test/plugin?token=secret',
          'https://example.test/plugin#main',
          'owner/repo/extra',
          'owner /repo',
        ]) {
          expect(isSafePluginInstallIdentifier(value), isFalse, reason: value);
        }
      },
    );

    test('agent center retains only exact controls and status projections', () {
      final result = AgentCenterSnapshot.fromJson(
        snapshots: {
          'entries': [
            {
              'path': '/host/private/spawn.json',
              'session_id': 'private-session',
              'label': 'private delegation label',
              'goal': 'private goal',
              'count': 3,
              'finished_at': 10,
              'metadata': {'model': 'private-model', 'cwd': '/private/path'},
            },
          ],
        },
        processes: {
          'processes': [
            {
              'session_id': 'proc-a',
              'command': 'private command --token secret',
              'status': 'RUNNING',
              'uptime_seconds': 5,
              'started_at': 1720000000,
              'notify_on_complete': true,
              'watch_patterns': ['ready', 'done'],
              'watch_hit': true,
              'output_tail': 'private process output',
              'error': 'private process error',
              'metadata': {'model': 'private-model', 'cwd': '/private/path'},
            },
            {'process_id': 'proc-b', 'status': 'invented private state'},
          ],
        },
      );
      final detail = SpawnTreeDetail.fromJson({
        'session_id': 'private-session',
        'label': 'private tree label',
        'started_at': 1,
        'finished_at': 2,
        'subagents': [
          {
            'id': 'private-agent-id',
            'status': 'completed',
            'goal': 'private goal',
            'summary': 'private summary',
            'result': 'private result',
            'error': 'private error',
            'output': 'private output',
            'metadata': {'model': 'private-model', 'cwd': '/private/path'},
          },
          {'status': 'invented private state'},
          {'phase': 42},
        ],
      });

      expect(result.snapshots.single.opaquePath, '/host/private/spawn.json');
      expect(result.snapshots.single.count, 3);
      expect(result.snapshots.single.finishedAt, 10);
      expect(result.processes.first.opaqueId, 'proc-a');
      expect(result.processes.first.status, AgentCenterStatus.running);
      expect(result.processes.first.uptimeSeconds, 5);
      expect(result.processes.first.command, 'private');
      expect(result.processes.first.command, isNot(contains('secret')));
      expect(result.processes.first.notifyOnComplete, isTrue);
      expect(result.processes.first.watchPatterns, ['ready', 'done']);
      expect(result.processes.first.watchHit, isTrue);
      expect(
        result.processes.first.startedAt,
        DateTime.fromMillisecondsSinceEpoch(1720000000000, isUtc: true),
      );
      expect(result.processes.last.status, AgentCenterStatus.unknown);
      expect(detail.startedAt, 1);
      expect(detail.finishedAt, 2);
      expect(detail.subagents.map((entry) => entry.status), [
        AgentCenterStatus.completed,
        AgentCenterStatus.unknown,
        AgentCenterStatus.unknown,
      ]);
    });

    test('project tree parses overview and hydrated lanes', () {
      final tree = ProjectTreeSnapshot.fromJson({
        'active_id': 'project-1',
        'projects': [
          {
            'id': 'project-1',
            'label': 'Hermes Console',
            'path': '/workspace/hermes',
            'sessionCount': 2,
            'previewSessions': [
              {
                'id': 'chat-1',
                'title': 'Theme work',
                'preview': 'Build studio',
                'last_active': 12,
              },
            ],
            'repos': [
              {
                'id': 'repo-1',
                'label': 'hermes',
                'path': '/workspace/hermes',
                'sessionCount': 2,
                'groups': [
                  {
                    'id': 'main',
                    'label': 'main',
                    'totalCount': 1,
                    'sessions': [
                      {'id': 'chat-1', 'title': 'Theme work'},
                    ],
                  },
                ],
              },
            ],
          },
        ],
      });

      expect(tree.activeId, 'project-1');
      final project = tree.projects.single;
      expect(project.previewSessions.single.id, 'chat-1');
      expect(
        project.repositories.single.lanes.single.sessions.single.id,
        'chat-1',
      );
    });
  });

  group('SessionControlSnapshot', () {
    test('parses loop and heartbeat timing without retaining prompts', () {
      final control = SessionControlSnapshot.fromJson({
        'revision': 'rev-4',
        'updated_at': 1720000400,
        'loop': {
          'prompt': 'PRIVATE LOOP PROMPT',
          'status': 'active',
          'interval_seconds': 300,
          'last_fired_at': 1720000000,
          'next_due_at': 1720000300,
          'ticks_fired': 2,
          'awaiting_response': true,
          'deferred_by_goal': true,
        },
        'heartbeat': {
          'prompt': 'PRIVATE HEARTBEAT PROMPT',
          'status': 'active',
          'interval_seconds': 60,
          'last_fired_at': 1720000100,
          'fire_count': 7,
        },
      });

      expect(control.revision, 'rev-4');
      expect(control.loop?.interval, const Duration(minutes: 5));
      expect(control.loop?.ticksFired, 2);
      expect(control.loop?.awaitingResponse, isTrue);
      expect(control.loop?.deferredByGoal, isTrue);
      expect(
        control.loop?.nextDueAt,
        DateTime.fromMillisecondsSinceEpoch(1720000300000, isUtc: true),
      );
      expect(control.heartbeat?.interval, const Duration(minutes: 1));
      expect(control.heartbeat?.fireCount, 7);
      expect(
        control.heartbeat?.nextDueAt,
        DateTime.fromMillisecondsSinceEpoch(1720000160000, isUtc: true),
      );
      expect(control.toString(), isNot(contains('PRIVATE')));
    });
  });

  group('SessionGoalSnapshot', () {
    test('parses an active goal with contract, subgoals and gates', () {
      final goal = SessionGoalSnapshot.tryParse({
        'title': 'Ship 1.2.11',
        'status': 'active',
        'turns_used': 3,
        'max_turns': 20,
        'contract': {
          'outcome': 'PR merged',
          'verification': 'CI green',
          'constraints': 'no breaking changes',
          'boundaries': 'this repo only',
          'stop_when': 'PR merged',
        },
        'subgoals': ['write tests', 'update changelog'],
        'gates': [
          {
            'command': 'flutter analyze --fatal-infos',
            'timeout_seconds': 60,
            'max_retries': 2,
            'attempts': 1,
            'last_exit_code': 0,
          },
        ],
      });
      expect(goal, isNotNull);
      expect(goal!.title, 'Ship 1.2.11');
      expect(goal.isActive, isTrue);
      expect(goal.turnsUsed, 3);
      expect(goal.maxTurns, 20);
      expect(goal.outcome, 'PR merged');
      expect(goal.subgoals, ['write tests', 'update changelog']);
      expect(goal.gates.single.command, 'flutter analyze --fatal-infos');
      expect(goal.gates.single.lastExitCode, 0);
      expect(goal.isBlocked, isFalse);
      expect(goal.displayReason, '');
    });

    test('a cleared goal parses to null', () {
      expect(
        SessionGoalSnapshot.tryParse({'status': 'cleared'}),
        isNull,
      );
      expect(SessionGoalSnapshot.tryParse(null), isNull);
      expect(SessionGoalSnapshot.tryParse('not a map'), isNull);
    });

    test('wait_barrier.reason wins over paused_reason and last_reason', () {
      final goal = SessionGoalSnapshot.tryParse({
        'status': 'waiting',
        'paused_reason': 'paused reason',
        'last_reason': 'last reason',
        'wait_barrier': {
          'type': 'until',
          'until_at': '2026-09-15T00:00:00Z',
          'reason': 'barrier reason',
        },
      });
      expect(goal!.displayReason, 'barrier reason');
      expect(goal.isWaiting, isTrue);
    });

    test('paused_reason wins over last_reason when there is no wait_barrier', () {
      final goal = SessionGoalSnapshot.tryParse({
        'status': 'paused',
        'paused_reason': 'paused reason',
        'last_reason': 'last reason',
      });
      expect(goal!.displayReason, 'paused reason');
      expect(goal.isPaused, isTrue);
    });

    test('last_verdict blocked is independent of status', () {
      final goal = SessionGoalSnapshot.tryParse({
        'status': 'active',
        'last_verdict': 'blocked',
        'last_reason': 'flaky test',
      });
      expect(goal!.isActive, isTrue);
      expect(goal.isBlocked, isTrue);
      expect(goal.displayReason, 'flaky test');
    });
  });
}
