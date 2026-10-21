// SPDX-License-Identifier: GPL-3.0-only
// C2b: the native browser flow keeps access + refresh in one v2 envelope and
// never the typed password. Synthetic fixtures only (`test-rt-<n>`).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/services/app_error_log.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _password = 'test-pw-C2B-never-sent-by-console';
const _access = 'test-at-1';
const _refresh = 'test-rt-1';

/// Dashboard stand-in: `/auth/native/authorize` sends the browser to `/login`
/// (what the official `basic` provider does); the simulated browser posts the
/// password there. Requests without `x-sim-browser` come from Console.
class _Dashboard {
  _Dashboard({this.provider = 'basic', this.includeRefresh = true});
  final String provider;
  bool includeRefresh;
  late HttpServer server;
  String get base => 'http://127.0.0.1:${server.port}';
  final consoleRequests = <String>[]; // method path query body
  final pending = <String, Map<String, String>>{};
  String? challenge, redirect, state;
  final verifiers = <String>[]; // code_verifier values seen at the exchange

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      final body = await utf8.decoder.bind(r).join();
      final fromBrowser = r.headers.value('x-sim-browser') == '1';
      if (!fromBrowser) {
        consoleRequests.add('${r.method} ${r.uri} $body');
      }
      Future<void> json(int code, Object o) async {
        r.response.statusCode = code;
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode(o));
        await r.response.close();
      }

      if (r.uri.path == '/api/status') {
        await json(200, {
          'auth_required': true,
          'auth_flows': ['native_pkce'],
        });
      } else if (r.uri.path == '/api/auth/providers') {
        await json(200, {
          'providers': [
            {'name': provider, 'supports_password': provider == 'basic'},
          ],
        });
      } else if (r.uri.path == '/auth/native/authorize') {
        challenge = r.uri.queryParameters['code_challenge'];
        redirect = r.uri.queryParameters['redirect_uri'];
        state = r.uri.queryParameters['state'];
        r.response.statusCode = 302;
        r.response.headers.set('location', '/login');
        await r.response.close();
      } else if (r.uri.path == '/login' && r.method == 'POST') {
        expect(
          fromBrowser,
          isTrue,
          reason: 'only the browser types a password',
        );
        expect(body, contains(_password));
        r.response.statusCode = 302;
        r.response.headers.set(
          'location',
          '$redirect?code=test-code-1&state=$state',
        );
        await r.response.close();
      } else if (r.uri.path == '/auth/native/token') {
        final b = jsonDecode(body) as Map;
        verifiers.add(b['code_verifier'] as String);
        final ok =
            b['code'] == 'test-code-1' &&
            base64UrlEncode(
                  sha256
                      .convert(ascii.encode(b['code_verifier'] as String))
                      .bytes,
                ).replaceAll('=', '') ==
                challenge;
        if (!ok) return json(400, {'error': 'invalid_grant'});
        await json(200, {
          'token_type': 'Bearer',
          'access_token': _access,
          if (includeRefresh) 'refresh_token': _refresh,
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
          'provider': provider,
          'user_id': 'u1',
        });
      } else if (r.uri.path == '/api/auth/me') {
        if (r.headers.value('authorization') != 'Bearer $_access') {
          return json(401, {'error': 'unauthorized'});
        }
        await json(200, {'provider': provider, 'user_id': 'u1'});
      } else {
        await json(404, {});
      }
    });
  }

  /// The system browser: follows the redirect to /login, types the password,
  /// then follows the redirect to Console's loopback callback.
  Future<bool> browser(Uri authorize) async {
    final c = HttpClient();
    try {
      Future<HttpClientResponse> send(
        String method,
        Uri u, [
        String? body,
      ]) async {
        final req = await c.openUrl(method, u);
        req.followRedirects = false;
        req.headers.set('x-sim-browser', '1');
        if (body != null) req.write(body);
        final res = await req.close();
        await res.drain<void>();
        return res;
      }

      final first = await send('GET', authorize);
      final login = Uri.parse(base).resolve(first.headers.value('location')!);
      final posted = await send('POST', login, 'password=$_password');
      await send('GET', Uri.parse(posted.headers.value('location')!));
      return true;
    } finally {
      c.close(force: true);
    }
  }
}

