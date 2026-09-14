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
}
