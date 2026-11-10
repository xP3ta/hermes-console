import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';
import 'package:hermes_android/core/models/desktop_compression_outcome.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/compression_dispatcher.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/rpc_frame_helpers.dart';

final class _CommandTicketDashboard extends DashboardClient {
  _CommandTicketDashboard()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-commands-047',
      );
}

TuiGatewayClient _clientFor(HttpServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'conn-commands-047',
    label: 'Commands contract',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'gateway-key',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _CommandTicketDashboard(),
);

/// A long `/goal` as the owner pasted it: past the old limits (500 in the
/// chat, 4096 in the client), several lines, quotes, accents and emoji.
final String _longGoal = [
  'Objetivo: «revisar» la app — "comillas", \'simples\', áéíóú ñ, 🚀👩🏽‍💻',
  for (var i = 0; i < 80; i++) 'Línea $i: ${'palabra ' * 8}fin.',
].join('\n');

void main() {
  test('usa los cuatro JSON-RPC Desktop con parámetros exactos', () async {
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
        if (isClientCapabilitiesFrame(frame)) {
          socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
          continue;
        }
        requests.add(frame);
        final result = switch (frame['method']) {
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
          'commands.catalog' => {
            'categories': [
              {
                'name': 'Session',
                'pairs': [
                  ['/compress', 'Compress context'],
                ],
              },
            ],
            'pairs': [
              ['/compress', 'Compress context'],
              ['/usage', 'Show usage'],
            ],
            'canon': {'/summarize': '/compress'},
          },
          'complete.slash' => {
            'replace_from': 1,
            'items': [
              {
                'text': 'compress',
                'display': '/compress',
                'meta': 'Compress context',
              },
            ],
          },
          'slash.exec' => {
            'output': 'Synthetic slash accepted',
            'headers': {'authorization': 'must-not-survive'},
          },
          'command.dispatch' => {
            'type': 'exec',
            'output': 'Synthetic dispatch accepted',
          },
          _ => <String, dynamic>{},
        };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    final catalog = await client.commandsCatalog();
    final completion = await client.completeSlash('/com');
    final slash = await client.slashExec(
      'runtime-synthetic-047',
      '/Compress release decisions',
    );
    final dispatch = await client.commandDispatch(
      'runtime-synthetic-047',
      name: '/COMPRESS',
      arg: '  release decisions  ',
    );

    expect(requests.map((request) => request['method']), [
      'commands.catalog',
      'complete.slash',
      'gateway.capabilities',
      'slash.exec',
      'command.dispatch',
    ]);
    expect(requests[0]['params'], <String, dynamic>{});
    expect(requests[1]['params'], {'text': '/com'});
    expect(requests[2]['params'], <String, dynamic>{});
    expect(requests[3]['params'], {
      'session_id': 'runtime-synthetic-047',
      'command': 'compress release decisions',
    });
    expect(requests[4]['params'], {
      'session_id': 'runtime-synthetic-047',
      'name': 'compress',
      'arg': 'release decisions',
    });
    expect(catalog.commands, hasLength(2));
    expect(catalog.commands.first.aliases, contains('summarize'));
    expect(completion.suggestions.single.replaceFrom, 1);
    expect(slash.kind, DesktopCommandDispatchKind.output);
    expect(slash.output, 'Synthetic slash accepted');
    expect(dispatch.kind, DesktopCommandDispatchKind.output);
  });

  test(
    'completion conserva trailing space y descarta replace_from inválido',
    () {
      final batch = SlashCompletionBatch.fromJson({
        'items': [
          {'value': 'valid', 'replace_from': 5},
          {'value': 'invalid', 'replace_from': 500},
        ],
      }, input: '/cmd ');

      expect(batch.input, '/cmd ');
      expect(batch.suggestions.single.replacement, 'valid');
      expect(batch.partial, isTrue);
    },
  );

  test('completion queda limitada a 50 suggestions', () {
    final batch = SlashCompletionBatch.fromJson({
      'replace_from': 1,
      'items': List.generate(60, (index) => {'text': 'cmd$index'}),
    }, input: '/c');

    expect(batch.suggestions, hasLength(50));
    expect(batch.partial, isTrue);
  });

  test('REGRESSION_COMP_TYPED_LEGACY_PENDING preserves wire status', () async {
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
        if (frame['method'] == 'session.compress') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'error': {'code': -32601, 'message': 'missing'},
            }),
          );
        } else {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': frame['method'] == 'gateway.capabilities'
                  ? {'per_session_exclusive_submit': true}
                  : {'type': 'exec', 'status': 'pending', 'output': 'ignored'},
            }),
          );
        }
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);
    final result = await CompressionDispatcher(client).dispatch(
      'runtime-pending-047',
      focusTopic: '',
      connectionEpoch: 1,
      sessionEpoch: 1,
      stillValid: () => true,
      matchesRoot: (_) => true,
    );
    expect(result.evidence.outcome, DesktopCompressionOutcome.acceptedPending);
  });

  test('a long, multiline command travels whole, and so does its '
      'prompt', () async {
    // ORDEN-COMANDOS: neither Hermes nor Desktop limit the argument; the
    // kickoff prompt the server sends back is never cut either.
    expect(_longGoal.length, greaterThan(4096));
    expect(_longGoal, contains('\n'));
    final kickoff = List<String>.filled(2000, 'kickoff ').join() + _longGoal;
    expect(kickoff.length, greaterThan(8000));
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
        if (isClientCapabilitiesFrame(frame)) {
          socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
          continue;
        }
        requests.add(frame);
        final result = switch (frame['method']) {
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
          'slash.exec' || 'command.dispatch' => {
            'type': 'send',
            'notice': '⊙ Goal set (20-turn budget)',
            'message': kickoff,
          },
          _ => <String, dynamic>{},
        };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    final slash = await client.slashExec('runtime-goal', '/goal $_longGoal');
    final dispatch = await client.commandDispatch(
      'runtime-goal',
      name: 'goal',
      arg: _longGoal,
    );

    final sent = requests.where(
      (request) => request['method'] != 'gateway.capabilities',
    );
    expect(sent.map((request) => request['method']), [
      'slash.exec',
      'command.dispatch',
    ]);
    expect(sent.first['params'], {
      'session_id': 'runtime-goal',
      'command': 'goal $_longGoal',
    });
    expect(sent.last['params'], {
      'session_id': 'runtime-goal',
      'name': 'goal',
      'arg': _longGoal,
    });
    for (final result in [slash, dispatch]) {
      expect(result.kind, DesktopCommandDispatchKind.send);
      expect(result.message, kickoff);
      expect(result.notice, '⊙ Goal set (20-turn budget)');
    }

    // Past the safety bound (64 Ki units) nothing is sent at all.
    final tooLong = 'x' * (commandArgumentMaxLength + 1);
    await expectLater(
      client.slashExec('runtime-goal', '/goal $tooLong'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.commandDispatch('runtime-goal', name: 'goal', arg: tooLong),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    // The bound itself still goes (checked above with the 4096+ goal);
    // what was refused before still is: a control character, an empty
    // command, a name that is not a command name.
    await expectLater(
      client.slashExec('runtime-goal', '/goal a\u0007b'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    for (final invalid in ['', '   ', '/', '/go;al x', '/${'n' * 65} x']) {
      await expectLater(
        client.slashExec('runtime-goal', invalid),
        throwsA(isA<TuiGatewayRpcError>()),
        reason: invalid,
      );
    }
    await expectLater(
      client.commandDispatch('runtime-goal', name: 'go;al', arg: 'x'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.commandDispatch('runtime-goal', name: 'goal', arg: 'a\u0007b'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(
      requests.where((request) => request['method'] != 'gateway.capabilities'),
      hasLength(2),
    );
  });
}
