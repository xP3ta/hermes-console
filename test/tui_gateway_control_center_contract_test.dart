import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

final class _ControlTicketDashboard extends DashboardClient {
  _ControlTicketDashboard()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-control-047',
      );
}

TuiGatewayClient _clientFor(HttpServer server, {bool readOnly = false}) =>
    TuiGatewayClient(
      SavedConnection(
        id: 'conn-control-047',
        label: 'Control contract',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        readOnly: readOnly,
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _ControlTicketDashboard(),
    );

void main() {
  test(
    'uses native rollback and extensions RPCs with exact parameters',
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
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          requests.add(frame);
          final params = Map<String, dynamic>.from(frame['params'] as Map);
          final result = switch (frame['method']) {
            'rollback.list' => {
              'enabled': true,
              'checkpoints': [
                {
                  'hash': 'abcdef123456',
                  'timestamp': '2026-07-22T10:30:00Z',
                  'message': 'Safe point',
                },
              ],
            },
            'rollback.diff' => {
              'stat': '1 file changed',
              'diff': '@@ -1 +1 @@\n-old\n+new',
              'rendered': {'private': 'must not be retained'},
            },
            'rollback.restore' => {'success': true, 'history_removed': 3},
            'plugins.manage' when params['action'] == 'list' => {
              'plugins': [
                {
                  'name': 'memory-tools',
                  'version': '1.2.0',
                  'description': 'Memory helpers',
                  'source': 'user',
                  'status': 'enabled',
                },
              ],
            },
            'plugins.manage' => {
              'ok': true,
              'unchanged': false,
              'plugin': {'name': 'memory-tools', 'status': 'disabled'},
            },
            'tools.list' => {
              'toolsets': [
                {
                  'name': 'web',
                  'description': 'Web tools',
                  'tool_count': 2,
                  'enabled': false,
                  'tools': ['search', 'fetch'],
                },
              ],
            },
            'tools.configure' => {
              'changed': ['web'],
              'unknown': <String>[],
              'enabled_toolsets': ['web'],
            },
            'reload.mcp' => {'status': 'reloaded'},
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
      final diff = await client.diffRecovery('runtime-a', 'abcdef123456');
      final restore = await client.restoreRecovery('runtime-a', 'abcdef123456');
      final inventory = await client.extensionsInventory(
        runtimeSessionId: 'runtime-a',
      );
      await client.setPluginEnabled('memory-tools', false);
      await client.setToolsetEnabled(
        'web',
        true,
        runtimeSessionId: 'runtime-a',
      );
      await client.reloadMcp(runtimeSessionId: 'runtime-a', confirmed: true);

      expect(timeline.enabled, isTrue);
      expect(timeline.checkpoints.single.hash, 'abcdef123456');
      expect(diff.stat, '1 file changed');
      expect(diff.diff, contains('+new'));
      expect(restore.historyRemoved, 3);
      expect(inventory.plugins.single.name, 'memory-tools');
      expect(inventory.toolsets.single.tools, ['search', 'fetch']);
      expect(
        client.capabilityState(DesktopGatewayCapability.recoveryCenter),
        DesktopGatewayCapabilityState.supported,
      );
      expect(
        client.capabilityState(DesktopGatewayCapability.extensionsCenter),
        DesktopGatewayCapabilityState.supported,
      );

      Map<String, dynamic> requestFor(String method, {String? action}) =>
          requests.singleWhere(
            (request) =>
                request['method'] == method &&
                (action == null ||
                    (request['params'] as Map)['action'] == action),
          );

      expect(requestFor('rollback.list')['params'], {
        'session_id': 'runtime-a',
      });
      expect(requestFor('rollback.diff')['params'], {
        'session_id': 'runtime-a',
        'hash': 'abcdef123456',
      });
      expect(requestFor('rollback.restore')['params'], {
        'session_id': 'runtime-a',
        'hash': 'abcdef123456',
      });
      expect(
        (requestFor('rollback.restore')['params'] as Map).containsKey(
          'file_path',
        ),
        isFalse,
      );
      expect(requestFor('plugins.manage', action: 'list')['params'], {
        'action': 'list',
      });
      expect(requestFor('plugins.manage', action: 'toggle')['params'], {
        'action': 'toggle',
        'name': 'memory-tools',
        'enable': false,
      });
      expect(requestFor('tools.list')['params'], {'session_id': 'runtime-a'});
      expect(requestFor('tools.configure')['params'], {
        'action': 'enable',
        'names': ['web'],
        'session_id': 'runtime-a',
      });
      expect(requestFor('reload.mcp')['params'], {
        'confirm': true,
        'session_id': 'runtime-a',
      });
    },
  );

  test(
    'method-not-found is reported as unsupported, not an empty list',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var requests = 0;
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
          requests++;
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'error': {
                'code': -32601,
                'message': 'method missing at /private/host/server.py',
              },
            }),
          );
        }
      });
      final client = _clientFor(server);
      addTearDown(client.close);

      await expectLater(
        client.listRecovery('runtime-a'),
        throwsA(
          isA<DesktopControlFailure>()
              .having(
                (failure) => failure.kind,
                'kind',
                DesktopControlFailureKind.unsupported,
              )
              .having((failure) => failure.code, 'code', -32601),
        ),
      );
      expect(
        client.capabilityState(DesktopGatewayCapability.recoveryCenter),
        DesktopGatewayCapabilityState.unsupported,
      );
      await expectLater(
        client.listRecovery('runtime-a'),
        throwsA(
          isA<DesktopControlFailure>().having(
            (failure) => failure.kind,
            'kind',
            DesktopControlFailureKind.unsupported,
          ),
        ),
      );
      expect(requests, 1);
    },
  );

  test('reload MCP rejects calls that skipped UI confirmation', () async {
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
        requests.add(jsonDecode(raw as String) as Map<String, dynamic>);
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.reloadMcp(runtimeSessionId: 'runtime-a', confirmed: false),
      throwsA(
        isA<DesktopControlFailure>().having(
          (failure) => failure.kind,
          'kind',
          DesktopControlFailureKind.rejected,
        ),
      ),
    );
    expect(requests, isEmpty);
  });

  test(
    'read-only connection rejects every control-centre mutation locally',
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
          requests.add(jsonDecode(raw as String) as Map<String, dynamic>);
        }
      });
      final client = _clientFor(server, readOnly: true);
      addTearDown(client.close);

      Future<void> expectBlocked(Future<void> Function() action) async {
        await expectLater(
          action(),
          throwsA(
            isA<DesktopControlFailure>().having(
              (failure) => failure.kind,
              'kind',
              DesktopControlFailureKind.forbidden,
            ),
          ),
        );
      }

      await expectBlocked(
        () async => client.restoreRecovery('runtime-a', 'abcdef123456'),
      );
      await expectBlocked(() => client.setPluginEnabled('memory-tools', false));
      await expectBlocked(
        () => client.setToolsetEnabled(
          'web',
          true,
          runtimeSessionId: 'runtime-a',
        ),
      );
      await expectBlocked(
        () => client.reloadMcp(runtimeSessionId: 'runtime-a', confirmed: true),
      );
      await expectBlocked(
        () async => client.startBackgroundTask('runtime-a', 'safe QA task'),
      );
      await expectBlocked(
        () => client.killBackgroundProcess('runtime-a', 'process-a'),
      );
      await expectBlocked(
        () => client.setSessionWorkingDirectory('runtime-a', '/workspace'),
      );

      expect(requests, isEmpty);
      expect(client.isConnected, isFalse);
    },
  );
}
