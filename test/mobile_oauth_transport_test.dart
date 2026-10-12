// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/rpc_frame_helpers.dart';

class SystemBrowser extends UrlLauncherPlatform {
  SystemBrowser(this.open);
  final Future<bool> Function(Uri) open;
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) {
    expect(options.mode, PreferredLaunchMode.externalApplication);
    expect(options.webViewConfiguration.headers, isEmpty);
    return open(Uri.parse(url));
  }
}

class Broker {
  late HttpServer server;
  String get base => 'http://127.0.0.1:${server.port}';
  final paths = <String>[];
  final verifiers = <String>[];
  final tickets = <String>{};
  final upgrades = <String>[];
  final submits = <Map<String, dynamic>>[];
  String? challenge;
  Completer<void>? hold;
  int tokenStatus = 200;
  String? redirect;
  int minted = 0;
  final exchanged = Completer<void>();
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      paths.add(r.uri.path);
      if (r.uri.path == '/api/ws') {
        final ticket = r.uri.queryParameters['ticket'];
        expect(tickets.remove(ticket), isTrue);
        expect(r.uri.queryParameters.containsKey('token'), isFalse);
        upgrades.add(ticket!);
        final socket = await WebSocketTransformer.upgrade(r);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (isClientCapabilitiesFrame(frame)) continue;
          Map<String, dynamic> reply = {'status': 'ok'};
          if (frame['method'] == 'gateway.capabilities') {
            reply = {'per_session_exclusive_submit': true};
          }
          if (frame['method'] == 'prompt.submit') {
            final params = Map<String, dynamic>.from(frame['params'] as Map);
            submits.add(params);
            reply = {
              'accepted': true,
              'client_turn_id': params['client_turn_id'],
              'server_turn_id': 'synthetic-server-turn-${submits.length}',
              'state': 'accepted',
              'duplicate': false,
            };
          }
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': reply}),
          );
        }
        return;
      }
      if (r.uri.path == '/auth/native/token') {
        final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
        expect(body.keys.toSet(), {'code', 'code_verifier'});
        expect(body['code'], 'synthetic-code');
        final verifier = body['code_verifier'] as String;
        verifiers.add(verifier);
        expect(verifier, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(
          base64UrlEncode(
            sha256.convert(ascii.encode(verifier)).bytes,
          ).replaceAll('=', ''),
          challenge,
        );
        if (!exchanged.isCompleted) exchanged.complete();
        if (hold != null) await hold!.future;
        r.response.statusCode = tokenStatus;
        if (redirect != null) r.response.headers.set('location', redirect!);
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          jsonEncode({
            'token_type': 'Bearer',
            'access_token': 'synthetic-access',
            'refresh_token': 'synthetic-refresh-not-retained',
            'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
            'provider': 'portal',
            'user_id': 'synthetic-user',
          }),
        );
        await r.response.close();
        return;
      }
      expect(r.headers.value('authorization'), 'Bearer synthetic-access');
      expect(r.headers.value('x-hermes-session-token'), isNull);
      expect(r.headers.value('cookie'), isNull);
      if (r.uri.path == '/api/auth/me') {
        r.response.headers.contentType = ContentType.json;
        r.response.write('{"provider":"portal","user_id":"synthetic-user"}');
        await r.response.close();
      } else if (r.uri.path == '/api/auth/ws-ticket') {
        final ticket = 'synthetic-ticket-${++minted}';
        tickets.add(ticket);
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode({'ticket': ticket, 'ttl_seconds': 30}));
        await r.response.close();
      } else {
        r.response.statusCode = 404;
        await r.response.close();
      }
    });
  }

  void capture(Uri url) {
    expect(url.origin, base);
    expect(url.path, '/auth/native/authorize');
    expect(url.queryParameters['code_challenge_method'], 'S256');
    expect(
      url.queryParameters['state'],
      matches(RegExp(r'^[A-Za-z0-9_-]{43}$')),
    );
    expect(url.queryParameters.containsKey('code_verifier'), isFalse);
    challenge = url.queryParameters['code_challenge'];
    final cb = Uri.parse(url.queryParameters['redirect_uri']!);
    expect(cb.scheme, 'http');
    expect(cb.host, '127.0.0.1');
    expect(cb.port, greaterThan(0));
    expect(cb.path, '/callback');
  }
}

