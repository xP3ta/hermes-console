import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
// Transitive via flutter_test; keep the production lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';

import 'support/qrc_fake_gateway_socket.dart';

class _CloseChannel implements WebSocketChannel {
  final delegate = QrcFakeChannel();
  @override
  Stream<dynamic> get stream => delegate.stream;
  @override
  WebSocketSink get sink => delegate.sink;
  @override
  Future<void> get ready => delegate.ready;
  @override
  int get closeCode => 1002;
  @override
  String? get closeReason => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('dart:io can report 1002 onDone without a peer close frame', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final raw = Completer<Socket>();
    final serving = server.listen((request) async {
      final key = request.headers.value('Sec-WebSocket-Key')!;
      final accept = base64Encode(
        sha1
            .convert(utf8.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
            .bytes,
      );
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.write(
        'HTTP/1.1 101 Switching Protocols\r\n'
        'Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n',
      );
      await socket.flush();
      raw.complete(socket);
    });
    final channel = IOWebSocketChannel.connect(
      'ws://127.0.0.1:${server.port}/',
    );
    final errors = <Object>[];
    final done = Completer<void>();
    final listener = channel.stream.listen(
      (_) {},
      onError: errors.add,
      onDone: done.complete,
    );
    await channel.ready;
    final socket = await raw.future;
    // Reserved opcode 3 makes the local decoder close; the server sends no
    // close frame at all. This is deliberately not a device reproduction.
    socket.add([0x83, 0]);
    await socket.flush();
    await done.future.timeout(const Duration(seconds: 3));
    expect(errors, isEmpty);
    expect(channel.closeCode, 1002);
    socket.destroy();
    await listener.cancel();
    await serving.cancel();
    await server.close(force: true);
  });

  test(
    'ambiguous 1002 is stream_done; explicit parking is attributed locally',
    () {
      fakeAsync((time) {
        final tickets = QrcTickets();
        final channels = <_CloseChannel>[];
        final client = TuiGatewayClient(
          SavedConnection(
            id: 'origin',
            label: 'Origin',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'unused',
            kind: InstanceKind.vps,
          ),
          dashboard: tickets,
          heartbeatInterval: Duration.zero,
          channelFactory: (_, _) {
            final c = _CloseChannel();
            channels.add(c);
            return c;
          },
        );
        final logs = <String>[];
        final previous = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) logs.add(message);
        };
        final events = client.events.listen((_) {}, onError: (Object _) {});
        try {
          unawaited(client.connect());
          time.flushMicrotasks();
          client.suspendBackgroundReconnects();
          time.elapse(const Duration(seconds: 9));
          expect(
            client.isConnected,
            isTrue,
            reason: 'suspension is not parking',
          );
          expect(channels.single.delegate.closedByClient, isFalse);
          channels.single.delegate.closeFromPeer();
          time.flushMicrotasks();
          expect(
            logs.where((s) => s.contains('closeCode=1002')).single,
            contains('origin=unknown'),
            reason: 'onDone cannot prove who closed',
          );
          expect(logs.where((s) => s.contains('reason=peer_closed')), isEmpty);
          time.elapse(const Duration(minutes: 2));
          expect(tickets.minted, 1, reason: 'push owns background delivery');
          client.setBackgroundParked(false);
          unawaited(client.connect());
          time.flushMicrotasks();
          expect(
            tickets.minted,
            2,
            reason: 'foreground resumes without backoff',
          );
          expect(client.isConnected, isTrue);
          client.setBackgroundParked(true);
          time.flushMicrotasks();
          expect(client.linkParked, isTrue);
          expect(client.isConnected, isFalse);
          // Teardown first drains the unanswered client.capabilities RPC.
          time.elapse(const Duration(seconds: 1));
          time.flushMicrotasks();
          expect(channels.last.delegate.closedByClient, isTrue);
          // Explicit parking fences the callback before closing the transport.
          expect(logs.where((s) => s.contains('closeCode=1002')), hasLength(1));
        } finally {
          unawaited(events.cancel());
          unawaited(client.close());
          time.elapse(const Duration(seconds: 2));
          time.flushMicrotasks();
          debugPrint = previous;
        }
      });
    },
  );
}
