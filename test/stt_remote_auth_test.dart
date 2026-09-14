import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/stt_remote.dart';

typedef _SocketHandler =
    void Function(int connection, Uri requestUri, WebSocket socket);

class _WsTestServer {
  _WsTestServer._(this._server, this._handler) {
    _subscription = _server.listen((request) {
      final accepted = _accept(request);
      _pending.add(accepted);
    });
  }

  final HttpServer _server;
  final _SocketHandler _handler;
  final List<WebSocket> _sockets = [];
  final List<Future<void>> _pending = [];
  late final StreamSubscription<HttpRequest> _subscription;
  int connections = 0;

  static Future<_WsTestServer> start(_SocketHandler handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _WsTestServer._(server, handler);
  }

  String get url => 'ws://127.0.0.1:${_server.port}';

  Future<void> _accept(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    connections++;
    _handler(connections, request.uri, socket);
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
    await Future.wait(_pending.map((future) => future.catchError((_) {})));
    for (final socket in _sockets) {
      try {
        await socket.close();
      } catch (_) {}
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('error público STT nunca incorpora el body remoto', () {
    final message = serverSttPublicErrorMessage({
      'message': 'PRIVATE_STT_FRAME /home/server/model',
    });

    expect(message, 'Server speech recognition failed.');
    expect(message, isNot(contains('PRIVATE_STT_FRAME')));
    expect(message, isNot(contains('/home/server')));
  });

  test('metadata pública STT usa allowlist numérica finita', () {
    expect(
      serverSttPublicMeta({
        'voiced_secs': 1.25,
        'avg_logprob': -0.3,
        'no_speech_prob': 0.2,
        'gate': 'PRIVATE_GATE',
        'trace': 'PRIVATE_TRACE',
        'path': '/home/server/model',
      }),
      {'voiced_secs': 1.25, 'avg_logprob': -0.3, 'no_speech_prob': 0.2},
    );
    expect(
      serverSttPublicMeta({
        'voiced_secs': double.nan,
        'avg_logprob': 'PRIVATE_STRING',
      }),
      isNull,
    );
  });

  test('auth moderno recibe ready sin exponer el token en la URL', () async {
    final authFrames = <Map<String, dynamic>>[];
    final uris = <Uri>[];
    final server = await _WsTestServer.start((_, uri, socket) {
      uris.add(uri);
      socket.listen((raw) {
        authFrames.add(jsonDecode(raw as String) as Map<String, dynamic>);
        socket.add(jsonEncode({'type': 'ready'}));
      });
    });
    addTearDown(server.close);
    final engine = ServerSttEngine(baseUrl: server.url, token: 'secret-token');
    addTearDown(engine.dispose);

    expect(await engine.ping(timeout: const Duration(seconds: 1)), isTrue);

    expect(server.connections, 1);
    expect(uris.single.queryParameters, isNot(contains('token')));
    expect(authFrames.single, {'type': 'auth', 'token': 'secret-token'});
  });

  test('error de auth inicial reintenta una vez con token legacy', () async {
    final uris = <Uri>[];
    final server = await _WsTestServer.start((connection, uri, socket) {
      uris.add(uri);
      if (connection == 1) {
        socket.listen((_) {
          socket.add(
            jsonEncode({
              'type': 'error',
              'code': 'auth_message_unsupported',
              'message': 'Unknown message type auth',
            }),
          );
        });
      } else {
        socket.add(jsonEncode({'type': 'ready'}));
      }
    });
    addTearDown(server.close);
    final engine = ServerSttEngine(baseUrl: server.url, token: 'legacy-token');
    addTearDown(engine.dispose);

    expect(await engine.ping(timeout: const Duration(seconds: 1)), isTrue);

    expect(server.connections, 2);
    expect(uris.first.queryParameters, isNot(contains('token')));
    expect(uris.last.queryParameters['token'], 'legacy-token');
  });

  test('el fallback legacy no vuelve a reintentar si también falla', () async {
    final server = await _WsTestServer.start((connection, _, socket) {
      if (connection == 1) {
        socket.listen((_) {
          socket.add(
            jsonEncode({
              'type': 'error',
              'message': 'Authentication messages are unsupported',
            }),
          );
        });
      } else {
        socket.add(jsonEncode({'type': 'error', 'message': 'Token rejected'}));
      }
    });
    addTearDown(server.close);
    final engine = ServerSttEngine(baseUrl: server.url, token: 'legacy-token');
    addTearDown(engine.dispose);

    expect(await engine.ping(timeout: const Duration(seconds: 1)), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(server.connections, 2);
  });

  test('un error posterior a ready nunca activa downgrade legacy', () async {
    final server = await _WsTestServer.start((connection, uri, socket) {
      socket.listen((_) {
        socket.add(jsonEncode({'type': 'ready'}));
        Timer(const Duration(milliseconds: 10), () {
          if (socket.readyState == WebSocket.open) {
            socket.add(
              jsonEncode({
                'type': 'error',
                'code': 'unauthenticated',
                'message': 'Token expired after ready',
              }),
            );
          }
        });
      });
    });
    addTearDown(server.close);
    final engine = ServerSttEngine(baseUrl: server.url, token: 'modern-token');
    addTearDown(engine.dispose);

    expect(await engine.ping(timeout: const Duration(seconds: 1)), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(server.connections, 1);
  });

  test(
    'un error inicial ajeno a auth no degrada al protocolo legacy',
    () async {
      final server = await _WsTestServer.start((connection, uri, socket) {
        socket.listen((_) {
          socket.add(
            jsonEncode({
              'type': 'error',
              'code': 'model_unavailable',
              'message': 'The speech model is still loading',
            }),
          );
        });
      });
      addTearDown(server.close);
      final engine = ServerSttEngine(
        baseUrl: server.url,
        token: 'modern-token',
      );
      addTearDown(engine.dispose);

      expect(await engine.ping(timeout: const Duration(seconds: 1)), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(server.connections, 1);
    },
  );
}
