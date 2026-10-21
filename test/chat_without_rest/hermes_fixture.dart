import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Synthetic host: Dashboard side (`/`, ws-ticket, `/api/ws`) plus a count of
/// every HTTP path and JSON-RPC method. Any other path is a REST call the
/// chat must not make: recorded in [restHits], answered 503.
final class FakeHermes {
  FakeHermes._(this.server, this.rootStatus, this.dropOnResume);

  final HttpServer server;
  final int? rootStatus;
  final bool dropOnResume;
  final paths = <String>[];
  final frames = <Map<String, dynamic>>[];
  final sockets = <WebSocket>[];
  final results = <String, Map<String, dynamic>>{};
  final events = <String, Map<String, dynamic>>{}; // pushed after a reply
  final errors = <String, int>{};
  final lostOnce = <String>{}; // reply swallowed once

  int get port => server.port;
  Iterable<String> get restHits =>
      paths.where((p) => !{'/', '/api/auth/ws-ticket', '/api/ws'}.contains(p));
  Iterable<Map<String, dynamic>> rpc(String method) =>
      frames.where((f) => f['method'] == method);

  static Future<FakeHermes> start({
    int? rootStatus,
    bool dropOnResume = false,
  }) async {
    final hermes = FakeHermes._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      rootStatus,
      dropOnResume,
    );
    hermes.server.listen(hermes._serve);
    return hermes;
  }

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    paths.add(path);
    final res = request.response;
    if (path == '/api/ws') {
      return _socket(await WebSocketTransformer.upgrade(request));
    }
    if (path == '/') {
      rootStatus != null
          ? res.statusCode = rootStatus!
          : res.write('window.__HERMES_SESSION_TOKEN__="fixture-token";');
    } else if (path == '/api/auth/ws-ticket') {
      res.write(jsonEncode({'ticket': 'fixture-ticket'}));
    } else {
      res.statusCode = 503;
    }
    await res.close();
  }

  static const _defaults = <String, Map<String, dynamic>>{
    'session.resume': {
      'session_id': 'runtime-fixture',
      'stored_session_id': 'stored-fixture',
      'status': 'idle',
      'running': false,
    },
    'session.active_list': {'sessions': <Object>[]},
    'gateway.capabilities': {'per_session_exclusive_submit': true},
    'client.capabilities': {'server_requests': <Object>[]},
    'prompt.submit': {'status': 'accepted'},
    'approval.respond': {'resolved': 1},
  };

  Future<void> _socket(WebSocket socket) async {
    sockets.add(socket);
    void send(Object message) => socket.add(
      jsonEncode({'jsonrpc': '2.0', ...(message as Map<String, dynamic>)}),
    );
    void event(Map<String, dynamic> params) =>
        send({'method': 'event', 'params': params});
    event({
      'type': 'gateway.ready',
      'payload': {'heartbeat': false},
    });
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      frames.add(frame);
      final method = frame['method'] as String;
      if (dropOnResume && method == 'session.resume') return socket.close();
      if (lostOnce.remove(method)) continue;
      final code = errors[method];
      send({
        'id': frame['id'],
        if (code != null)
          'error': {'code': code, 'message': 'fixture'}
        else
          'result': results[method] ?? _defaults[method] ?? <String, dynamic>{},
      });
      final pushed = events[method];
      if (pushed != null) event({'session_id': 'runtime-fixture', ...pushed});
    }
  }

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}