class _Secure {
  final storage = <String, String>{};
  bool failTokenWrite = false;
  bool dropTokenWrite = false; // acknowledges but never persists (apply())
  void install() {
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          final key = args['key'] as String?;
          switch (call.method) {
            case 'write':
              if (failTokenWrite && key!.startsWith('dash_token_')) {
                throw PlatformException(code: 'write-failed');
              }
              if (dropTokenWrite && key!.startsWith('dash_token_')) return null;
              storage[key!] = args['value'] as String;
              return null;
            case 'read':
              return storage[key];
            case 'readAll':
              return storage;
            case 'delete':
              storage.remove(key);
              return null;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  }
}

Future<MobileOAuthSession> _login(_Dashboard d, {bool retain = true}) =>
    MobileOAuthLogin(
      openBrowser: d.browser,
      retainRefresh: retain,
    ).run(connectionId: 'c2b', baseUrl: d.base, authorityCurrent: () => true);

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test(
    'basic: v2 envelope with refresh, no password key, no password sent',
    () async {
      final d = _Dashboard();
      await d.start();
      final secure = _Secure()..install();
      final session = await _login(d);
      expect(session.refreshable, isTrue);
      expect(session.refreshToken, _refresh);
      final manager = await _manager();
      await manager.setDashboardSecrets('c2b', sessionToken: session.encode());
      final stored = secure.storage['dash_token_c2b']!;
      final back = MobileOAuthSession.decode(stored, 'c2b', d.base)!;
      expect(back.refreshToken, _refresh);
      expect(back.accessToken, _access);
      expect(back.rev, 0);
      expect(
        secure.storage.keys.where((k) => k.startsWith('dash_pass_')),
        isEmpty,
      );
      expect(
        secure.storage.keys.where((k) => k.startsWith('dash_user_')),
        isEmpty,
      );
      expect(d.consoleRequests, isNotEmpty);
      for (final line in d.consoleRequests) {
        expect(line, isNot(contains(_password)));
      }
    },
  );

  test(
    'nous: refresh kept; a missing refresh is a login error, no half session',
    () async {
      final ok = _Dashboard(provider: 'nous');
      await ok.start();
      final session = await _login(ok);
      expect(session.provider, 'nous');
      expect(session.refreshToken, _refresh);

      final bad = _Dashboard(provider: 'nous', includeRefresh: false);
      await bad.start();
      await expectLater(_login(bad), throwsA(isA<MobileOAuthException>()));
    },
  );

  test(
    'basic without a refresh degrades to a v1 envelope (not refreshable)',
    () async {
      final d = _Dashboard(includeRefresh: false);
      await d.start();
      final session = await _login(d);
      expect(session.refreshable, isFalse);
      expect(session.encode(), isNot(contains('refresh_token')));
      expect(session.encode(), isNot(contains('"v"')));
    },
  );

  test(
    'without simple connect the refresh is not retained (as published)',
    () async {
      final d = _Dashboard(provider: 'nous');
      await d.start();
      final session = await _login(d, retain: false);
      expect(session.refreshable, isFalse);
      expect(session.encode(), isNot(contains(_refresh)));
    },
  );

  test(
    'envelope: v1 fixture decodes, v2 round-trips, malformed v2 is refused',
    () {
      final v1 =
          '${MobileOAuthSession.prefix}${jsonEncode({'connection_id': 'o', 'base_url': 'http://127.0.0.1:9', 'access_token': 'test-at-old', 'expires_at': 4102444800, 'provider': 'basic', 'user_id': 'u'})}';
      final old = MobileOAuthSession.decode(v1, 'o', 'http://127.0.0.1:9')!;
      expect(old.accessToken, 'test-at-old');
      expect(old.refreshable, isFalse);
      expect(old.rev, 0);
      final v2 = MobileOAuthSession(
        connectionId: 'o',
        baseUrl: 'http://127.0.0.1:9',
        accessToken: 'a',
        expiresAt: 4102444800,
        provider: 'basic',
        userId: 'u',
        refreshToken: 'test-rt-2',
        rev: 3,
      );
      final again = MobileOAuthSession.decode(
        v2.encode(),
        'o',
        'http://127.0.0.1:9',
      )!;
      expect((again.refreshToken, again.rev), ('test-rt-2', 3));
      expect(v2.encode(), startsWith(MobileOAuthSession.prefix));
      Map<String, Object?> body() =>
          jsonDecode(v2.encode().substring(MobileOAuthSession.prefix.length))
              as Map<String, Object?>;
      for (final broken in [
        body()..['refresh_token'] = '',
        body()..remove('rev'),
        body()..['v'] = 3,
      ]) {
        expect(
          () => MobileOAuthSession.decode(
            '${MobileOAuthSession.prefix}${jsonEncode(broken)}',
            'o',
            'http://127.0.0.1:9',
          ),
          throwsA(isA<MobileOAuthException>()),
        );
      }
    },
  );

  test(
    'old connection with a saved password: v2 first, password dropped after',
    () async {
      final d = _Dashboard();
      await d.start();
      final secure = _Secure()..install();
      secure.storage['dash_user_c2b'] = 'admin';
      secure.storage['dash_pass_c2b'] = 'test-old-pass';
      final session = await _login(d);
      final manager = await _manager();
      await manager.setDashboardSecrets('c2b', sessionToken: session.encode());
      expect(secure.storage['dash_token_c2b'], session.encode());
      expect(secure.storage.containsKey('dash_user_c2b'), isFalse);
      expect(secure.storage.containsKey('dash_pass_c2b'), isFalse);
    },
  );

