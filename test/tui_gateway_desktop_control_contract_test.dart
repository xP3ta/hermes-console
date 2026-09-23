import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _ControlTicketDashboard extends DashboardClient {
  _ControlTicketDashboard()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-control-contract',
      );
}

TuiGatewayClient _clientFor(HttpServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'desktop-control-contract',
    label: 'Desktop control contract',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'test-only',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _ControlTicketDashboard(),
);

final class _InMemoryControlChannel implements WebSocketChannel {
  _InMemoryControlChannel(this.onRequest) {
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  final void Function(Map<String, dynamic>) onRequest;
  final StreamController<dynamic> _incoming = StreamController<dynamic>();

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _InMemoryControlSink((data) {
    final frame = Map<String, dynamic>.from(
      jsonDecode(data as String) as Map,
    );
    onRequest(frame);
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': frame['id'],
        'result': <String, dynamic>{},
      }),
    );
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _InMemoryControlSink implements WebSocketSink {
  _InMemoryControlSink(this.onAdd);

  final void Function(dynamic) onAdd;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) => onAdd(data);

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('process.stop stays scoped on a shared client', () async {
    final requests = <Map<String, dynamic>>[];
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'process-stop-scope',
        label: 'Process stop scope',
        host: 'hermes.local',
        port: 8642,
        apiKey: 'test-only',
      ),
      dashboard: _ControlTicketDashboard(),
      channelFactory: (_, _) => _InMemoryControlChannel(requests.add),
    );
    addTearDown(client.close);

    await client.stopBackgroundProcesses('runtime-session-a');
    await client.stopBackgroundProcesses('runtime-session-b');

