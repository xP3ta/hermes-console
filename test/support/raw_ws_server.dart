import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Minimal RFC 6455 server over a raw [ServerSocket] for transport tests.
///
/// Unlike `WebSocketTransformer`, it lets a test stop reading from the kernel
/// while a "dispatch" runs ([pauseReads]), exactly like the Hermes read loop
/// that awaits an inline handler. Bytes the client sends meanwhile (its close
/// frame) stay in the kernel buffer, so a client-side RST discards them and the
/// server observes an abnormal closure instead of the client's code.
final class RawWsServer {
  RawWsServer._(this._server);

  final ServerSocket _server;
  final List<RawWsPeer> peers = [];
  final StreamController<RawWsPeer> _accepted =
      StreamController<RawWsPeer>.broadcast();

  /// Called for every text frame. Return a reply (JSON-encodable) or null.
  FutureOr<Object?> Function(RawWsPeer peer, Map<String, dynamic> frame)?
  onRequest;

  Map<String, dynamic> readyPayload = const {'heartbeat': false};

  int get port => _server.port;
  Stream<RawWsPeer> get accepted => _accepted.stream;

  static Future<RawWsServer> bind() async {
    final server = RawWsServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._server.listen(server._accept);
    return server;
  }

  void _accept(Socket socket) {
    final peer = RawWsPeer._(this, socket);
    peers.add(peer);
    _accepted.add(peer);
  }

  Future<void> close() async {
    for (final peer in peers) {
      peer._destroy();
    }
    await _server.close();
    await _accepted.close();
  }
}

final class RawWsPeer {
  RawWsPeer._(this._owner, this._socket) {
    _subscription = _socket.listen(
      _onData,
      onError: (Object error) => _finish(null, 'error:${error.runtimeType}'),
      onDone: () => _finish(null, 'eof'),
      cancelOnError: true,
    );
  }

  final RawWsServer _owner;
  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  bool _upgraded = false;
  final Completer<RawWsClose> _closed = Completer<RawWsClose>();
  final List<String> methods = [];
  int _pausedDispatches = 0;

  /// Resolves when the peer ends: a close frame (code/reason), or an abnormal
  /// end (`code == null`, `abnormal` describes the socket error or EOF).
  Future<RawWsClose> get closed => _closed.future;

  /// Stop reading (kernel keeps buffering) until the returned callback runs.
  void Function() pauseReads() {
    _pausedDispatches++;
    _subscription.pause();
    var resumed = false;
    return () {
      if (resumed) return;
      resumed = true;
      _pausedDispatches--;
      _subscription.resume();
    };
  }

  bool get readsPaused => _pausedDispatches > 0;

  void sendJson(Object value) {
    if (_closed.isCompleted) return;
    try {
      _socket.add(_frame(0x1, utf8.encode(jsonEncode(value))));
    } catch (_) {}
  }

  void sendClose(int code, [String reason = '']) {
    final reasonBytes = utf8.encode(reason);
    final payload = Uint8List(2 + reasonBytes.length)
      ..[0] = code >> 8
      ..[1] = code & 0xff
      ..setRange(2, 2 + reasonBytes.length, reasonBytes);
    try {
      _socket.add(_frame(0x8, payload));
    } catch (_) {}
  }

  /// Drop the TCP connection without a close frame.
  void _destroy() {
    try {
      _socket.destroy();
    } catch (_) {}
    _finish(null, 'destroyed');
  }

  void destroy() => _destroy();

  void _finish(int? code, String reason) {
    if (_closed.isCompleted) return;
    _closed.complete(RawWsClose(code, reason));
  }

