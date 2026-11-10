import 'dart:async';
import 'dart:convert';

import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A Dashboard that mints tickets, or fails them with [failWith].
final class QrcTickets extends DashboardClient {
  QrcTickets() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  Object? failWith;
  int minted = 0;

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async {
    final error = failWith;
    if (error != null) throw error;
    minted += 1;
    return const DashboardWebSocketAuth(queryName: 'ticket', credential: 't');
  }
}

String qrcReadyFrame({Map<String, dynamic> payload = const {}}) => jsonEncode({
  'jsonrpc': '2.0',
  'method': 'event',
  'params': {'type': 'gateway.ready', 'payload': payload},
});

/// A socket the test drives: `gateway.ready` arrives on open (unless
/// [readyOnOpen] is false), later frames through [push], a peer close through
/// [closeFromPeer]. Whatever the client sends is kept in [sent]; nothing is
/// ever answered unless the test does it.
final class QrcFakeChannel implements WebSocketChannel {
  QrcFakeChannel({bool readyOnOpen = true}) {
    if (readyOnOpen) _incoming.add(qrcReadyFrame());
  }

  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final List<String> sent = <String>[];
  bool get closedByClient => _sink._done.isCompleted;

  void push(String frame) {
    if (!_incoming.isClosed) _incoming.add(frame);
  }

  /// The server (or the OS) closed the socket: the stream ends.
  void closeFromPeer() {
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  late final _QrcSink _sink = _QrcSink(this);

  @override
  WebSocketSink get sink => _sink;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _QrcSink implements WebSocketSink {
  _QrcSink(this.channel);

  final QrcFakeChannel channel;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) {
    if (data is String) channel.sent.add(data);
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    if (!_done.isCompleted) _done.complete();
    channel.closeFromPeer();
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
