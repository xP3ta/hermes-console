// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/dashboard_address.dart';
import 'package:hermes_android/core/services/simple_connect/hermes_server_status.dart';

/// Direct coverage of what Connect manually keeps from the retired network
/// search: the address parser, the status parser, the TCP gate and the
/// typed-address probe (they lost their unit tests with the search, ONB4).

const _fixturePath = 'test/fixtures/simple_connect/status_dashboard_basic.json';

Map<String, dynamic> _fixture() =>
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;

Future<TcpOutcome> Function(String, int, Duration) _net(
  Map<int, TcpOutcome> ports,
) =>
    (host, port, timeout) async => ports[port] ?? TcpOutcome.silent;

void main() {
  group('parseDashboardAddress', () {
    test('a bare host gets http and the Dashboard port', () {
      final t = parseDashboardAddress('  192.168.1.20  ')!;
      expect(t.host, '192.168.1.20');
      expect(t.port, 9119);
      expect(t.secure, isFalse);
      expect(t.route, DiscoveryRoute.typed);
      expect(t.url, 'http://192.168.1.20:9119');
    });

    test('a typed port wins', () {
      final t = parseDashboardAddress('mi-pc.local:8080')!;
      expect(t.host, 'mi-pc.local');
      expect(t.port, 8080);
      expect(t.secure, isFalse);
    });

    test('https defaults to 443, http:// keeps 9119', () {
      final s = parseDashboardAddress('https://hermes.example.org')!;
      expect(s.secure, isTrue);
      expect(s.port, 443);
      final h = parseDashboardAddress('http://10.0.0.5')!;
      expect(h.secure, isFalse);
      expect(h.port, 9119);
      expect(
        parseDashboardAddress('https://hermes.example.org:8443')!.port,
        8443,
      );
    });

    test('Tailscale addresses and names are routed as Tailscale', () {
      for (final raw in ['100.88.1.2', 'my-pc.tail1234.ts.net', '100.64.0.1']) {
        expect(
          parseDashboardAddress(raw)!.route,
          DiscoveryRoute.tailscale,
          reason: raw,
        );
      }
      for (final raw in ['100.63.255.255', '100.128.0.1', '192.168.1.2']) {
        expect(
          parseDashboardAddress(raw)!.route,
          DiscoveryRoute.typed,
          reason: raw,
        );
      }
    });

    test('empty or hostless input is not an address', () {
      expect(parseDashboardAddress(''), isNull);
      expect(parseDashboardAddress('   '), isNull);
      expect(parseDashboardAddress('http://'), isNull);
      expect(parseDashboardAddress('https://:9119'), isNull);
    });

    test(
      'plain http to a public host is flagged, private and https are not',
      () {
        expect(parseDashboardAddress('203.0.113.9')!.publicCleartext, isTrue);
        expect(
          parseDashboardAddress('https://203.0.113.9')!.publicCleartext,
          isFalse,
        );
        expect(parseDashboardAddress('192.168.1.20')!.publicCleartext, isFalse);
        expect(parseDashboardAddress('100.88.1.2')!.publicCleartext, isFalse);
      },
    );
  });

  group('HermesServerStatus', () {
    test('parses the public status of a Dashboard with password login', () {
      final s = HermesServerStatus.tryParse(_fixture())!;
      expect(s.version, '0.21.6');
      expect(s.installId, '0123456789abcdef0123456789abcdef');
      expect(s.authRequired, isTrue);
      expect(s.passwordSignIn, isTrue);
      expect(s.nativeSignIn, isTrue);
    });

    test('rejects payloads that are not Hermes', () {
      expect(HermesServerStatus.tryParse(null), isNull);
      expect(HermesServerStatus.tryParse({'version': '1'}), isNull);
      expect(HermesServerStatus.tryParse({'auth_required': true}), isNull);
      expect(HermesServerStatus.tryParse('<html>'), isNull);
    });

    test('an old server without the newer fields still parses', () {
      final s = HermesServerStatus.tryParse({
        'version': '0.9.0',
        'auth_required': false,
      })!;
      expect(s.installId, isNull);
      expect(s.authProviders, isEmpty);
      expect(s.nativeSignIn, isFalse);
    });
  });

  group('real sockets on 127.0.0.1', () {
    late HttpServer server;
    late String body;
    late int code;
    var requests = <String>[];

    setUp(() async {
      HttpOverrides.global = null;
      body = jsonEncode(_fixture());
      code = 200;
      requests = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((req) async {
          requests.add('${req.method} ${req.uri.path}');
          req.response.statusCode = code;
          if (code == 302) {
            req.response.headers.set('location', '/elsewhere');
          }
          req.response.write(body);
          await req.response.close();
        }),
      );
    });
    tearDown(() => server.close(force: true));

    test('a closed port is refused, an open one is open', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      expect(
        await tcpConnect('127.0.0.1', port, const Duration(seconds: 2)),
        TcpOutcome.refused,
      );
      expect(
        await tcpConnect('127.0.0.1', server.port, const Duration(seconds: 2)),
        TcpOutcome.open,
      );
    });

    test('Hermes answering /api/status is Hermes', () async {
      final r = await probeHost(
        DiscoveryTarget('127.0.0.1', server.port, DiscoveryRoute.typed),
      );
      expect(r.verdict, HostVerdict.hermes);
      expect(r.status?.version, '0.21.6');
      expect(requests, ['GET /api/status']);
    });

    test('a web server that is not Hermes is not listening', () async {
      body = '<html>router</html>';
      final r = await probeHost(
        DiscoveryTarget('127.0.0.1', server.port, DiscoveryRoute.typed),
      );
      expect(r.verdict, HostVerdict.notListening);
    });

    test('a redirect is not followed', () async {
      code = 302;
      final r = await probeHost(
        DiscoveryTarget('127.0.0.1', server.port, DiscoveryRoute.typed),
      );
      expect(r.verdict, HostVerdict.notListening);
      expect(requests, ['GET /api/status']);
    });
  });

  group('probeHost (typed address)', () {
    const t = DiscoveryTarget('192.168.1.20', 9119, DiscoveryRoute.typed);

    test('Hermes answers', () async {
      final r = await probeHost(
        t,
        tcp: _net({9119: TcpOutcome.open}),
        status: (_) async => HermesServerStatus.tryParse(_fixture()),
      );
      expect(r.verdict, HostVerdict.hermes);
      expect(r.status, isNotNull);
    });

    test('port refused → the Dashboard is not listening', () async {
      final r = await probeHost(t, tcp: _net({9119: TcpOutcome.refused}));
      expect(r.verdict, HostVerdict.notListening);
    });

    test('open port that is not Hermes → not listening', () async {
      final r = await probeHost(
        t,
        tcp: _net({9119: TcpOutcome.open}),
        status: (_) async => null,
      );
      expect(r.verdict, HostVerdict.notListening);
    });

    test(
      'firewall drops the Dashboard port, another port answers → blocked',
      () async {
        for (final port in [22, 445, 3389, 80]) {
          final r = await probeHost(t, tcp: _net({port: TcpOutcome.open}));
          expect(r.verdict, HostVerdict.blocked, reason: 'port $port');
        }
      },
    );

    test('a refusing neighbour port also proves the computer is up', () async {
      final r = await probeHost(t, tcp: _net({445: TcpOutcome.refused}));
      expect(r.verdict, HostVerdict.blocked);
    });

    test('nothing answers at all → silent', () async {
      final r = await probeHost(t, tcp: _net({}));
      expect(r.verdict, HostVerdict.silent);
    });

    test('public http is blocked before any packet leaves', () async {
      var connects = 0;
      final r = await probeHost(
        const DiscoveryTarget('203.0.113.9', 9119, DiscoveryRoute.typed),
        tcp: (h, p, d) async {
          connects++;
          return TcpOutcome.open;
        },
        status: (_) async {
          connects++;
          return null;
        },
      );
      expect(r.verdict, HostVerdict.publicCleartext);
      expect(connects, 0);
    });

    test('a public name over https is allowed through', () async {
      final r = await probeHost(
        const DiscoveryTarget(
          'hermes.example.org',
          443,
          DiscoveryRoute.typed,
          secure: true,
        ),
        tcp: _net({443: TcpOutcome.open}),
        status: (_) async => HermesServerStatus.tryParse(_fixture()),
      );
      expect(r.verdict, HostVerdict.hermes);
    });

    test('Tailscale and loopback are private, not blocked', () async {
      for (final host in ['100.88.1.2', 'my-pc.tail1234.ts.net', '127.0.0.1']) {
        final r = await probeHost(
          DiscoveryTarget(host, 9119, DiscoveryRoute.typed),
          tcp: _net({9119: TcpOutcome.refused}),
        );
        expect(r.verdict, HostVerdict.notListening, reason: host);
      }
    });
  });
}