    final stopRequests = requests
        .where((request) => request['method'] == 'process.stop')
        .toList(growable: false);
    expect(stopRequests.map((request) => request['params']), [
      {'session_id': 'runtime-session-a'},
      {'session_id': 'runtime-session-b'},
    ]);
  });

  test(
    'usa los RPC nativos de Recovery, Extensions, Agents y Projects',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
          }),
        );
        await for (final raw in socket) {
          final frame = Map<String, dynamic>.from(
            jsonDecode(raw as String) as Map,
          );
          requests.add(frame);
          final params = Map<String, dynamic>.from(frame['params'] as Map);
          final result = switch (frame['method']) {
            'rollback.list' => {
              'enabled': true,
              'checkpoints': [
                {
                  'hash': 'checkpoint-a',
                  'timestamp': '2026-07-22T12:00:00Z',
                  'message': 'Before change',
                },
              ],
            },
            'rollback.diff' => {'stat': '1 file', 'diff': '+safe'},
            'rollback.restore' => {'success': true, 'history_removed': 2},
            'plugins.manage' when params['action'] == 'list' => {
              'plugins': [
                {'name': 'plugin-a', 'version': '1.0.0', 'status': 'enabled'},
              ],
            },
            'plugins.manage' => {
              'ok': true,
              'unchanged': false,
              'name': params['name'],
            },
            'tools.list' => {
              'toolsets': [
                {
                  'name': 'web',
                  'description': 'Web tools',
                  'tool_count': 2,
                  'enabled': true,
                  'tools': ['search', 'fetch'],
                },
              ],
            },
            'tools.configure' => {
              'changed': ['web'],
              'unknown': <Object>[],
            },
            'reload.mcp' => {'status': 'reloaded'},
            'spawn_tree.list' => {
              'entries': [
                {
                  'path': '/opaque/spawn-tree.json',
                  'session_id': 'runtime-a',
                  'label': 'Audit',
                  'count': 1,
                },
              ],
            },
            'process.list' => {
              'processes': [
                {
                  'session_id': 'process-a',
                  'command': 'flutter test',
                  'status': 'running',
                },
              ],
            },
            'spawn_tree.load' => {
              'session_id': 'runtime-a',
              'label': 'Audit',
              'subagents': [
                {'id': 'agent-a', 'status': 'completed'},
              ],
            },
            'prompt.background' => {'task_id': 'bg-a'},
            'process.kill' => {'killed': true},
            'session.control.read' => {
              'control': {
                'loop': {
                  'status': 'active',
                  'interval_seconds': 300,
                  'ticks_fired': 2,
                },
                'heartbeat': {
                  'status': 'paused',
                  'interval_seconds': 600,
                  'fire_count': 4,
                },
                'revision': 'control-a',
              },
            },
            'session.control' => {'accepted': true},
            'projects.tree' => {
              'active_id': 'project-a',
              'projects': [
                {
                  'id': 'project-a',
                  'label': 'Hermes Console',
                  'sessionCount': 1,
                  'repos': <Object>[],
                },
              ],
            },
            'projects.project_sessions' => {
              'project': {
                'id': 'project-a',
                'label': 'Hermes Console',
                'sessionCount': 1,
                'repos': <Object>[],
              },
            },
            'session.cwd.set' => {'cwd': '/srv/hermes', 'branch': 'main'},
            _ => <String, dynamic>{},
          };
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        }
      });
      final client = _clientFor(server);
      addTearDown(client.close);

      final timeline = await client.listRecovery('runtime-a');
      final diff = await client.diffRecovery('runtime-a', 'checkpoint-a');
      final restore = await client.restoreRecovery('runtime-a', 'checkpoint-a');
      final inventory = await client.extensionsInventory(
        runtimeSessionId: 'runtime-a',
      );
      await client.setPluginEnabled('plugin-a', false);
      await client.setToolsetEnabled(
        'web',
        false,
        runtimeSessionId: 'runtime-a',
      );
      await client.reloadMcp(runtimeSessionId: 'runtime-a', confirmed: true);
      final agents = await client.agentCenterSnapshot(
        runtimeSessionId: 'runtime-a',
      );
      final tree = await client.loadSpawnTree('/opaque/spawn-tree.json');
      final taskId = await client.startBackgroundTask('runtime-a', 'Audit UI');
      await client.killBackgroundProcess('runtime-a', 'process-a');
      final control = await client.readSessionControl('runtime-a');
      await client.sendSessionControlAction('runtime-a', 'heartbeat.pause');
      await expectLater(
        client.sendSessionControlAction('runtime-a', 'loop.delete'),
        throwsArgumentError,
      );
      final projects = await client.projectTree();
      final project = await client.projectSessions('project-a');
      await client.setSessionWorkingDirectory('runtime-a', '/srv/hermes');

      expect(timeline.checkpoints.single.hash, 'checkpoint-a');
      expect(diff.diff, '+safe');
      expect(restore.historyRemoved, 2);
      expect(inventory.plugins.single.name, 'plugin-a');
      expect(inventory.toolsets.single.name, 'web');
      expect(agents.snapshots.single.count, 1);
      expect(agents.processes.single.opaqueId, 'process-a');
      expect(agents.processes.single.status.name, 'running');
      expect(tree.subagents.single.status.name, 'completed');
      expect(taskId, 'bg-a');
      expect(control.loop?.ticksFired, 2);
      expect(control.heartbeat?.fireCount, 4);
      expect(projects.activeId, 'project-a');
      expect(project?.label, 'Hermes Console');

      Map<String, dynamic> paramsFor(
        String method, {
        bool Function(Map<String, dynamic>)? where,
      }) => Map<String, dynamic>.from(
        requests.firstWhere((request) {
              if (request['method'] != method) return false;
              final params = Map<String, dynamic>.from(
                request['params'] as Map,
              );
              return where?.call(params) ?? true;
            })['params']
            as Map,
      );

      expect(paramsFor('rollback.list'), {'session_id': 'runtime-a'});
      expect(paramsFor('rollback.diff'), {
        'session_id': 'runtime-a',
        'hash': 'checkpoint-a',
      });
      expect(
        paramsFor(
          'plugins.manage',
          where: (params) => params['action'] == 'toggle',
        ),
        {'action': 'toggle', 'name': 'plugin-a', 'enable': false},
      );
      expect(paramsFor('tools.configure'), {
        'action': 'disable',
        'names': ['web'],
        'session_id': 'runtime-a',
      });
      expect(paramsFor('reload.mcp'), {
        'confirm': true,
        'session_id': 'runtime-a',
      });
      expect(paramsFor('spawn_tree.list'), {
        'session_id': 'runtime-a',
        'cross_session': false,
        'limit': 50,
      });
      expect(paramsFor('process.kill'), {
        'session_id': 'runtime-a',
        'process_id': 'process-a',
      });
      expect(paramsFor('session.control.read'), {'session_id': 'runtime-a'});
      expect(paramsFor('session.control'), {
        'session_id': 'runtime-a',
        'action': 'heartbeat.pause',
      });
      expect(paramsFor('projects.tree'), {'preview_limit': 3});
      expect(paramsFor('projects.project_sessions'), {
        'project_id': 'project-a',
      });
      expect(paramsFor('session.cwd.set'), {
        'session_id': 'runtime-a',
        'cwd': '/srv/hermes',
      });
    },
  );

  test(
    'method-not-found se convierte en unsupported sin filtrar mensaje',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'error': {
                'code': -32601,
                'message': 'unknown method with /private/path and token-secret',
              },
            }),
          );
        }
      });
      final client = _clientFor(server);
      addTearDown(client.close);

      Object? failure;
      try {
        await client.projectTree();
      } catch (error) {
        failure = error;
      }

      expect(failure, isA<DesktopControlFailure>());
      final typed = failure! as DesktopControlFailure;
      expect(typed.kind, DesktopControlFailureKind.unsupported);
      expect(typed.code, -32601);
      expect('$failure', isNot(contains('private')));
      expect('$failure', isNot(contains('token-secret')));
    },
  );

  test('reload MCP sin confirmación no abre socket ni ejecuta RPC', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var connections = 0;
    server.listen((request) async {
      connections++;
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
        }),
      );
      await socket.close();
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.reloadMcp(confirmed: false),
      throwsA(
        isA<DesktopControlFailure>().having(
          (error) => error.kind,
          'kind',
          DesktopControlFailureKind.rejected,
        ),
      ),
    );
    expect(connections, 0);
  });
}