  test('a failing v2 write keeps the saved password', () async {
    final d = _Dashboard();
    await d.start();
    final secure = _Secure()..install();
    secure.storage['dash_user_c2b'] = 'admin';
    secure.storage['dash_pass_c2b'] = 'test-old-pass';
    final session = await _login(d);
    final manager = await _manager();
    secure.failTokenWrite = true;
    await expectLater(
      manager.setDashboardSecrets('c2b', sessionToken: session.encode()),
      throwsA(anything),
    );
    expect(secure.storage['dash_user_c2b'], 'admin');
    expect(secure.storage['dash_pass_c2b'], 'test-old-pass');
    expect(secure.storage.containsKey('dash_token_c2b'), isFalse);
  });

  test(
    'a write the storage acknowledged but lost keeps the password',
    () async {
      final d = _Dashboard();
      await d.start();
      final secure = _Secure()..install();
      secure.storage['dash_pass_c2b'] = 'test-old-pass';
      final session = await _login(d);
      final manager = await _manager();
      secure.dropTokenWrite = true;
      await expectLater(
        manager.setDashboardSecrets('c2b', sessionToken: session.encode()),
        throwsA(anything),
      );
      expect(secure.storage['dash_pass_c2b'], 'test-old-pass');
    },
  );

  test('a typed password / manual token save never drops anything', () async {
    final secure = _Secure()..install();
    secure.storage['dash_pass_c2b'] = 'test-old-pass';
    final manager = await _manager();
    await manager.setDashboardSecrets('c2b', sessionToken: 'plain-page-token');
    expect(secure.storage['dash_pass_c2b'], 'test-old-pass');
  });

  test(
    'log capture: no access/refresh/code/verifier/state/password anywhere',
    () async {
      final lines = <String>[];
      final previous = debugPrint;
      debugPrint = (m, {wrapWidth}) {
        if (m != null) lines.add(m);
      };
      addTearDown(() => debugPrint = previous);
      AppErrorLog.resetForTesting();
      final d = _Dashboard(provider: 'nous');
      await d.start();
      final secure = _Secure()..install();
      await runZoned(
        () async {
          final session = await _login(d);
          final manager = await _manager();
          await manager.setDashboardSecrets(
            'c2b',
            sessionToken: session.encode(),
          );
          secure.failTokenWrite = true;
          d.includeRefresh = false;
          try {
            await _login(d);
          } catch (e) {
            lines.add(e.toString());
          }
          try {
            await manager.setDashboardSecrets(
              'c2b',
              sessionToken: session.encode(),
            );
          } catch (e) {
            lines.add(e.toString());
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => lines.add(line),
        ),
      );
      lines.addAll(AppErrorLog.recent.map((e) => e.toString()));
      final canaries = [
        _access,
        _refresh,
        'test-code-1',
        _password,
        if (d.state != null) d.state!,
        if (d.challenge != null) d.challenge!,
        ...d.verifiers, // D3: the verifier is a secret too, not only its hash
      ];
      expect(d.verifiers, isNotEmpty, reason: 'the canary must exist');
      for (final line in lines) {
        for (final canary in canaries) {
          expect(line, isNot(contains(canary)));
        }
      }
    },
  );

  group('screen copy', () {
    Future<void> pump(
      WidgetTester tester,
      Future<bool> Function(Uri) open, {
      String locale = 'en',
    }) async {
      final client = MockClient((r) async {
        if (r.url.path == '/api/status') {
          return http.Response(
            jsonEncode({
              'auth_required': true,
              'auth_flows': ['native_pkce'],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'providers': [
              {'name': 'basic', 'supports_password': true},
            ],
          }),
          200,
        );
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: DashboardSetupScreen(
              browserFirst: true,
              connection: SavedConnection(
                id: 'c2b',
                label: 'Fixture',
                host: '127.0.0.1',
                port: 9131,
                apiKey: 'test-gateway-key',
                dashboardUrl: 'http://127.0.0.1:19119',
              ),
              authorityCurrent: () => true,
              openOAuthBrowser: open,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }, () => client);
    }

    testWidgets('waiting and failed states use the C2b copy', (tester) async {
      final hold = Completer<bool>();
      await pump(tester, (_) => hold.future);
      await tester.tap(find.byKey(const ValueKey('dashboard-oauth-browser')));
      await tester.pump();
      expect(
        find.text(
          'Opening your browser… Come back here once you have signed in.',
        ),
        findsOneWidget,
      );
      hold.complete(false);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Sign-in did not finish. Please try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('OAuth refused'), findsNothing);
    });

    testWidgets('Spanish copy', (tester) async {
      await pump(tester, (_) async => false, locale: 'es');
      await tester.tap(find.byKey(const ValueKey('dashboard-oauth-browser')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('No se completó el inicio de sesión. Vuelve a intentarlo.'),
        findsOneWidget,
      );
    });
  });
}
