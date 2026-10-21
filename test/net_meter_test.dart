// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/gateway_socket_meter.dart';
import 'package:hermes_android/core/config/flavor.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show ApiClient, DashboardClient, DashboardWebSocketAuth;
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/origin_bound_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/in_memory_compression_restore_storage.dart';

void main() {
  final meter = GatewaySocketMeter.instance;
  late List<String> lines;
  late DateTime clock;

  void enable() {
    lines = [];
    clock = DateTime(2026);
    meter.reset();
    meter.now = () => clock;
    meter.debugUseLog(NetMeterLog(lines.add));
  }

  tearDown(meter.reset);

  group('gate', () {
    test('the compile-time gate follows the QA flavor only', () {
      expect(kNetMeterEnabled, kHermesFlavor == 'qa');
    });

    test('a release build never enables the sink, even in the QA flavor', () {
      addTearDown(meter.reset);
      meter.reset(release: true);
      expect(meter.enabled, isFalse);
      meter.reset();
      expect(meter.enabled, kHermesFlavor == 'qa');
    });

    test('with the gate off nothing is written and no state is kept', () async {
      meter.reset();
      meter.debugUseLog(null);
      expect(meter.enabled, isFalse);
      final printed = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      addTearDown(() => debugPrint = originalPrint);
      meter.recordRest('GET', '/api/status', 200, 5);
      meter.recordRpc('session.list', 'ok', 5);
      meter.recordReady(5);
      meter.recordBackoff(1, 1000);
      meter.recordProbe(ok: false);
      meter.recordNetworkAvailable();
      meter.recordNetworkLost();
      meter.recordClose(reason: 'peer_closed', code: 1006);
      meter.trackRpc('x.y', Future<Object?>.value(1), (_) => false);
      final client = OriginBoundHttpClient(
        MockClient((_) async => http.Response('', 200)),
      );
      await client.get(Uri.parse('https://example.test/api/status'));
      expect(printed.where((l) => l.contains('[QA-NET]')), isEmpty);
    });
  });

  group('REST', () {
    test(
      'normalizes the path, drops the query and keeps the host out',
      () async {
        enable();
        final client = OriginBoundHttpClient(
          MockClient((_) async => http.Response('{}', 200)),
        );
        await client.get(
          Uri.parse(
            'https://secret-host.test:9119/api/profiles/mi-perfil/soul'
            '?token=TOPSECRET&x=1',
          ),
        );
        expect(lines, hasLength(1));
        expect(
          lines.single,
          matches(
            RegExp(
              r'^\[QA-NET\] rest GET /api/profiles/:id/soul 200 \d+ms '
              r'origin=none$',
            ),
          ),
        );
        final all = lines.join('\n');
        for (final leaked in [
          'TOPSECRET',
          'secret-host',
          'mi-perfil',
          'token',
        ]) {
          expect(all, isNot(contains(leaked)));
        }
      },
    );

    test('session ids and file names never appear', () {
      expect(
        NetMeterLog.normalizePath('/api/sessions/20260101_abc123/messages'),
        '/api/sessions/:id/messages',
      );
      expect(
        NetMeterLog.normalizePath('/api/files/download/my%20doc.pdf'),
        '/api/files/download/:id',
      );
    });

    test('a failed request is logged as error with its time', () async {
      enable();
      final client = OriginBoundHttpClient(
        MockClient((_) async => throw http.ClientException('boom')),
      );
      await expectLater(
        client.get(Uri.parse('https://example.test/api/status')),
        throwsA(isA<http.ClientException>()),
      );
      expect(lines.single, contains('rest GET /api/status error'));
    });
  });

  group('RPC and WebSocket', () {
    test(
      'a timed out RPC logs timeout and ms, never params or errors',
      () async {
        enable();
        final done = Completer<Object?>();
        meter.trackRpc(
          'gateway.ping',
          done.future,
          (e) => e is TimeoutException,
        );
        done.completeError(TimeoutException('secret detail'));
        await Future<void>.delayed(Duration.zero);
        expect(
          lines.single,
          matches(
            RegExp(r'^\[QA-NET\] rpc gateway\.ping timeout \d+ms origin=none$'),
          ),
        );
        expect(lines.join(), isNot(contains('secret')));
      },
    );

    test('ok and error outcomes; odd method names are masked', () async {
      enable();
      meter.trackRpc('session.list', Future<Object?>.value(1), (_) => false);
      meter.trackRpc('s.x', Future<Object?>.error('nope'), (_) => false);
      await Future<void>.delayed(Duration.zero);
      meter.recordRpc('Has Spaces/and-user-data', 'ok', 3);
      expect(lines[0], contains('rpc session.list ok'));
      expect(lines[1], contains('rpc s.x error'));
      expect(lines[2], contains('rpc :id ok'));
    });

    test('close, open, backoff, probe and network events', () {
      enable();
      meter.recordReady(321);
      meter.recordClose(
        reason: 'heartbeat_timeout',
        code: 4000,
        life: const Duration(seconds: 42),
      );
      meter.recordBackoff(3, 2500);
      meter.recordProbe(ok: true);
      meter.recordProbe(ok: false);
      meter.recordNetworkLost();
      meter.recordNetworkAvailable();
      expect(lines, [
        '[QA-NET] ws open ready_ms=321',
        '[QA-NET] ws close reason=heartbeat_timeout code=4000 life=42000ms',
        '[QA-NET] ws backoff attempt=3 ms=2500',
        '[QA-NET] ws probe ok',
        '[QA-NET] ws probe timeout',
        '[QA-NET] ws net lost',
        '[QA-NET] ws net available',
      ]);
    });

    test('a 60 s summary lists opens, closes and p50/p95 per route', () {
      enable();
      meter.recordOpen();
      meter.recordOpen();
      meter.recordClose(reason: 'peer_closed', code: 1006);
      for (final ms in [10, 20, 30, 40, 100]) {
        meter.recordRest('GET', '/api/status', 200, ms);
      }
      expect(lines.where((l) => l.contains('summary')), isEmpty);
      clock = clock.add(const Duration(seconds: 61));
      meter.recordProbe(ok: true);
      final summary = lines.singleWhere((l) => l.contains('summary'));
      expect(summary, contains('opens=2'));
      expect(summary, contains('peer_closed: 1'));
      expect(
        summary,
        contains('GET /api/status{origin=none}=5x p50=30 p95=100'),
      );
    });
  });

  group('N0: origin, REST outcome, live sockets, transcript reads', () {
    const origins = [
      'chat.snapshot',
      'chat.recovery',
      'list.agentCenter',
      'home.observer',
    ];

    test('REST and RPC lines carry the caller origin label', () async {
      enable();
      final client = OriginBoundHttpClient(
        MockClient((_) async => http.Response('{}', 200)),
      );
      await GatewaySocketMeter.origin(
        'chat.snapshot',
        () => client.get(Uri.parse('https://example.test/api/status')),
      );
      await GatewaySocketMeter.origin('list.agentCenter', () async {
        meter.trackRpc(
          'spawn_tree.list',
          Future<Object?>.value(1),
          (_) => false,
        );
        await Future<void>.delayed(Duration.zero);
      });
      await client.get(Uri.parse('https://example.test/api/status'));
      expect(lines[0], endsWith(' origin=chat.snapshot'));
      expect(lines[1], endsWith(' origin=list.agentCenter'));
      expect(lines[2], endsWith(' origin=none'));
    });

    test('an origin outside the stable token shape is masked', () async {
      enable();
      await GatewaySocketMeter.origin('has spaces/and-user-data', () async {
        meter.recordRpc('session.list', 'ok', 1);
      });
      expect(lines.single, endsWith(' origin=other'));
      expect(lines.join(), isNot(contains('user-data')));
    });

    test('the origin survives awaits inside the labelled call', () async {
      enable();
      await GatewaySocketMeter.origin('chat.recovery', () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        meter.recordRpc('session.resume', 'ok', 1);
      });
      expect(lines.single, endsWith(' origin=chat.recovery'));
    });

    test('the summary lists origin= per route and live=', () {
      enable();
      for (final o in origins) {
        GatewaySocketMeter.origin(o, () => meter.recordRpc('x.y', 'ok', 5));
      }
      clock = clock.add(const Duration(seconds: 61));
      meter.recordProbe(ok: true);
      final summary = lines.singleWhere((l) => l.contains('summary'));
      for (final o in origins) {
        expect(summary, contains('RPC x.y{origin=$o}=1x'));
      }
      expect(summary, contains('live='));
    });

    test(
      'REST result is aborted, timeout or error, not just a status',
      () async {
        enable();
        Future<void> run(Object failure) async {
          final client = OriginBoundHttpClient(
            MockClient((_) async => throw failure),
          );
          await client
              .get(Uri.parse('https://example.test/api/status'))
              .then<void>((_) {}, onError: (Object _) {});
        }

        await run(http.RequestAbortedException());
        await run(TimeoutException('slow'));
        await run(http.ClientException('boom'));
        expect(lines[0], contains('rest GET /api/status aborted'));
        expect(lines[1], contains('rest GET /api/status timeout'));
        expect(lines[2], contains('rest GET /api/status error'));
        clock = clock.add(const Duration(seconds: 61));
        meter.recordProbe(ok: true);
        final summary = lines.singleWhere((l) => l.contains('summary'));
        expect(
          summary,
          contains('rest_results={aborted: 1, timeout: 1, error: 1}'),
        );
      },
    );

    test('live sockets are counted per (connection, profile, lane)', () {
      enable();
      meter.socketUp('c1/p1/chat');
      meter.socketUp('c1/p1/chat');
      meter.socketUp('c1/p1/observer');
      meter.recordProbe(ok: true); // opens the summary window
      meter.socketDown('c1/p1/chat');
      expect(meter.liveSockets, {'c1/p1/chat': 1, 'c1/p1/observer': 1});
      meter.socketDown('c1/p1/chat');
      meter.socketDown('c1/p1/chat'); // never below zero
      expect(meter.liveSockets, {'c1/p1/observer': 1});
      clock = clock.add(const Duration(seconds: 61));
      meter.recordProbe(ok: true);
      expect(
        lines.singleWhere((l) => l.contains('summary')),
        contains('live={c1/p1/observer: 1}'),
      );
    });

    test('GET .../messages is counted per origin; other routes are not', () {
      enable();
      GatewaySocketMeter.origin('chat.recovery', () {
        meter.recordRest('GET', '/api/sessions/abc/messages', 200, 4);
        meter.recordRest('GET', '/api/sessions/def/messages', 200, 4);
      });
      GatewaySocketMeter.origin('chat.snapshot', () {
        meter.recordRest('GET', '/api/sessions/abc/messages', 200, 4);
      });
      meter.recordRest('POST', '/api/sessions/abc/messages', 200, 4);
      meter.recordRest('GET', '/api/status', 200, 4);
      expect(meter.messageReads, {'chat.recovery': 2, 'chat.snapshot': 1});
      clock = clock.add(const Duration(seconds: 61));
      meter.recordProbe(ok: true);
      expect(
        lines.singleWhere((l) => l.contains('summary')),
        contains('messages={chat.recovery: 2, chat.snapshot: 1}'),
      );
    });

    test('the QA-NET lines never carry the profile or connection id', () {
      enable();
      meter.socketUp(
        GatewaySocketMeter.socketKey('conn-secret-id', 'mi-perfil', 'chat'),
      );
      meter.recordProbe(ok: true); // opens the summary window
      clock = clock.add(const Duration(seconds: 61));
      meter.recordProbe(ok: true);
      final all = lines.join('\n');
      expect(all, contains('live={'));
      expect(all, isNot(contains('conn-secret-id')));
      expect(all, isNot(contains('mi-perfil')));
      expect(all, contains('/chat'));
    });

    test('with the gate off the new calls keep no state', () {
      meter.reset();
      meter.debugUseLog(null);
      meter.socketUp('c/p/chat');
      GatewaySocketMeter.origin('chat.snapshot', () {
        meter.recordRest('GET', '/api/sessions/a/messages', 200, 1);
      });
      expect(meter.liveSockets, isEmpty);
      expect(meter.messageReads, isEmpty);
    });

    test('a real client reports its socket up on ready and down on close', () {
      fakeAsync((async) {
        enable();
        final client = TuiGatewayClient(
          _connection('live-a'),
          dashboard: _Ticket(),
          heartbeatInterval: Duration.zero,
          now: () => DateTime(2026).add(async.elapsed),
          channelFactory: (_, _) => _ReadyChannel(),
        );
        client.connect().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        expect(meter.liveSockets.values.fold<int>(0, (a, b) => a + b), 1);
        unawaited(client.close());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(meter.liveSockets, isEmpty);
      });
    });

    test('the pool labels its clients with the chat and observer lanes', () {
      fakeAsync((async) {
        enable();
        final pool = SharedGatewayPool.forTesting(
          factory: (c) => TuiGatewayClient(
            c,
            dashboard: _Ticket(),
            heartbeatInterval: Duration.zero,
            channelFactory: (_, _) => _ReadyChannel(),
          ),
        );
        final chat = pool.acquireChat(
          _connection('lane-a'),
          profile: 'p1',
          chatLinger: Duration.zero,
        );
        final observer = pool.acquire(_connection('lane-a'));
        expect(chat.client.meterLane, 'chat');
        expect(chat.client.meterProfile, 'p1');
        expect(observer.client.meterLane, 'observer');
        chat.client.connect().then<void>((_) {}, onError: (Object _) {});
        observer.client.connect().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        final keys = meter.liveSockets.keys.toList();
        expect(keys, hasLength(2));
        expect(keys.where((k) => k.endsWith('/chat')), hasLength(1));
        expect(keys.where((k) => k.endsWith('/observer')), hasLength(1));
        unawaited(chat.client.close());
        unawaited(observer.client.close());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
      });
    });
  });

  group('N10a: lane, recovery reason, quarantine and dial peak', () {
    test('recovery reasons are stable tokens; anything else is other', () {
      enable();
      meter.recordRecovery('transport');
      meter.recordRecovery('fanout_gap');
      meter.recordRecovery('withheld_turn_end');
      meter.recordRecovery('something=else');
      expect(lines, [
        '[QA-NET] recovery scheduled reason=transport',
        '[QA-NET] recovery scheduled reason=fanout_gap',
        '[QA-NET] recovery scheduled reason=withheld_turn_end',
        '[QA-NET] recovery scheduled reason=other',
      ]);
      expect(meter.takeRehydrationReason(), 'fanout_gap');
      meter.noteRehydration('withheld_turn_end');
      expect(meter.takeRehydrationReason(), 'withheld_turn_end');
      expect(meter.takeRehydrationReason(), 'fanout_gap');
    });

    test('the summary has recoveries=, quarantined= and the dial peak', () {
      enable();
      meter.recordRecovery('transport');
      meter.recordRecovery('transport');
      meter.recordQuarantined('c/p/chat', 2);
      meter.recordQuarantined('c/p/observer', 1);
      meter.dialStart('c/p/chat');
      meter.dialStart('c/p/chat');
      meter.dialEnd('c/p/chat');
      meter.dialStart('c/p/observer');
      meter.dialEnd('c/p/observer');
      clock = clock.add(const Duration(seconds: 61));
      meter.recordProbe(ok: true);
      final summary = lines.singleWhere((l) => l.contains('summary'));
      expect(summary, contains('recoveries={transport: 2}'));
      expect(summary, contains('quarantined=3'));
      expect(
        summary,
        contains('dials_inflight_max={c/p/chat: 2, c/p/observer: 1}'),
      );
      // The peak restarts from what is still in flight, recoveries from 0.
      clock = clock.add(const Duration(seconds: 61));
      meter.recordProbe(ok: true);
      final next = lines.where((l) => l.contains('summary')).last;
      expect(next, contains('recoveries={}'));
      expect(next, contains('dials_inflight_max={c/p/chat: 1}'));
    });

    test('with the gate off the new calls keep no state', () {
      meter.reset();
      meter.debugUseLog(null);
      meter.recordRecovery('transport');
      meter.recordQuarantined('k', 1);
      meter.dialStart('k');
      meter.noteRehydration('withheld_turn_end');
      meter.recordRecoveryDone('transport', 1, 1, 1);
      meter.startStallWatch();
      expect(meter.takeRehydrationReason(), 'fanout_gap');
    });

    test('origin labels: an enclosing label wins over originIfNone', () async {
      enable();
      await GatewaySocketMeter.origin('chat.foreground', () async {
        await GatewaySocketMeter.originIfNone('chat.passive', () async {
          meter.recordRest('GET', '/api/sessions/s/messages', 200, 1);
        });
      });
      await GatewaySocketMeter.originIfNone('chat.passive', () async {
        meter.recordRest('GET', '/api/sessions/s/messages', 200, 1);
      });
      expect(meter.messageReads, {'chat.foreground': 1, 'chat.passive': 1});
    });

    test('ready, close and backoff lines carry lane and socket', () {
      fakeAsync((async) {
        enable();
        final pool = SharedGatewayPool.forTesting(
          factory: (c) => TuiGatewayClient(
            c,
            dashboard: _Ticket(),
            heartbeatInterval: Duration.zero,
            channelFactory: (_, _) => _ReadyChannel(),
          ),
        );
        final observer = pool.acquire(_connection('tag-a'));
        observer.client.connect().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        unawaited(observer.client.close());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        final key = GatewaySocketMeter.socketKey('tag-a', '', 'observer');
        final tag = ' lane=observer socket=$key';
        expect(
          lines,
          contains(matches('\\[QA-NET\\] ws open ready_ms=\\d+$tag')),
        );
        expect(
          lines.where((l) => l.contains('ws close ') && l.endsWith(tag)),
          hasLength(1),
        );
        // One dial, never two at once, on this lane.
        expect(lines.any((l) => l.contains('lane=chat')), isFalse);
      });
    });

    test('a failed ticket names the lane and the kind', () {
      fakeAsync((async) {
        enable();
        final client = TuiGatewayClient(
          _connection('tag-b'),
          dashboard: _FailingTicket(),
          heartbeatInterval: Duration.zero,
          now: () => DateTime(2026).add(async.elapsed),
          channelFactory: (_, _) => _ReadyChannel(),
        );
        client.meterLane = 'observer';
        client.connect().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        final key = GatewaySocketMeter.socketKey('tag-b', '', 'observer');
        expect(
          lines,
          contains(
            '[QA-NET] ws ticket failed kind=transport '
            'lane=observer socket=$key',
          ),
        );
        expect(
          lines.any(
            (l) => l.contains('ws backoff') && l.contains('lane=observer'),
          ),
          isTrue,
        );
        unawaited(client.close());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
      });
    });
  });

  group('N10a: why the chat scheduled a recovery (real socket fake)', () {
    late _MeterGateway gateway;
    late SharedGatewayPool pool;
    late ActiveChatService service;
    var durablePrompt = false;
    var durableAnswer = false;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      HttpOverrides.global = null;
      enable();
      durablePrompt = false;
      durableAnswer = false;
      gateway = await _MeterGateway.start();
      pool = SharedGatewayPool.forTesting(linger: Duration.zero);
      service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
        connectionCredentialsRevision: ValueNotifier<int>(0),
        chatGatewayPool: pool,
        sharedChatGatewayFactory: (connection) => TuiGatewayClient(
          connection,
          dashboard: _Ticket(),
          heartbeatInterval: const Duration(hours: 1),
          heartbeatDeadline: const Duration(hours: 2),
        ),
      );
    });

    tearDown(() async {
      service.dispose();
      await pool.closeAll();
      await gateway.server.close(force: true);
    });

    test('a dropped socket is transport; a held turn end is '
        'withheld_turn_end', () async {
      final connection = SavedConnection(
        id: 'meter-reason',
        label: 'Reason',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'k',
        dashboardUrl: 'http://127.0.0.1:${gateway.server.port}',
      );
      final chat = service.attach(
        connection: connection,
        sessionId: 'stored-1',
        sessionTitle: 'Reason',
        sessionProfile: 'default',
        api: ApiClient(
          baseUrl: 'http://127.0.0.1:1',
          apiKey: 'k',
          httpClient: MockClient((_) async => http.Response('unused', 500)),
        ),
        storedMessageLoader: (_, _) async => [
          if (durablePrompt)
            {'id': 11, 'role': 'user', 'content': 'hola', 'timestamp': 100.0},
          if (durableAnswer)
            {
              'id': 12,
              'role': 'assistant',
              'content': 'respuesta final',
              'timestamp': 101.0,
            },
        ],
        attachDesktopRuntimeOnLoad: true,
        allowUnownedDesktopSnapshotForTesting: true,
        disableForegroundKeepAlive: true,
      );
      await chat.loadMessages();
      await _untilTrue(() => chat.desktopRuntimeSessionId == 'runtime-1');
      await chat.send(
        fullText: 'hola',
        model: 'hermes-agent',
        history: const [],
      );
      await _untilTrue(() => gateway.count('prompt.submit') == 1);
      durablePrompt = true;
      gateway.running = true;
      gateway.event('message.delta', const {'text': 'respuesta '});
      await _untilTrue(() => chat.assistantContent.contains('respuesta'));

      final resumes = gateway.count('session.resume');
      await gateway.sockets.last.close(1001);
      await _untilTrue(
        () =>
            gateway.sockets.length == 2 &&
            gateway.count('session.resume') > resumes &&
            chat.state == ChatPipelineState.streaming,
      );
      expect(
        lines.where((l) => l.contains('recovery scheduled reason=')).toList(),
        ['[QA-NET] recovery scheduled reason=transport'],
      );

      durableAnswer = true;
      gateway.running = false;
      gateway.event('message.complete', const {'text': 'respuesta final'});
      await _untilTrue(() => chat.state == ChatPipelineState.completed);
      // N10b: the held turn end on a connected socket re-reads in place, it
      // is no longer a scheduled recovery.
      expect(
        lines.where((l) => l.contains('recovery scheduled reason=')).toList(),
        ['[QA-NET] recovery scheduled reason=transport'],
      );
      expect(
        lines.where((l) => l.contains('recovery done reason=')),
        hasLength(greaterThanOrEqualTo(1)),
      );
      // The quarantine gauge saw the runtime held after the cut.
      clock = clock.add(const Duration(seconds: 61));
      meter.recordProbe(ok: true);
      final summary = lines.singleWhere((l) => l.contains('summary'));
      expect(summary, contains('recoveries={transport: 1}'));
      expect(summary, matches(RegExp(r'quarantined=\d+')));
      expect(summary, contains('dials_inflight_max={'));
    });
  });
}

