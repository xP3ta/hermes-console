import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/rpc_frame_helpers.dart';

/// N10c: a turn the user starts is a turn boundary. The quarantine left by an
/// earlier cut (here: a sequence gap) must not withhold the new turn's frames.
/// Queued prompts and rejected corrections start no turn and keep it.

SavedConnection _conn(String id, int port) => SavedConnection(
  id: id,
  label: id,
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  dashboardUrl: 'http://127.0.0.1:$port',
);

final class _Ticket extends DashboardClient {
  _Ticket() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-qa',
      );
}

Map<String, dynamic> _event(int seq, String text) => {
  'jsonrpc': '2.0',
  'method': 'event',
  'params': {
    'type': 'reasoning.delta',
    'session_id': 'runtime-1',
    'seq': seq,
    'payload': {'text': text},
  },
};

/// Fake v7 gateway. After `session.resume` it sends seq 1 and then seq 3 (a
/// gap: the runtime is quarantined). Every reply to a turn-start method is
/// followed by the frames in [afterTurnStart].
Future<({HttpServer server, List<String> methods})> _gateway({
  required List<Map<String, dynamic>> afterTurnStart,
  String redirectStatus = 'redirected',
  String submitStatus = 'streaming',
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final methods = <String>[];
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'gateway.ready',
          'payload': {'replay_epoch': 'epoch-1'},
        },
      }),
    );
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      if (isClientCapabilitiesFrame(frame)) {
        socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
        continue;
      }
      final method = frame['method'] as String;
      methods.add(method);
      final result = switch (method) {
        'gateway.capabilities' => {'per_session_exclusive_submit': true},
        'session.resume' => {'session_id': 'runtime-1'},
        'session.redirect' => {'status': redirectStatus},
        'prompt.submit' => {'status': submitStatus},
        _ => <String, dynamic>{'status': 'ok'},
      };
      socket.add(
        jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
      );
      if (method == 'session.resume') {
        socket.add(jsonEncode(_event(1, 'one')));
        socket.add(jsonEncode(_event(3, 'gap')));
      } else if (method == 'prompt.submit' || method == 'session.redirect') {
        for (final event in afterTurnStart) {
          socket.add(jsonEncode(event));
        }
      }
    }
  });
  return (server: server, methods: methods);
}

Future<(TuiGatewayClient, List<String>)> _open(HttpServer server) async {
  final client = TuiGatewayClient(
    _conn('conn-n10c', server.port),
    dashboard: _Ticket(),
  );
  addTearDown(client.close);
  final texts = <String>[];
  final sub = client.events
      .where((event) => event.type == 'reasoning.delta')
      .listen((event) => texts.add(event.payload['text'] as String));
  addTearDown(sub.cancel);
  await client.connect();
  await client.resumeSession('stored-1');
  await Future<void>.delayed(const Duration(milliseconds: 200));
  return (client, texts);
}

void main() {
  test('a prompt.submit after a cut streams the new turn again', () async {
    final g = await _gateway(
      afterTurnStart: [_event(4, 'new-a'), _event(5, 'new-b')],
    );
    addTearDown(g.server.close);
    final (client, texts) = await _open(g.server);
    expect(texts, ['one'], reason: 'the gap withheld seq 3');

    await client.submitPrompt('runtime-1', 'next');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(texts, ['one', 'new-a', 'new-b']);
  });

  test('a queued prompt starts no turn: the quarantine stays', () async {
    final g = await _gateway(afterTurnStart: [_event(4, 'old-turn')]);
    addTearDown(g.server.close);
    final (client, texts) = await _open(g.server);

    await client.submitQueuedPrompt('runtime-1', 'later');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(texts, ['one']);
  });

  test('a rejected redirect starts no turn: the quarantine stays', () async {
    final g = await _gateway(
      afterTurnStart: [_event(4, 'old-turn')],
      redirectStatus: 'rejected',
    );
    addTearDown(g.server.close);
    final (client, texts) = await _open(g.server);

    final disposition = await client.redirect('runtime-1', 'no');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(disposition, DesktopRedirectDisposition.rejected);
    expect(texts, ['one']);
  });

  for (final status in ['redirected', 'steered', 'queued']) {
    test(
      'a busy prompt.submit answered "$status" keeps the quarantine',
      () async {
        final g = await _gateway(
          afterTurnStart: [_event(4, 'same-turn')],
          submitStatus: status,
        );
        addTearDown(g.server.close);
        final (client, texts) = await _open(g.server);

        await client.submitPrompt('runtime-1', 'next');
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(texts, ['one']);
      },
    );
  }
}
