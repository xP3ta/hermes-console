import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

/// N10h-1: a contiguous, same-epoch, non-truncated `session.events.since`
/// answer is the way back to the live stream (Hermes Desktop,
/// apps/shared/src/json-rpc-gateway.ts flushReplayHold). Anything else keeps
/// the quarantine and REST resync.

final class _Ticket extends DashboardClient {
  _Ticket() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-qa',
      );
}

Map<String, dynamic> _frame(int seq, String text) => {
  'jsonrpc': '2.0',
  'method': 'event',
  'params': {
    'type': 'message.delta',
    'session_id': 'runtime-1',
    'seq': seq,
    'payload': {'text': text},
  },
};

Map<String, dynamic> _row(int seq, String text) => {
  'type': 'message.delta',
  'session_id': 'runtime-1',
  'seq': seq,
  'payload': {'text': text},
};

/// First socket: seq 1..4, then a cut. Second socket: `session.events.since`
/// answers with [replay] and the shape [truncated]/[epoch]/[latest], then a
/// live seq latest+1 follows.
Future<
  ({TuiGatewayClient client, List<int> seqs, Map<String, int> Function() marks})
>
_run({
  required List<Map<String, dynamic>> replay,
  bool truncated = false,
  String epoch = 'epoch-a',
  int latest = 7,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  var connections = 0;
  final firstDelivered = Completer<void>();
  final secondLive = Completer<void>();
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'gateway.ready',
          'payload': {'replay_epoch': 'epoch-a'},
        },
      }),
    );
    connections++;
    if (connections == 1) {
      for (var seq = 1; seq <= 4; seq++) {
        socket.add(jsonEncode(_frame(seq, 'd$seq')));
      }
      await firstDelivered.future.timeout(const Duration(seconds: 2));
      await socket.close();
      return;
    }
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      if (frame['method'] != 'session.events.since') continue;
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': frame['id'],
          'result': {
            'epoch': epoch,
            'truncated': truncated,
            'events': replay,
            'count': replay.length,
            'latest_seq': latest,
          },
        }),
      );
      socket.add(jsonEncode(_frame(latest + 1, 'live')));
      if (!secondLive.isCompleted) secondLive.complete();
    }
  });

  final client = TuiGatewayClient(
    SavedConnection(
      id: 'conn-n10h',
      label: 'n10h',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'unused',
      dashboardUrl: 'http://127.0.0.1:${server.port}',
    ),
    dashboard: _Ticket(),
  );
  addTearDown(client.close);
  final seqs = <int>[];
  final disconnected = Completer<void>();
  final sub = client.events.listen(
    (event) {
      if (event.sessionId != 'runtime-1') return;
      seqs.add(event.sequence!);
      if (seqs.length == 4 && !firstDelivered.isCompleted) {
        firstDelivered.complete();
      }
    },
    onError: (Object _, StackTrace _) {
      if (!disconnected.isCompleted) disconnected.complete();
    },
  );
  addTearDown(sub.cancel);
  await client.connect();
  await disconnected.future.timeout(const Duration(seconds: 3));
  await client.connect();
  await secondLive.future.timeout(const Duration(seconds: 3));
  await Future<void>.delayed(const Duration(milliseconds: 300));
  return (
    client: client,
    seqs: seqs,
    marks: () => client.replayWatermarksForTesting,
  );
}

void main() {
  test('a contiguous replay is projected once, in order, and the live '
      'stream continues unquarantined', () async {
    final r = await _run(replay: [_row(5, 'd5'), _row(6, 'd6'), _row(7, 'd7')]);
    expect(r.seqs, [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(r.marks()['runtime-1'], 8, reason: 'not quarantined: watermark set');
  });

  test('an empty contiguous replay resumes the live stream', () async {
    final r = await _run(replay: const [], latest: 4);
    expect(r.seqs, [1, 2, 3, 4, 5]);
    expect(r.marks()['runtime-1'], 5);
  });

  group('anything not proven contiguous keeps the quarantine', () {
    final controls = <String, Future<dynamic> Function()>{
      'truncated': () =>
          _run(replay: [_row(5, 'd5')], truncated: true, latest: 5),
      'other epoch': () =>
          _run(replay: [_row(5, 'd5')], epoch: 'epoch-b', latest: 5),
      'gap 5,7': () => _run(replay: [_row(5, 'd5'), _row(7, 'd7')]),
      'gap 5,7 with a matching latest_seq': () =>
          _run(replay: [_row(5, 'd5'), _row(7, 'd7')], latest: 6),
    };
    for (final entry in controls.entries) {
      test(entry.key, () async {
        final r = await entry.value();
        expect(r.seqs, [1, 2, 3, 4], reason: 'nothing replayed or live');
        expect(r.marks().containsKey('runtime-1'), isFalse);
      });
    }
  });
}
