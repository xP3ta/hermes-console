import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// mk1215: an in-memory gateway socket for fake-time tests. It emits
/// `gateway.ready` after [readyAfter] and answers every RPC at once with
/// [respond] (an empty result by default). A `null` from [respond] leaves
/// that RPC unanswered.
final class ScriptedGatewayChannel implements WebSocketChannel {
  ScriptedGatewayChannel({Duration readyAfter = Duration.zero, this.respond}) {
    void ready() {
      if (_incoming.isClosed) return;
      _incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
        }),
      );
    }

    if (readyAfter > Duration.zero) {
      Timer(readyAfter, ready);
    } else {
      ready();
    }
  }

  final Map<String, dynamic>? Function(Map<String, dynamic> frame)? respond;
  final StreamController<dynamic> _incoming = StreamController<dynamic>();

  /// Methods of every request the client sent, in order.
  final List<String> methods = [];

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _ScriptedSink(this);

  /// Ends the stream without a close frame, like a dropped network path.
  void drop() {
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  void _onFrame(Map<String, dynamic> frame) {
    final id = frame['id'];
    if (_incoming.isClosed || id is! int) return;
    methods.add('${frame['method']}');
    final answer = respond;
    final result = answer == null ? <String, dynamic>{} : answer(frame);
    if (result == null) return;
    _incoming.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ScriptedSink implements WebSocketSink {
  _ScriptedSink(this.channel);

  final ScriptedGatewayChannel channel;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) => channel._onFrame(
    Map<String, dynamic>.from(jsonDecode(data as String) as Map),
  );

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    if (!_done.isCompleted) _done.complete();
    channel.drop();
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
