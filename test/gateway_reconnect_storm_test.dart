import 'dart:async';
import 'dart:convert';

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _Ticket extends DashboardClient {
  _Ticket() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'storm');
}

final class _NetworkTicket extends DashboardClient {
  _NetworkTicket(this.networkUp)
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  final bool Function() networkUp;

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async {
    if (!networkUp()) throw StateError('Connection attempt cancelled');
    return const DashboardWebSocketAuth(queryName: 'ticket', credential: 's');
  }
}

/// Emits `gateway.ready`, answers RPCs, then drops (onDone, no close frame)
/// right after the [dropAfter]-th request.
final class _DroppingChannel implements WebSocketChannel {
  _DroppingChannel({required this.dropAfter}) {
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  final int dropAfter;
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  int requests = 0;

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _Sink(this);

  void onFrame(Map<String, dynamic> frame) {
    if (_incoming.isClosed) return;
    final id = frame['id'];
    if (id is! int || id < 0) return;
    requests++;
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': frame['method'] == 'profiles.list'
            ? {'profiles': <Object>[]}
            : <String, dynamic>{},
      }),
    );
    if (requests >= dropAfter) {
      scheduleMicrotask(() {
        if (!_incoming.isClosed) unawaited(_incoming.close());
      });
    }
  }

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Sink implements WebSocketSink {
  _Sink(this.channel);

  final _DroppingChannel channel;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) =>
      channel.onFrame(Map<String, dynamic>.from(jsonDecode(data as String)));

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    if (!_done.isCompleted) _done.complete();
    if (!channel._incoming.isClosed) unawaited(channel._incoming.close());
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SavedConnection _connection(String id) => SavedConnection(
  id: id,
  label: id,
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  dashboardUrl: 'http://127.0.0.1:1',
);

