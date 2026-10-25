// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocketException;

import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Fakes for the auth notice tests: a Dashboard that answers ticket requests
/// from a script, and sockets that open or are refused on the upgrade.

/// Hands out the next answer of [answers] per ticket request (null = a
/// ticket), then tickets.
final class FakeTickets extends DashboardClient {
  FakeTickets({
    this.answers = const [],
    this.queryName = 'ticket',
    bool? simpleConnect,
  }) : super(
         host: '127.0.0.1',
         port: 1,
         manualToken: 'unused',
         simpleConnectOverride: simpleConnect,
       );

  final List<Object?> answers;
  final String queryName;
  int tickets = 0;

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async {
    final answer = tickets < answers.length ? answers[tickets] : null;
    tickets++;
    if (answer != null) throw answer;
    return DashboardWebSocketAuth(
      queryName: queryName,
      credential: 'c$tickets',
    );
  }
}

abstract class FakeChannel implements WebSocketChannel {
  FakeChannel({bool sync = false})
    : incoming = StreamController<dynamic>(sync: sync);

  final StreamController<dynamic> incoming;
  bool sinkClosed = false;

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  late final WebSocketSink sink = _Sink(this);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Emits `gateway.ready` and then stays open until [drop].
final class ReadyChannel extends FakeChannel {
  ReadyChannel() {
    incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  @override
  Future<void> get ready async {}

  /// The server goes away: the stream ends.
  void drop() {
    if (!incoming.isClosed) unawaited(incoming.close());
  }
}

/// An upgrade answered with HTTP [status] instead of 101: `ready` fails
/// with the wrapped `WebSocketException`, and the stream carries the error
/// and closes. By default in the order `AdapterWebSocketChannel` uses: its
/// stream controllers are synchronous, so the stream's error and done reach
/// the client before the failed `ready` does. [streamLater] delivers the
/// stream after `ready` instead. [hold] keeps the answer back until [answer]
/// is called.
final class RefusedUpgradeChannel extends FakeChannel {
  RefusedUpgradeChannel(
    this.status, {
    bool hold = false,
    this.streamLater = false,
  }) : super(sync: !streamLater) {
    unawaited(_ready.future.catchError((Object _) {}));
    if (!hold) scheduleMicrotask(answer);
  }

  final int status;
  final bool streamLater;
  final Completer<void> _ready = Completer<void>();

  void answer() {
    if (_ready.isCompleted) return;
    final error = WebSocketChannelException.from(
      WebSocketException('Connection was not upgraded to websocket', status),
    );
    _ready.completeError(error);
    void emit() {
      if (incoming.isClosed) return;
      incoming.addError(error);
      unawaited(incoming.close());
    }

    if (streamLater) {
      Timer.run(emit);
    } else {
      emit();
    }
  }

  @override
  Future<void> get ready => _ready.future;
}

final class _Sink implements WebSocketSink {
  _Sink(this.channel);

  final FakeChannel channel;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) {}

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    channel.sinkClosed = true;
    if (!_done.isCompleted) _done.complete();
    if (!channel.incoming.isClosed) unawaited(channel.incoming.close());
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