final class _Ticket extends DashboardClient {
  _Ticket() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'n0');
}

SavedConnection _connection(String id) => SavedConnection(
  id: id,
  label: id,
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'unused',
  dashboardUrl: 'http://127.0.0.1:1',
);

/// Emits `gateway.ready`, then stays open until closed.
final class _ReadyChannel implements WebSocketChannel {
  _ReadyChannel() {
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  final StreamController<dynamic> _incoming = StreamController<dynamic>();

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _ReadySink(_incoming);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ReadySink implements WebSocketSink {
  _ReadySink(this._incoming);

  final StreamController<dynamic> _incoming;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) {}

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    if (!_done.isCompleted) _done.complete();
    if (!_incoming.isClosed) unawaited(_incoming.close());
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FailingTicket extends DashboardClient {
  _FailingTicket() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      throw const SocketException('unreachable');
}

Future<void> _untilTrue(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

/// Minimal real-socket Hermes fake: stored `stored-1` → runtime `runtime-1`.
class _MeterGateway {
  _MeterGateway._(this.server) {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {
              'heartbeat': true,
              'change_events': true,
              'replay_epoch': 'epoch-1',
            },
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add(frame);
        if (socket.closeCode != null) continue;
        final method = frame['method'];
        if (method is! String) continue;
        final params = (frame['params'] as Map?) ?? const {};
        final result = switch (method) {
          'client.capabilities' => {
            'server_requests': ['approval', 'clarify', 'sudo', 'secret'],
          },
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
          'session.resume' => {
            'session_id': 'runtime-1',
            'stored_session_id': 'stored-1',
            'running': running,
            'status': running ? 'working' : 'idle',
            'inflight': running
                ? {'user': 'hola', 'assistant': 'respuesta '}
                : null,
          },
          'session.events.since' => {
            'epoch': 'epoch-1',
            'events': <Object>[],
            'latest_seq': params['last_seen'],
            'truncated': false,
            'count': 0,
          },
          'session.active_list' => {
            'sessions': [
              {
                'id': 'runtime-1',
                'session_key': 'stored-1',
                'stored_session_id': 'stored-1',
                'status': running ? 'working' : 'idle',
              },
            ],
          },
          'prompt.submit' => <String, dynamic>{'status': 'streaming'},
          _ => <String, dynamic>{'status': 'ok'},
        };
        try {
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        } on StateError {
          // The test closed this socket while the request was in flight.
        }
      }
    });
  }

  final HttpServer server;
  final sockets = <WebSocket>[];
  final frames = <Map<String, dynamic>>[];
  bool running = false;
  int _seq = 0;

  static Future<_MeterGateway> start() async =>
      _MeterGateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  void event(String type, Map<String, dynamic> payload) => sockets.last.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': type,
        'session_id': 'runtime-1',
        'seq': ++_seq,
        'payload': payload,
      },
    }),
  );

  int count(String method) => frames.where((f) => f['method'] == method).length;
}