Future<int> callback(
  Uri url, {
  String? state,
  String? path,
  String? host,
  bool duplicate = false,
}) async {
  final cb = Uri.parse(url.queryParameters['redirect_uri']!).replace(
    path: path,
    query:
        'code=synthetic-code&state=${state ?? url.queryParameters['state']}${duplicate ? '&state=foreign' : ''}',
  );
  final client = HttpClient();
  try {
    final r = await client.getUrl(cb);
    if (host != null) r.headers.set('host', host);
    final response = await r.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => HttpOverrides.global = null,
  ); // real controlled loopback transport
  test('cancellation settles even while browser launch is held', () async {
    final started = Completer<Uri>();
    final hold = Completer<bool>();
    final login = MobileOAuthLogin(
      openBrowser: (u) {
        started.complete(u);
        return hold.future;
      },
    );
    final pending = login.run(
      connectionId: 'A',
      baseUrl: 'https://dashboard.example',
      authorityCurrent: () => true,
    );
    final expectation = expectLater(
      pending,
      throwsA(isA<MobileOAuthException>()),
    );
    await started.future;
    login.cancel();
    await expectation.timeout(const Duration(seconds: 2));
    hold.complete(true);
  });

  test(
    'real broker PKCE exchange validates session, secure slot and fresh reconnect tickets',
    () async {
      final diagnostics = <String>[];
      final previousDebug = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) diagnostics.add(message);
      };
      addTearDown(() => debugPrint = previousDebug);
      await runZoned(
        () async {
          Zone.current.print('synthetic-detector-print');
          debugPrint('synthetic-detector-debug');
          expect(
            diagnostics,
            containsAll([
              'synthetic-detector-print',
              'synthetic-detector-debug',
            ]),
          );
          diagnostics.clear();
          final broker = Broker();
          await broker.start();
          final originalLauncher = UrlLauncherPlatform.instance;
          addTearDown(() => UrlLauncherPlatform.instance = originalLauncher);
          UrlLauncherPlatform.instance = SystemBrowser((u) async {
            broker.capture(u);
            expect(await callback(u), 200);
            return true;
          });
          final login = MobileOAuthLogin();
          final session = await login.run(
            connectionId: 'A',
            baseUrl: broker.base,
            authorityCurrent: () => true,
          );
          expect(broker.verifiers, hasLength(1));
          expect(broker.paths, ['/auth/native/token', '/api/auth/me']);
          final storage = <String, String>{};
          final durableWrites = <String>[];
          const channel = MethodChannel(
            'plugins.it_nomads.com/flutter_secure_storage',
          );
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                final args = call.arguments as Map;
                final key = args['key'] as String?;
                if (call.method == 'write') {
                  durableWrites.add(args['value'] as String);
                  storage[key!] = args['value'] as String;
                  return null;
                }
                if (call.method == 'read') return storage[key];
                if (call.method == 'readAll') return storage;
                return null;
              });
          addTearDown(
            () => TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final secure = SecureStorage();
          await secure.writeDashboardSecret('A', 'token', session.encode());
          expect(
            await secure.readDashboardSecret('A', 'token'),
            session.encode(),
          );
          expect(await secure.readDashboardSecret('B', 'token'), isNull);
          expect(prefs.getKeys(), isEmpty);
          expect(
            session.encode(),
            isNot(contains('synthetic-refresh-not-retained')),
          );
          expect(session.encode(), isNot(contains(broker.verifiers.single)));
          final conn = SavedConnection(
            id: 'A',
            label: 'Existing',
            host: '127.0.0.1',
            port: 9131,
            apiKey: 'synthetic-gateway',
            dashboardUrl: broker.base,
            dashboardAuthMode: AuthMode.sessionToken,
          );
          final dashboard = DashboardClient.lazy(conn);
          addTearDown(dashboard.close);
          final gateway = TuiGatewayClient(conn, dashboard: dashboard);
          addTearDown(gateway.close);
          final first = await gateway.submitPromptIdempotent(
            'owned-runtime',
            'synthetic first',
            'synthetic-turn-1',
          );
          expect(first.accepted, isTrue);
          await gateway.disconnectIdle();
          final second = await gateway.submitPromptIdempotent(
            'owned-runtime',
            'synthetic second',
            'synthetic-turn-2',
          );
          expect(second.accepted, isTrue);
          expect(broker.upgrades.toSet(), hasLength(2));
          expect(broker.tickets, isEmpty);
          expect(
            broker.submits.map((p) => p['session_id']),
            everyElement('owned-runtime'),
          );
          expect(broker.minted, 2);
          expect(conn.apiKey, 'synthetic-gateway');
          final secretCanaries = [
            'synthetic-access',
            'synthetic-refresh-not-retained',
            'synthetic-code',
            ...broker.verifiers,
            ...broker.upgrades,
          ];
          expect(
            diagnostics.any((line) => secretCanaries.any(line.contains)),
            isFalse,
            reason: 'native secrets must not enter print or debugPrint',
          );
          expect(
            durableWrites.any((value) => broker.upgrades.any(value.contains)),
            isFalse,
            reason: 'one-use tickets must never enter even encrypted storage',
          );
          expect(
            prefs.getKeys().any(
              (k) => secretCanaries.any('${prefs.get(k)}'.contains),
            ),
            isFalse,
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => diagnostics.add(line),
        ),
      );
    },
  );

  for (final scenario in [
    'foreign-state',
    'wrong-path',
    'wrong-host',
    'duplicate-state',
  ]) {
    test(
      '$scenario rejected before exchange; valid callback still works',
      () async {
        final broker = Broker();
        await broker.start();
        final login = MobileOAuthLogin(
          openBrowser: (u) async {
            broker.capture(u);
            expect(
              await callback(
                u,
                state: scenario == 'foreign-state' ? 'foreign' : null,
                path: scenario == 'wrong-path' ? '/other' : null,
                host: scenario == 'wrong-host' ? 'foreign.example' : null,
                duplicate: scenario == 'duplicate-state',
              ),
              400,
            );
            expect(broker.verifiers, isEmpty);
            expect(await callback(u), 200);
            return true;
          },
        );
        await login.run(
          connectionId: 'A',
          baseUrl: broker.base,
          authorityCurrent: () => true,
        );
        expect(broker.verifiers, hasLength(1));
      },
    );
  }

  for (final scenario in ['cancel', 'profile-ABA', 'expiry']) {
    test(
      '$scenario while token exchange held cannot publish a session',
      () async {
        final broker = Broker();
        await broker.start();
        broker.hold = Completer<void>();
        var epoch = 0;
        var now = DateTime.now();
        final login = MobileOAuthLogin(
          now: () => now,
          openBrowser: (u) async {
            broker.capture(u);
            expect(await callback(u), 200);
            return true;
          },
        );
        final pending = login.run(
          connectionId: 'A',
          baseUrl: broker.base,
          authorityCurrent: () => epoch == 0,
        );
        final expectation = expectLater(
          pending,
          throwsA(isA<MobileOAuthException>()),
        );
        await broker.exchanged.future;
        if (scenario == 'cancel') login.cancel();
        if (scenario == 'profile-ABA') {
          epoch++;
          epoch++;
        }
        if (scenario == 'expiry') now = now.add(const Duration(minutes: 6));
        await expectation.timeout(const Duration(seconds: 2));
        broker.hold!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(broker.paths, ['/auth/native/token']);
      },
    );
  }

  test('replayed concurrent callback exchanges exactly once', () async {
    final broker = Broker();
    await broker.start();
    broker.hold = Completer<void>();
    final login = MobileOAuthLogin(
      openBrowser: (u) async {
        broker.capture(u);
        expect(await callback(u), 200);
        await broker.exchanged.future;
        expect(await callback(u), 400);
        expect(broker.verifiers, hasLength(1));
        broker.hold!.complete();
        return true;
      },
    );
    await login.run(
      connectionId: 'A',
      baseUrl: broker.base,
      authorityCurrent: () => true,
    );
    expect(broker.verifiers, hasLength(1));
  });

  test('token redirect never forwards code or verifier', () async {
    final broker = Broker();
    await broker.start();
    final foreign = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => foreign.close(force: true));
    var leaked = 0;
    foreign.listen((r) async {
      leaked++;
      await r.response.close();
    });
    broker.tokenStatus = 307;
    broker.redirect = 'http://127.0.0.1:${foreign.port}/capture';
    final login = MobileOAuthLogin(
      openBrowser: (u) async {
        broker.capture(u);
        await callback(u);
        return true;
      },
    );
    await expectLater(
      login.run(
        connectionId: 'A',
        baseUrl: broker.base,
        authorityCurrent: () => true,
      ),
      throwsA(isA<MobileOAuthException>()),
    );
    expect(leaked, 0);
  });

  test(
    'native token headers and body share the 15 second request deadline',
    () async {
      final broker = Broker();
      await broker.start();
      broker.hold = Completer<void>();
      addTearDown(() {
        if (!broker.hold!.isCompleted) broker.hold!.complete();
      });
      final login = MobileOAuthLogin(
        openBrowser: (u) async {
          broker.capture(u);
          await callback(u);
          return true;
        },
      );
      final pending = login.run(
        connectionId: 'A',
        baseUrl: broker.base,
        authorityCurrent: () => true,
      );
      addTearDown(login.cancel);
      await expectLater(
        pending,
        throwsA(isA<MobileOAuthException>()),
      ).timeout(const Duration(seconds: 17));
      expect(broker.paths, ['/auth/native/token']);
    },
  );

  test(
    'private HTTP has zero launch or exchange without explicit consent',
    () async {
      var launches = 0;
      final login = MobileOAuthLogin(
        openBrowser: (_) async {
          launches++;
          return true;
        },
      );
      await expectLater(
        login.run(
          connectionId: 'A',
          baseUrl: 'http://10.0.0.2:9119',
          authorityCurrent: () => true,
        ),
        throwsA(isA<MobileOAuthException>()),
      );
      expect(launches, 0);
    },
  );

  for (final mismatch in ['owner', 'origin', 'expired']) {
    test(
      'secure token $mismatch binding rejects before authenticated request',
      () async {
        final broker = Broker();
        await broker.start();
        final session = MobileOAuthSession(
          connectionId: mismatch == 'owner' ? 'B' : 'A',
          baseUrl: mismatch == 'origin'
              ? 'https://foreign.example'
              : broker.base,
          accessToken: 'synthetic-access',
          expiresAt: mismatch == 'expired'
              ? 1
              : DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
          provider: 'portal',
          userId: 'synthetic-user',
        );
        final conn = SavedConnection(
          id: 'A',
          label: 'Existing',
          host: '127.0.0.1',
          port: 9131,
          apiKey: '',
          dashboardUrl: broker.base,
          dashboardAuthMode: AuthMode.sessionToken,
        );
        final client = DashboardClient.forConnection(
          conn,
          secrets: DashboardSecrets(sessionToken: session.encode()),
        );
        addTearDown(client.close);
        await expectLater(
          client.apiGet('auth/me'),
          throwsA(isA<MobileOAuthException>()),
        );
        expect(broker.paths, isEmpty);
      },
    );
  }
}
