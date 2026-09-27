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

      // Before the fix every tick (12 in 60 s) opened a new socket.
      expect(
        opens.length,
        lessThanOrEqualTo(7),
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
}
