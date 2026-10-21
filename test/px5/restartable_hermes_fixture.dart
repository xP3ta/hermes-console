// SPDX-License-Identifier: GPL-3.0-only
// Hermes-shaped loopback host for PX5 tests: /, /api/auth/ws-ticket and
// /api/ws (gateway.ready with replay_epoch, session.active_list,
// session.resume answering 4007 once the state is new). Synthetic only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Hermes-shaped host that can be stopped (`close(force: true)`) and started
/// again on the same port with no memory of the previous run.
class RestartableHermes {
  HttpServer? _server;
  int port = 0;
  int tickets = 0;
  int epoch = 0;

  /// Stored session ids `session.active_list` advertises (any epoch), and the
  /// error `session.resume` answers once the state is new (epoch > 1).
  final advertised = <String>[];
  Map<String, Object?> resumeErrorAfterRestart = const {
    'code': 4007,
    'message': 'session not found',
  };
  final sockets = <WebSocket>[];

  /// Whether the durable session row still answers over REST after a
  /// restart (state.db survives the process); 404 otherwise.
  bool rowSurvives = false;

  /// Every HTTP path outside the handshake routes, in order.
  final restPaths = <String>[];

  /// Every JSON-RPC method the client sent, in order.
  final methods = <String>[];

  Future<void> start() async {
    epoch += 1;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    port = _server!.port;
    _server!.listen((request) async {
      final path = request.uri.path;
      if (path == '/api/ws') {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        _serve(socket, epoch);
        return;
      }
      if (path == '/') {
        request.response.write('window.__HERMES_SESSION_TOKEN__="fixture";');
      } else if (path == '/api/auth/ws-ticket') {
        tickets += 1;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ticket': 't$tickets'}));
      } else {
        restPaths.add(path);
        if (rowSurvives) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'id': 'stored-px5b', 'title': 'New', 'messages': []}),
          );
        } else {
          request.response.statusCode = 404;
        }
      }
      await request.response.close();
    });
  }

  Future<void> stop() async {
    // close(force) leaves upgraded sockets alone; a dead process drops them.
    for (final socket in sockets) {
      unawaited(socket.close(WebSocketStatus.goingAway).catchError((_) {}));
    }
    sockets.clear();
    await _server?.close(force: true);
    _server = null;
  }

  void _serve(WebSocket socket, int epoch) {
    void send(Map<String, dynamic> m) {
      if (socket.readyState != WebSocket.open) return;
      try {
        socket.add(jsonEncode({'jsonrpc': '2.0', ...m}));
      } on StateError {
        // The sink closed under us: the process is gone.
      }
    }

    send({
      'method': 'event',
      'params': {
        'type': 'gateway.ready',
        'payload': {'heartbeat': false, 'replay_epoch': 'epoch-$epoch'},
      },
    });
    socket.listen((raw) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      final method = frame['method'];
      if (method is! String) return;
      methods.add(method);
      final params = (frame['params'] as Map?) ?? const {};
      // A server with a new, empty state knows no stored session: Hermes
      // answers the resume of a missing one with 4007.
      send({
        'id': frame['id'],
        if (method == 'session.resume' && epoch > 1)
          'error': resumeErrorAfterRestart
        else
          'result': switch (method) {
            'session.resume' => {
              'session_id': 'runtime-a',
              'stored_session_id': params['session_id'],
              'status': 'idle',
              'running': false,
            },
            'session.create' => {
              'session_id': 'runtime-new',
              'stored_session_id': 'stored-new',
              'status': 'idle',
              'running': false,
            },
            'prompt.submit' => {'status': 'streaming'},
            'session.activate' => {
              'session_id': params['session_id'],
              'stored_session_id': advertised.isEmpty ? null : advertised.first,
              'status': 'idle',
              'running': false,
              'messages': <Object>[],
              'message_count': 0,
            },
            'session.active_list' => {
              'sessions': [
                for (final id in advertised)
                  {
                    'id': 'runtime-a',
                    'session_key': id,
                    'status': 'idle',
                    'message_count': 0,
                  },
              ],
            },
            'gateway.capabilities' => {'per_session_exclusive_submit': true},
            'client.capabilities' => {'server_requests': <Object>[]},
            _ => <String, dynamic>{},
          },
      });
    });
  }
}
