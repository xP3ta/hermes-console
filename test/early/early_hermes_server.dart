// SPDX-License-Identifier: GPL-3.0-only
// EARLY: loopback host shaped like Hermes (WS + Dashboard REST) for a brand
// new chat. REST answers like hermes_cli/web_routers/sessions.py
// `get_session_messages`: 404 {"detail":"Session not found"} for an id the
// store does not know yet, 200 {session_id, profile, messages, pagination}
// otherwise. Synthetic only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef EarlyRest = ({int status, Object? body}) Function(Uri uri);

class EarlyHermes {
  HttpServer? _server;
  int port = 0;
  final restRequests = <String>[];
  final methods = <String>[];
  final sockets = <WebSocket>[];

  /// How `/api/sessions/{id}/messages` answers. Defaults to the Dashboard
  /// answer for a session the store has not written yet.
  EarlyRest rest = (_) => (status: 404, body: {'detail': 'Session not found'});

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = _server!.port;
    _server!.listen((request) async {
      final path = request.uri.path;
      if (path == '/api/ws') {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        _serve(socket);
        return;
      }
      final res = request.response;
      if (path == '/') {
        res.write('window.__HERMES_SESSION_TOKEN__="fixture";');
      } else if (path == '/api/auth/ws-ticket') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'ticket': 't'}));
      } else {
        restRequests.add(request.uri.toString());
        final answer = rest(request.uri);
        res.statusCode = answer.status;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(answer.body));
      }
      await res.close();
    });
  }

  Future<void> stop() async {
    for (final s in sockets) {
      unawaited(s.close(WebSocketStatus.goingAway).catchError((_) {}));
    }
    await _server?.close(force: true);
  }

  void _serve(WebSocket socket) {
    void send(Map<String, dynamic> m) {
      if (socket.readyState == WebSocket.open) {
        socket.add(jsonEncode({'jsonrpc': '2.0', ...m}));
      }
    }

    void event(String type, [Map<String, Object?> payload = const {}]) => send({
      'method': 'event',
      'params': {'type': type, 'session_id': 'runtime-new', 'payload': payload},
    });

    send({
      'method': 'event',
      'params': {
        'type': 'gateway.ready',
        'payload': {'heartbeat': false},
      },
    });
    socket.listen((raw) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      final method = frame['method'];
      if (method is! String) return;
      methods.add(method);
      send({
        'id': frame['id'],
        'result': switch (method) {
          'session.create' => {
            'session_id': 'runtime-new',
            'stored_session_id': 'stored-early',
            'status': 'idle',
            'running': false,
          },
          'prompt.submit' => {'status': 'streaming'},
          // live_session_payload / _resume_reuse_live: the reattach of the live
          // session; history rides REST when the client omits it.
          'session.resume' || 'session.activate' => {
            'session_id': 'runtime-new',
            'session_key': 'stored-early',
            'resumed': 'stored-early',
            'status': 'idle',
            'running': false,
            'messages': <Object>[],
            'messages_omitted': true,
            'message_count': 2,
          },
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
          'client.capabilities' => {'server_requests': <Object>[]},
          'session.active_list' => {'sessions': <Object>[]},
          _ => <String, dynamic>{},
        },
      });
      if (method == 'prompt.submit') {
        Timer(const Duration(milliseconds: 30), () {
          event('message.start');
          event('message.delta', {'text': 'Hola, ¿en qué te ayudo?'});
          event('message.complete', {
            'text': 'Hola, ¿en qué te ayudo?',
            'status': 'complete',
          });
        });
      }
    });
  }
}
