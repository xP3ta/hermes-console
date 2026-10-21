// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/gateway_socket_meter.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/origin_bound_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Real extends HttpOverrides {}

/// Loopback peer that accepts, reads the request and never answers. It reports
/// when the client side of the connection closes.
class _SilentPeer {
  _SilentPeer._(this._server, this._reply);

  final ServerSocket _server;
  final String? _reply;
  final accepted = <Socket>[];
  final closedAt = <int, DateTime>{};

  static Future<_SilentPeer> start({String? reply}) async {
    final peer = _SilentPeer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      reply,
    );
    peer._server.listen((socket) {
      final id = peer.accepted.length;
      peer.accepted.add(socket);
      if (peer._reply != null) socket.write(peer._reply);
      socket.listen((_) {}, onDone: () => peer.closedAt[id] = DateTime.now());
    });
    return peer;
  }

  int get port => _server.port;

  Future<void> close() async {
    for (final socket in accepted) {
      socket.destroy();
    }
    await _server.close();
  }
}

void main() {
  const deadline = Duration(milliseconds: 300);

  test(
    'a REST deadline closes the connection instead of abandoning it',
    () => HttpOverrides.runZoned(() async {
      final peer = await _SilentPeer.start();
      addTearDown(peer.close);
      final client = DashboardClient(
        host: '127.0.0.1',
        port: peer.port,
        manualToken: 'synthetic-token',
      );
      addTearDown(client.close);
      final started = DateTime.now();
      await expectLater(
        client.apiPost('fixture', timeout: deadline),
        throwsA(isA<TimeoutException>()),
      );
      final thrownAfter = DateTime.now().difference(started);
      // Allow the peer's read loop to notice the FIN/RST.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(peer.accepted, hasLength(1));
      expect(
        peer.closedAt[0],
        isNotNull,
        reason: 'server must see the client close <200 ms after the deadline',
      );
      final closeAfter = peer.closedAt[0]!.difference(started);
      expect(
        closeAfter - deadline,
        lessThan(const Duration(milliseconds: 200)),
      );
      expect(thrownAfter, greaterThanOrEqualTo(deadline));
    }, createHttpClient: _Real().createHttpClient),
  );

  test(
    'the deadline is total: a body that stalls after the headers is aborted',
    () => HttpOverrides.runZoned(() async {
      // Headers and a few body bytes, then silence.
      final peer = await _SilentPeer.start(
        reply: 'HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n{"a":',
      );
      addTearDown(peer.close);
      final client = DashboardClient(
        host: '127.0.0.1',
        port: peer.port,
        manualToken: 'synthetic-token',
      );
      addTearDown(client.close);
      final started = DateTime.now();
      await expectLater(
        client.apiPost('fixture', timeout: deadline),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(peer.closedAt[0], isNotNull);
      expect(
        peer.closedAt[0]!.difference(started) - deadline,
        lessThan(const Duration(milliseconds: 200)),
      );
    }, createHttpClient: _Real().createHttpClient),
  );

  test('QA meter records the abandoned REST call as aborted', () async {
    final lines = <String>[];
    final meter = GatewaySocketMeter.instance
      ..reset()
      ..debugUseLog(NetMeterLog(lines.add));
    addTearDown(meter.reset);
    await HttpOverrides.runZoned(() async {
      final peer = await _SilentPeer.start();
      addTearDown(peer.close);
      final client = DashboardClient(
        host: '127.0.0.1',
        port: peer.port,
        manualToken: 'synthetic-token',
      );
      addTearDown(client.close);
      await expectLater(
        client.apiPost('fixture', timeout: deadline),
        throwsA(isA<TimeoutException>()),
      );
    }, createHttpClient: _Real().createHttpClient);
    // The caller gets its TimeoutException when the deadline fires; the inner
    // send settles with the abort on a later socket event, and the meter
    // records it there. Wait for that event instead of assuming it already ran.
    final waiting = Stopwatch()..start();
    while (!lines.any((l) => l.contains('aborted')) &&
        waiting.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(lines.where((l) => l.contains('aborted')), isNotEmpty);
  });

  group('classifyRestFailure', () {
    test('maps every failure to one body-free class', () {
      expect(classifyRestFailure(TimeoutException('x')), 'timeout');
      expect(classifyRestFailure(http.RequestAbortedException()), 'timeout');
      expect(
        classifyRestFailure(const SocketException('secret-host')),
        'transport',
      );
      expect(classifyRestFailure(http.ClientException('x')), 'transport');
      expect(classifyRestFailure(const HandshakeException('x')), 'transport');
      expect(
        classifyRestFailure(const DashboardHttpException(500)),
        'http(500)',
      );
      expect(classifyRestFailure(const DashboardHttpException(401)), 'auth');
      expect(classifyRestFailure(const DashboardHttpException(403)), 'auth');
      expect(
        classifyRestFailure(
          const DashboardAuthException(DashboardAuthFailureCode.loginRequired),
        ),
        'auth',
      );
      expect(classifyRestFailure(StateError('x')), 'other');
    });
  });

  group('[rest] failed log', () {
    Future<List<String>> failWith(NetMeterLog? log) async {
      final meter = GatewaySocketMeter.instance
        ..reset()
        ..debugUseLog(log);
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      addTearDown(() {
        debugPrint = previous;
        meter.reset();
      });
      final client = DeadlineHttpClient(
        MockClient((_) async => throw const SocketException('down')),
        deadline,
      );
      await expectLater(
        client.get(Uri.parse('http://127.0.0.1:9/x')),
        throwsA(isA<SocketException>()),
      );
      return printed.where((l) => l.contains('[rest] failed')).toList();
    }

    test('stays silent when the QA meter is off (release)', () async {
      expect(await failWith(null), isEmpty);
    });

    test('prints once when the QA meter is on', () async {
      expect(await failWith(NetMeterLog((_) {})), [
        '[rest] failed class=transport',
      ]);
    });
  });

  test('a fast answer passes through the deadline view untouched', () async {
    final client = OriginBoundHttpClient(
      MockClient((_) async => http.Response('{"ok":true}', 200)),
    );
    final res = await client
        .within(deadline)
        .get(Uri.parse('http://127.0.0.1:9/x'));
    expect(res.statusCode, 200);
    expect(res.body, '{"ok":true}');
  });
}