void main() {
  test('a 5 s poller over a socket that drops after each pass does not open a '
      'socket per tick, and attempts are spaced by a growing backoff', () {
    fakeAsync((async) {
      final opens = <Duration>[];
      final client = TuiGatewayClient(
        _connection('storm'),
        dashboard: _Ticket(),
        heartbeatInterval: Duration.zero,
        now: () => DateTime(2026).add(async.elapsed),
        reconnectBackoff: GatewayReconnectBackoff(random: () => 0.5),
        channelFactory: (_, _) {
          opens.add(async.elapsed);
          // client.capabilities + one poll RPC, then the socket dies.
          return _DroppingChannel(dropAfter: 2);
        },
      );
      final poller = Timer.periodic(const Duration(seconds: 5), (_) {
        unawaited(client.listProfiles().then((_) {}, onError: (Object _) {}));
      });
      async.elapse(const Duration(seconds: 60));
      poller.cancel();
      unawaited(client.close());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));

      // Before the fix every tick (12 in 60 s) opened a new socket. With the
      // Desktop 15 s ceiling the ladder tops out sooner than with 30 s.
      expect(
        opens.length,
        lessThanOrEqualTo(8),
        reason: 'opens at ${opens.map((d) => d.inMilliseconds).toList()}',
      );
      for (var i = 1; i < opens.length; i++) {
        expect(
          opens[i] - opens[i - 1],
          greaterThanOrEqualTo(GatewayReconnectBackoff.baseDelay),
        );
      }
      final gaps = [
        for (var i = 1; i < opens.length; i++) opens[i] - opens[i - 1],
      ];
      for (var i = 1; i < gaps.length; i++) {
        expect(gaps[i], greaterThanOrEqualTo(gaps[i - 1]));
      }
      expect(gaps.last, greaterThan(gaps.first));
    });
  });

  test('an RPC during backoff fails fast without creating a channel', () {
    fakeAsync((async) {
      var channels = 0;
      final client = TuiGatewayClient(
        _connection('fail-fast'),
        dashboard: _Ticket(),
        heartbeatInterval: Duration.zero,
        now: () => DateTime(2026).add(async.elapsed),
        reconnectBackoff: GatewayReconnectBackoff(random: () => 1),
        channelFactory: (_, _) {
          channels++;
          return _DroppingChannel(dropAfter: 1);
        },
      );
      client.connect();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 10));
      expect(channels, 1);
      expect(client.isConnected, isFalse);
      expect(client.isBackingOff, isTrue);

      Object? error;
      client.listProfiles().then<void>(
        (_) {},
        onError: (Object e) {
          error = e;
        },
      );
      async.flushMicrotasks();
      expect(error, isA<TuiGatewayRpcError>());
      expect(
        (error as TuiGatewayRpcError).failureKind,
        TuiGatewayRpcFailureKind.connectionLost,
      );
      expect(channels, 1, reason: 'no dial while the owner backs off');

      async.elapse(const Duration(seconds: 2));
      client.listProfiles().then((_) {}, onError: (Object _) {});
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 10));
      expect(channels, 2, reason: 'after the backoff the next RPC may dial');
      unawaited(client.close());
      async.elapse(const Duration(seconds: 2));
    });
  });

  test('a good read right after reconnect does not reset the backoff', () {
    fakeAsync((async) {
      final backoff = GatewayReconnectBackoff(random: () => 0);
      final client = TuiGatewayClient(
        _connection('no-reset'),
        dashboard: _Ticket(),
        heartbeatInterval: Duration.zero,
        now: () => DateTime(2026).add(async.elapsed),
        reconnectBackoff: backoff,
        channelFactory: (_, _) => _DroppingChannel(dropAfter: 2),
      );
      for (var i = 0; i < 4; i++) {
        client.connect().then((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        client.listProfiles().then((_) {}, onError: (Object _) {});
        async.elapse(const Duration(seconds: 20));
      }
      expect(backoff.attempt, 4, reason: 'short-lived sockets never reset');

      // A socket that stays up 30 s resets the counter when it is lost.
      final stable = GatewayReconnectBackoff(random: () => 0)
        ..nextDelay()
        ..nextDelay();
      late _DroppingChannel channel;
      final other = TuiGatewayClient(
        _connection('stable'),
        dashboard: _Ticket(),
        heartbeatInterval: Duration.zero,
        now: () => DateTime(2026).add(async.elapsed),
        reconnectBackoff: stable,
        channelFactory: (_, _) => channel = _DroppingChannel(dropAfter: 99),
      );
      other.connect();
      async.elapse(const Duration(seconds: 31));
      unawaited(channel._incoming.close());
      async.flushMicrotasks();
      expect(stable.attempt, 1);
      unawaited(client.close());
      unawaited(other.close());
      async.elapse(const Duration(seconds: 2));
    });
  });

  test('sockets that drop together (one per open chat) redial at distinct '
      'jittered times inside a bounded window', () {
    fakeAsync((async) {
      // The owner's log: six sockets closed together and reopened. Each chat
      // owns its own client and backoff; with no spread on the first attempt
      // they all redialled at exactly +1 s (a thundering herd).
      const sockets = 6;
      final channels = <_DroppingChannel>[];
      final clients = [
        for (var i = 0; i < sockets; i++)
          TuiGatewayClient(
            _connection('herd-$i'),
            dashboard: _Ticket(),
            heartbeatInterval: Duration.zero,
            now: () => DateTime(2026).add(async.elapsed),
            channelFactory: (_, _) {
              final channel = _DroppingChannel(dropAfter: 99);
              channels.add(channel);
              return channel;
            },
          ),
      ];
      for (final client in clients) {
        client.connect().then((_) {}, onError: (Object _) {});
      }
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 10));
      expect(clients.every((c) => c.isConnected), isTrue);

      for (final channel in channels) {
        unawaited(channel._incoming.close());
      }
      async.flushMicrotasks();
      final delays = [for (final c in clients) c.reconnectBackoffRemaining];
      expect(clients.every((c) => c.isBackingOff), isTrue);
      expect(
        delays.toSet(),
        hasLength(sockets),
        reason: 'first-attempt delays $delays must not coincide',
      );
      for (final delay in delays) {
        expect(delay, greaterThanOrEqualTo(GatewayReconnectBackoff.baseDelay));
        expect(
          delay,
          lessThanOrEqualTo(GatewayReconnectBackoff.baseDelay * 1.5),
        );
      }
      for (final client in clients) {
        unawaited(client.close());
      }
      async.elapse(const Duration(seconds: 2));
    });
  });

  test('the foreground reconnect ceiling matches Desktop (15 s)', () {
    // apps/shared/src/reconnect-backoff.ts: DEFAULT_CAP_MS = 15_000. A longer
    // ceiling kept "reconnecting" on screen well after the network returned.
    final backoff = GatewayReconnectBackoff(random: () => 1);
    var last = Duration.zero;
    for (var i = 0; i < 12; i++) {
      last = backoff.nextDelay();
    }
    expect(last, GatewayReconnectBackoff.foregroundCap);
    expect(GatewayReconnectBackoff.foregroundCap, const Duration(seconds: 15));
  });

  // rl1215: after a Wi-Fi/cellular switch every socket died together and the
  // outage drove each client's backoff to its 15 s ceiling. When the platform
  // reports the new default network, the stale ladder must not keep lazy RPC
  // dials failing fast (nor make the next loss wait the ceiling again).
  test('rl1215 a network change clears a stale reconnect backoff', () {
    fakeAsync((async) {
      final backoff = GatewayReconnectBackoff(random: () => 1);
      var channels = 0;
      var networkUp = true;
      final client = TuiGatewayClient(
        _connection('rl1215-network-change'),
        dashboard: _NetworkTicket(() => networkUp),
        heartbeatInterval: Duration.zero,
        now: () => DateTime(2026).add(async.elapsed),
        reconnectBackoff: backoff,
        channelFactory: (_, _) {
          channels++;
          return _DroppingChannel(dropAfter: 99);
        },
      );
      networkUp = false;
      for (var i = 0; i < 6; i++) {
        client.connect().then((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        async.elapse(client.reconnectBackoffRemaining);
      }
      client.connect().then((_) {}, onError: (Object _) {});
      async.flushMicrotasks();
      expect(client.isBackingOff, isTrue);
      expect(
        client.reconnectBackoffRemaining,
        greaterThan(const Duration(seconds: 10)),
      );

      networkUp = true;
      client.resetReconnectBackoffForNetworkChange();
      expect(client.isBackingOff, isFalse);
      expect(backoff.attempt, 0);
      final before = channels;
      client.listProfiles().then((_) {}, onError: (Object _) {});
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 10));
      expect(channels, before + 1, reason: 'the next RPC dials at once');
      expect(client.isConnected, isTrue);

      // A reset never tears a connected socket down.
      client.resetReconnectBackoffForNetworkChange();
      expect(client.isConnected, isTrue);
      unawaited(client.close());
      async.elapse(const Duration(seconds: 2));
    });
  });
}
