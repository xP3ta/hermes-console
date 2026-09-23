import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/rpc_frame_helpers.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-subagent-controls',
      );
}

TuiGatewayClient _clientFor(HttpServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'conn-subagent-controls',
    label: 'Subagent controls',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'secret',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _TicketDashboardClient(),
);

Future<HttpServer> _server(
  Map<String, dynamic> Function(Map<String, dynamic>) respond,
  List<Map<String, dynamic>> requests,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
      if (isClientCapabilitiesFrame(frame)) {
        socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
        continue;
      }
      requests.add(frame);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': frame['id'],
          'result': respond(frame),
        }),
      );
    }
  });
  return server;
}

void main() {
  test(
    'fixture del handler real conserva las formas exactas del productor',
    () {
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/subagent_real_handler_contract.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final list = fixture['list'] as Map<String, dynamic>;
      expect(list.keys.toList(), ['subagents', 'delegations']);
      final row = DesktopSubagentSnapshot.tryParse(
        (list['subagents'] as List).single,
      );
      expect(row?.subagentId, 'child-live');
      expect(row?.depth, 2);
      expect(row?.startedAt?.microsecondsSinceEpoch, 1789034400250000);
      final tail = DesktopSubagentTailResult.fromJson(
        fixture['tail'] as Map<String, dynamic>,
      );
      expect(tail.content, 'producer tail');
      final queued = DesktopSubagentSteerResult.fromJson(
        fixture['steer_queued'] as Map<String, dynamic>,
        requestedSubagentId: 'child-live',
      );
      final rejected = DesktopSubagentSteerResult.fromJson(
        fixture['steer_rejected'] as Map<String, dynamic>,
        requestedSubagentId: 'child-live',
      );
      expect(queued.queued, isTrue);
      expect(rejected.queued, isFalse);
    },
  );

  test(
    'list normaliza allowlist, descarta terminales y extras privados',
    () async {
      final requests = <Map<String, dynamic>>[];
      final server = await _server(
        (_) => {
          'subagents': [
            {
              'subagent_id': 'child-live',
              'parent_id': 'parent-agent',
              'depth': 2,
              'goal': 'Auditar contrato',
              'delegation_id': 'deleg-live',
              'model': 'hermes-3',
              'started_at': 1789034400.25,
              'status': 'running',
              'tool_count': 2,
              'last_tool': 'terminal',
              'accepting_steer': true,
              'live_transcripts': '/private/session.jsonl',
              'raw': {'prompt': 'PRIVATE'},
            },
            {'subagent_id': 'child-done', 'status': 'completed'},
            {'subagent_id': '', 'status': 'running'},
          ],
        },
        requests,
      );
      addTearDown(server.close);
      final client = _clientFor(server);
      addTearDown(client.close);

      final rows = await client.listSubagents('runtime-parent');

      expect(requests.single['method'], 'subagent.list');
      expect(requests.single['params'], {'session_id': 'runtime-parent'});
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row.subagentId, 'child-live');
      expect(row.parentId, 'parent-agent');
      expect(row.depth, 2);
      expect(row.goal, 'Auditar contrato');
      expect(row.delegationId, 'deleg-live');
      expect(row.model, 'hermes-3');
      expect(row.startedAt?.microsecondsSinceEpoch, 1789034400250000);
      expect(row.status, 'running');
      expect(row.toolCount, 2);
      expect(row.lastTool, 'terminal');
      expect(row.acceptingSteer, isTrue);
      expect(row.toString(), isNot(contains('PRIVATE')));
      expect(row.toString(), isNot(contains('session.jsonl')));
    },
  );

  test('tail limita localmente a 16384 y marca truncación', () async {
    final requests = <Map<String, dynamic>>[];
    final server = await _server(
      (_) => {
        'subagent_id': 'child-live',
        'available': true,
        'text': '${'a' * 616}${'b' * 16384}',
        'truncated': false,
      },
      requests,
    );
    addTearDown(server.close);
    final client = _clientFor(server);
    addTearDown(client.close);

    final tail = await client.tailSubagent('runtime-parent', 'child-live');

    expect(requests.single['method'], 'subagent.tail');
    expect(requests.single['params'], {
      'session_id': 'runtime-parent',
      'subagent_id': 'child-live',
    });
    expect(tail.available, isTrue);
    expect(tail.content.length, 16384);
    expect(tail.content, 'b' * 16384);
    expect(tail.truncated, isTrue);
    expect(tail.toString(), isNot(contains('session.jsonl')));
  });

  test('tail unavailable no conserva contenido', () async {
    final requests = <Map<String, dynamic>>[];
    final server = await _server(
      (_) => {
        'subagent_id': 'child-live',
        'available': false,
        'text': 'PRIVATE',
        'truncated': false,
      },
      requests,
    );
    addTearDown(server.close);
    final client = _clientFor(server);
    addTearDown(client.close);

    final tail = await client.tailSubagent('runtime-parent', 'child-live');

    expect(tail.available, isFalse);
    expect(tail.content, isEmpty);
    expect(tail.truncated, isFalse);
  });

  test('tail acepta content solo como alias legacy explícito', () async {
    final requests = <Map<String, dynamic>>[];
    final server = await _server(
      (_) => {
        'subagent_id': 'child-live',
        'available': true,
        'content': 'legacy tail',
        'truncated': false,
      },
      requests,
    );
    addTearDown(server.close);
    final client = _clientFor(server);
    addTearDown(client.close);

    final tail = await client.tailSubagent('runtime-parent', 'child-live');

    expect(tail.content, 'legacy tail');
    expect(requests.single['method'], 'subagent.tail');
  });

  test(
    'approval.respond validates first-wins result and exact payload',
    () async {
      final requests = <Map<String, dynamic>>[];
      final server = await _server((_) => {'resolved': 0}, requests);
      addTearDown(server.close);
      final client = _clientFor(server);
      addTearDown(client.close);

      final result = await client.resolveApprovalChecked(
        'runtime-parent',
        'deny',
        requestId: 'approval-restored',
      );

      expect(result.resolved, 0);
      expect(requests.single['method'], 'approval.respond');
      expect(requests.single['params'], {
        'session_id': 'runtime-parent',
        'choice': 'deny',
        'request_id': 'approval-restored',
      });
    },
  );

  test('approval.respond rejects ambiguous result', () async {
    final requests = <Map<String, dynamic>>[];
    final server = await _server((_) => {'ok': true}, requests);
    addTearDown(server.close);
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.resolveApprovalChecked(
        'runtime-parent',
        'once',
        requestId: 'approval-restored',
      ),
      throwsA(isA<TuiGatewayRpcError>()),
    );
  });

  test('steer ambiguo falla cerrado sin inventar entrega', () async {
    final requests = <Map<String, dynamic>>[];
    final server = await _server(
      (_) => {
        'accepted': true,
        'status': 'accepted',
        'subagent_id': 'child-live',
      },
      requests,
    );
    addTearDown(server.close);
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.steerSubagent(
        'runtime-parent',
        'child-live',
        'conservar borrador',
      ),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(requests.single['params'], {
      'session_id': 'runtime-parent',
      'subagent_id': 'child-live',
      'text': 'conservar borrador',
    });
  });

  test('controles rechazan identidades vacías antes de transportar', () async {
    final requests = <Map<String, dynamic>>[];
    final server = await _server((_) => <String, dynamic>{}, requests);
    addTearDown(server.close);
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.listSubagents(''),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.tailSubagent('runtime-parent', ' '),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.steerSubagent('runtime-parent', '', 'texto'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.interruptSubagent('runtime-parent', '\n'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(requests, isEmpty);
  });

  test(
    'steer decodifica exactamente queued y rejected del productor',
    () async {
      final requests = <Map<String, dynamic>>[];
      var response = 0;
      final server = await _server((frame) {
        response += 1;
        return {
          'status': response == 1 ? 'queued' : 'rejected',
          'subagent_id': 'child-live',
          'text': response == 1 ? 'primero' : 'segundo',
        };
      }, requests);
      addTearDown(server.close);
      final client = _clientFor(server);
      addTearDown(client.close);

      final queued = await client.steerSubagent(
        'runtime-parent',
        'child-live',
        'primero',
      );
      final rejected = await client.steerSubagent(
        'runtime-parent',
        'child-live',
        'segundo',
      );

      expect(queued.status, 'queued');
      expect(queued.queued, isTrue);
      expect(queued.text, 'primero');
      expect(rejected.status, 'rejected');
      expect(rejected.queued, isFalse);
      expect(rejected.text, 'segundo');
      expect(
        requests.map((row) => row['method']),
        everyElement('subagent.steer'),
      );
      expect(requests.first['params'], {
        'session_id': 'runtime-parent',
        'subagent_id': 'child-live',
        'text': 'primero',
      });
      expect(requests.last['params'], {
        'session_id': 'runtime-parent',
        'subagent_id': 'child-live',
        'text': 'segundo',
      });
    },
  );
}
