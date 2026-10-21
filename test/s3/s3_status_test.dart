// SPDX-License-Identifier: GPL-3.0-only
// S3: `starting` is ONE more entry of the single status derivation, with the
// priority authRequired > noNetwork > starting > noServer > reconnecting.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/connection_status.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import '../support/fake_connection_link.dart';

final class _StartingLink
    implements ConnectionLinkSource, ServerStartingLinkSource {
  final ConnectionSignal signal = ConnectionSignal();
  @override
  bool isConnected = false;
  @override
  bool isClosed = false;
  @override
  bool linkAuthRejected = false;
  @override
  DateTime? linkReconnectAt = DateTime.utc(2026, 10, 18, 0, 0, 5);
  @override
  int linkReconnectAttempt = 1;
  @override
  bool linkParked = false;
  @override
  bool linkServerStarting = true;
  @override
  Listenable get linkListenable => signal;
  void change(void Function() edit) {
    edit();
    signal.notify();
  }
}

ConnectionStatusKind _derive({
  bool socketReady = false,
  bool auth = false,
  bool net = false,
  bool starting = false,
  bool? rest,
}) => deriveConnectionStatus(
  socketReady: socketReady,
  authRejected: auth,
  networkLost: net,
  serverStarting: starting,
  restReachable: rest,
).kind;

void main() {
  socketTests();
  test('priority: auth > no network > starting > no server > reconnecting', () {
    expect(
      _derive(auth: true, net: true, starting: true, rest: false),
      ConnectionStatusKind.authRequired,
    );
    expect(
      _derive(net: true, starting: true, rest: false),
      ConnectionStatusKind.noNetwork,
    );
    expect(_derive(starting: true, rest: false), ConnectionStatusKind.starting);
    expect(_derive(rest: false), ConnectionStatusKind.noServer);
    expect(_derive(), ConnectionStatusKind.reconnecting);
    expect(
      _derive(socketReady: true, starting: true),
      ConnectionStatusKind.connected,
    );
  });

  test(
    'registry: a socket that saw 503 says starting, ready says connected',
    () {
      final registry = ConnectionStatusRegistry(
        clock: () => DateTime.utc(2026, 10, 18),
      );
      final link = _StartingLink();
      registry.bind('c', link);
      expect(registry.current('c')?.kind, ConnectionStatusKind.starting);
      registry.reportRest('c', reachable: false);
      expect(registry.current('c')?.kind, ConnectionStatusKind.starting);
      link.change(() => link.linkServerStarting = false);
      expect(registry.current('c')?.kind, ConnectionStatusKind.noServer);
      link.change(() => link.linkServerStarting = true);
      link.change(() => link.linkAuthRejected = true);
      expect(registry.current('c')?.kind, ConnectionStatusKind.authRequired);
      link.change(() {
        link.linkAuthRejected = false;
        link.isConnected = true;
      });
      expect(registry.current('c')?.kind, ConnectionStatusKind.connected);
    },
  );

  test('a plain link without the starting interface never says starting', () {
    final registry = ConnectionStatusRegistry();
    final link = FakeConnectionLink()
      ..linkReconnectAt = DateTime.utc(2026, 10, 18);
    registry.bind('c', link);
    expect(registry.current('c')?.kind, ConnectionStatusKind.reconnecting);
  });
}

// ── The real socket client feeds `starting` (ticket 502/503/504) ───────────

Future<(HttpServer, TuiGatewayClient, List<int>)> _socketRig(
  String id, {
  required List<int> ticketCodes,
  bool simpleConnect = true,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  final served = <int>[];
  server.listen((r) async {
    await utf8.decoder.bind(r).join();
    final code = ticketCodes.isEmpty ? 200 : ticketCodes.removeAt(0);
    served.add(code);
    r.response.statusCode = code;
    r.response.headers.contentType = ContentType.json;
    r.response.write(code == 200 ? '{"ticket":"test-ticket"}' : '{}');
    await r.response.close();
  });
  final conn = SavedConnection(
    id: id,
    label: 'S3',
    host: '127.0.0.1',
    port: 9131,
    apiKey: '',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
    dashboardAuthMode: AuthMode.sessionToken,
  );
  final dashboard = DashboardClient.forConnection(
    conn,
    secrets: const DashboardSecrets(sessionToken: 'test-manual-token'),
    simpleConnectOverride: simpleConnect,
  );
  addTearDown(dashboard.close);
  final client = TuiGatewayClient(
    conn,
    dashboard: dashboard,
    heartbeatInterval: Duration.zero,
  );
  addTearDown(client.close);
  return (server, client, served);
}

void socketTests() {
  for (final code in [502, 503, 504]) {
    test(
      'ticket $code: the socket says starting through the registry',
      () async {
        final (_, client, _) = await _socketRig(
          's3-$code',
          ticketCodes: [code],
        );
        final registry = ConnectionStatusRegistry()..bind('s3-$code', client);
        await expectLater(client.connectForeground(), throwsA(anything));
        expect(client.linkServerStarting, isTrue);
        expect(client.linkAuthRejected, isFalse);
        expect(
          registry.current('s3-$code')?.kind,
          ConnectionStatusKind.starting,
        );
      },
    );
  }

  test('ticket 401 / 403 / 500 never say starting', () async {
    for (final code in [401, 403, 500]) {
      final (_, client, _) = await _socketRig('s3-n$code', ticketCodes: [code]);
      await expectLater(client.connectForeground(), throwsA(anything));
      expect(client.linkServerStarting, isFalse, reason: 'HTTP $code');
    }
  });

  test('a healthy ticket clears starting', () async {
    final (_, client, served) = await _socketRig(
      's3-clear',
      ticketCodes: [503, 200],
    );
    await expectLater(client.connectForeground(), throwsA(anything));
    expect(client.linkServerStarting, isTrue);
    // The next ticket is issued (the upgrade then fails: not a websocket).
    await expectLater(client.connectForeground(), throwsA(anything));
    expect(served.take(2), [503, 200]);
    expect(client.linkServerStarting, isFalse);
  });

  test(
    'with the simple-connect flag off the socket never says starting',
    () async {
      final (_, client, _) = await _socketRig(
        's3-off',
        ticketCodes: [503],
        simpleConnect: false,
      );
      await expectLater(client.connectForeground(), throwsA(anything));
      expect(client.linkServerStarting, isFalse);
    },
  );
}
