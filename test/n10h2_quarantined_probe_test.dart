import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

/// N10h-2: a busy runtime whose replay was not provable (quarantined, no
/// watermark) must not poll `session.events.since(0)` and call every answer
/// a gap: that looped GET /messages for the whole live turn. Only a withheld
/// end-of-turn frame triggers the single rehydration.

final class _Ticket extends DashboardClient {
  _Ticket() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-qa',
      );
}

Map<String, dynamic> _event(int seq, String type) => {
  'jsonrpc': '2.0',
  'method': 'event',
  'params': {
    'type': type,
    'session_id': 'runtime-1',
    'seq': seq,
    'payload': {'text': 'x'},
  },
};

void main() {
  late TuiGatewayClient client;
  late WebSocket? Function() secondSocket;
  var sinceRequests = 0;
  var rosterRequests = 0;
  String? rosterStatus;
  var clock = DateTime(2026, 10, 18, 12);
  final rehydrations = <Map?>[];

  Future<void> boot() async {
    sinceRequests = 0;
    rosterRequests = 0;
    rosterStatus = null;
    clock = DateTime(2026, 10, 18, 12);
    rehydrations.clear();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var connections = 0;
    WebSocket? second;
    secondSocket = () => second;
    final firstDelivered = Completer<void>();
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
          socket.add(jsonEncode(_event(seq, 'message.delta')));
        }
        await firstDelivered.future.timeout(const Duration(seconds: 2));
        await socket.close();
        return;
      }
      second = socket;
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] == 'session.active_list') {
          rosterRequests++;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'sessions': [
                  if (rosterStatus != null)
                    {'id': 'runtime-1', 'status': rosterStatus},
                ],
              },
            }),
          );
          continue;
        }
        if (frame['method'] != 'session.events.since') continue;
        sinceRequests++;
        // The first answer is truncated: the runtime is quarantined with no
        // watermark. Later answers (the probe) would look like a full gap.
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'epoch': 'epoch-a',
              'truncated': sinceRequests == 1,
              'events': [
                for (var s = 5; s <= 9; s++)
                  {
                    'type': 'message.delta',
                    'session_id': 'runtime-1',
                    'seq': s,
                    'payload': {'text': 'x'},
                  },
              ],
              'count': 5,
              'latest_seq': 9,
            },
          }),
        );
      }
    });
    client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-n10h2',
        label: 'n10h2',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'unused',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _Ticket(),
      now: () => clock,
    );
    addTearDown(client.close);
    var delivered = 0;
    final disconnected = Completer<void>();
    final sub = client.events.listen(
      (event) {
        if (event.sessionId == 'runtime-1' &&
            ++delivered == 4 &&
            !firstDelivered.isCompleted) {
          firstDelivered.complete();
        }
      },
      onError: (Object error, StackTrace _) {
        if (error is TuiGatewayRpcError) rehydrations.add(error.data);
        if (!disconnected.isCompleted) disconnected.complete();
      },
    );
    addTearDown(sub.cancel);
    await client.connect();
    await disconnected.future.timeout(const Duration(seconds: 3));
    rehydrations.clear();
    await client.connect();
    await _until(() => sinceRequests == 1);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      client.replayWatermarksForTesting.containsKey('runtime-1'),
      isFalse,
      reason: 'precondition: quarantined, no watermark',
    );
  }

  test('a quarantined busy runtime sends no probe and no rehydration over '
      'three watchdog windows', () async {
    await boot();
    rosterStatus = 'working';
    client.debugMarkRuntimeBusy('runtime-1');
    for (var i = 0; i < 3; i++) {
      clock = clock.add(const Duration(seconds: 40));
      await client.debugProbeSilentFanout();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(sinceRequests, 1, reason: 'only the reconnect replay asked');
    expect(
      rosterRequests,
      2,
      reason: 'roster reads back off: at 40 s and 80 s, none at 120 s',
    );
    expect(rehydrations, isEmpty);
  });

  // Hermes lists a live session as idle once `running` is false
  // (tui_gateway/server.py `_session_live_status`) and drops it when it is
  // closed (`session.active_list` skips `_finalized`): a turn that ended
  // without a frame this client saw rehydrates once, without /messages reads.
  for (final status in <String?>['idle', null]) {
    test('a quarantined turn that ended with no end frame rehydrates once '
        '(roster row ${status ?? 'gone'})', () async {
      await boot();
      rosterStatus = status;
      client.debugMarkRuntimeBusy('runtime-1');
      clock = clock.add(const Duration(seconds: 40));
      await client.debugProbeSilentFanout();
      await _until(() => rehydrations.isNotEmpty);
      clock = clock.add(const Duration(seconds: 200));
      await client.debugProbeSilentFanout();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(rehydrations, hasLength(1));
      expect(rehydrations.single!['turn_ended'], isTrue);
      expect(sinceRequests, 1, reason: 'no since(0) loop');
    });
  }

  // The probe skip keys on quarantine alone: `_recordWatermark` never records
  // a watermark for a quarantined runtime, so none can hide a real probe.
  test('a live frame of a quarantined runtime records no watermark', () async {
    await boot();
    secondSocket()!.add(jsonEncode(_event(10, 'message.delta')));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(client.replayWatermarksForTesting.containsKey('runtime-1'), isFalse);
  });

  test('a withheld end of turn still rehydrates once', () async {
    await boot();
    client.debugMarkRuntimeBusy('runtime-1');
    clock = clock.add(const Duration(seconds: 40));
    await client.debugProbeSilentFanout();
    secondSocket()!.add(jsonEncode(_event(10, 'message.complete')));
    await _until(() => rehydrations.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(rehydrations, hasLength(1));
    expect(rehydrations.single!['turn_ended'], isTrue);
  });
  test('after a withheld end the rearmed watchdog may probe again (answer '
      'not durable yet)', () async {
    await boot();
    client.debugMarkRuntimeBusy('runtime-1');
    secondSocket()!.add(jsonEncode(_event(10, 'message.complete')));
    await _until(() => rehydrations.length == 1);
    client.rearmRuntimeWatchdog('runtime-1');
    clock = clock.add(const Duration(seconds: 40));
    await client.debugProbeSilentFanout();
    await _until(() => sinceRequests == 2 && rehydrations.length == 2);
  });
}

Future<void> _until(bool Function() test) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!test()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