  void _onData(Uint8List data) {
    _buffer.add(data);
    if (!_upgraded) {
      final bytes = _buffer.toBytes();
      final text = latin1.decode(bytes, allowInvalid: true);
      final end = text.indexOf('\r\n\r\n');
      if (end < 0) return;
      _buffer.clear();
      _buffer.add(bytes.sublist(end + 4));
      final keyLine = text
          .split('\r\n')
          .firstWhere(
            (line) => line.toLowerCase().startsWith('sec-websocket-key:'),
          );
      final key = keyLine.substring(keyLine.indexOf(':') + 1).trim();
      final accept = base64.encode(
        sha1
            .convert(utf8.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
            .bytes,
      );
      _socket.add(
        latin1.encode(
          'HTTP/1.1 101 Switching Protocols\r\n'
          'Upgrade: websocket\r\nConnection: Upgrade\r\n'
          'Sec-WebSocket-Accept: $accept\r\n\r\n',
        ),
      );
      _upgraded = true;
      sendJson({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': _owner.readyPayload},
      });
    }
    _drainFrames();
  }

  void _drainFrames() {
    while (true) {
      final bytes = _buffer.toBytes();
      if (bytes.length < 2) return;
      final opcode = bytes[0] & 0x0f;
      final masked = (bytes[1] & 0x80) != 0;
      var length = bytes[1] & 0x7f;
      var offset = 2;
      if (length == 126) {
        if (bytes.length < 4) return;
        length = (bytes[2] << 8) | bytes[3];
        offset = 4;
      } else if (length == 127) {
        if (bytes.length < 10) return;
        length = 0;
        for (var i = 2; i < 10; i++) {
          length = (length << 8) | bytes[i];
        }
        offset = 10;
      }
      final maskOffset = offset;
      if (masked) offset += 4;
      if (bytes.length < offset + length) return;
      final payload = Uint8List.fromList(
        bytes.sublist(offset, offset + length),
      );
      if (masked) {
        for (var i = 0; i < payload.length; i++) {
          payload[i] ^= bytes[maskOffset + (i % 4)];
        }
      }
      _buffer.clear();
      _buffer.add(bytes.sublist(offset + length));
      switch (opcode) {
        case 0x1:
          _onText(utf8.decode(payload));
        case 0x8:
          final code = payload.length >= 2
              ? (payload[0] << 8) | payload[1]
              : 1005;
          final reason = payload.length > 2
              ? utf8.decode(payload.sublist(2), allowMalformed: true)
              : '';
          sendClose(code == 1005 ? 1000 : code, '');
          _finish(code, reason);
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 20), () {
              try {
                _socket.destroy();
              } catch (_) {}
            }),
          );
          return;
        case 0x9:
          try {
            _socket.add(_frame(0xA, payload));
          } catch (_) {}
        default:
          break;
      }
    }
  }

  void _onText(String text) {
    final frame = Map<String, dynamic>.from(jsonDecode(text) as Map);
    final method = frame['method'] as String?;
    if (method != null) methods.add(method);
    final handler = _owner.onRequest;
    final id = frame['id'];
    if (id == null) return;
    if (handler == null) {
      sendJson({'jsonrpc': '2.0', 'id': id, 'result': <String, dynamic>{}});
      return;
    }
    unawaited(
      Future<Object?>.sync(() => handler(this, frame)).then((value) {
        if (value != null) sendJson(value);
      }),
    );
  }

  static Uint8List _frame(int opcode, List<int> payload) {
    final header = BytesBuilder()..addByte(0x80 | opcode);
    if (payload.length < 126) {
      header.addByte(payload.length);
    } else if (payload.length < 65536) {
      header
        ..addByte(126)
        ..addByte(payload.length >> 8)
        ..addByte(payload.length & 0xff);
    } else {
      header.addByte(127);
      for (var i = 7; i >= 0; i--) {
        header.addByte((payload.length >> (8 * i)) & 0xff);
      }
    }
    header.add(payload);
    return header.toBytes();
  }
}

final class RawWsClose {
  const RawWsClose(this.code, this.reason);

  /// Close code from the client's close frame; null when the connection ended
  /// without one (the server-side equivalent of 1006).
  final int? code;
  final String reason;

  @override
  String toString() => 'RawWsClose(code: $code, reason: $reason)';
}
