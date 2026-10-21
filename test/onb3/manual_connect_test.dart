// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/screens/recover_access_page.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../onb2q/hermes_shaped_server.dart';
import '../support/onboarding_fakes.dart';

/// A real Hermes-shaped Dashboard: the sign-in routes of the shared fixture
/// plus `/api/status`, both on one 127.0.0.1 port (every other request is
/// forwarded over a real socket).
class _Front {
  _Front(this._server, this._back);
  final HttpServer _server;
  final HermesShapedServer _back;
  final requests = <String>[];

  static Future<_Front> start(HermesShapedServer back) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final f = _Front(s, back);
    unawaited(f._serve());
    return f;
  }

  String get url => 'http://127.0.0.1:${_server.port}';
  Future<void> close() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final req in _server) {
      requests.add('${req.method} ${req.uri.path}');
      if (req.uri.path == '/api/status') {
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'version': '9.9.9',
              'auth_required': true,
              'auth_providers': ['basic'],
              'auth_flows': ['native_pkce'],
            }),
          );
        await req.response.close();
        continue;
      }
      final client = HttpClient()..autoUncompress = false;
      try {
        final target = Uri.parse(_back.url).replace(
          path: req.uri.path,
          query: req.uri.hasQuery ? req.uri.query : null,
        );
        final out = await client.openUrl(req.method, target);
        out.followRedirects = false;
        req.headers.forEach((n, v) {
          if (n != 'host' && n != 'content-length') {
            for (final x in v) {
              out.headers.add(n, x);
            }
          }
        });
        final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
        out.add(body);
        final res = await out.close();
        req.response.statusCode = res.statusCode;
        res.headers.forEach((n, v) {
          if (n != 'transfer-encoding' && n != 'content-length') {
            for (final x in v) {
              // Absolute redirects must point at this front, not the back.
              req.response.headers.add(n, x.replaceAll(_back.url, url));
            }
          }
        });
        await req.response.addStream(res);
      } catch (_) {
        req.response.statusCode = 502;
      } finally {
        client.close(force: true);
      }
      await req.response.close();
    }
  }
}

Future<ConnectionManager> _open(WidgetTester tester) async {
  final manager = await onboardingManager();
  await tester.pumpWidget(
    onboardingHost(
      OnboardingScreen(
        simpleConnectEnabled: true,
        cameraBuilder: (detect, _) => const SizedBox(),
        connManager: manager,
        playOpening: false,
        onDone: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _tap(tester, 'onboarding-manual');
  return manager;
}

Strings _strings(WidgetTester tester) =>
    Strings.of(tester.element(find.byKey(const ValueKey('manual-address'))));

Future<void> _tap(WidgetTester tester, String key) async {
  final control = find.byKey(ValueKey(key));
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
}

/// Real socket round trips (and the 600 ms debounce) need real time.
Future<void> _wait(WidgetTester tester, {int ms = 2000}) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _fill(
  WidgetTester tester,
  String address, {
  String user = HermesShapedServer.user,
  String pass = HermesShapedServer.pass,
}) async {
  await _type(tester, 'manual-address', address);
  await _type(tester, 'manual-user', user);
  await _type(tester, 'manual-password', pass);
}

Future<String> _everythingPersisted(ConnectionManager manager) async {
  final prefs = await SharedPreferences.getInstance();
  final b = StringBuffer();
  for (final k in prefs.getKeys()) {
    b.write('$k=${prefs.get(k)};');
  }
  for (final c in manager.getConnections()) {
    final s = await manager.getDashboardSecrets(c.id);
    b.write('pw=${s.password};user=${s.username};tok=${s.sessionToken};');
  }
  return b.toString();
}

void main() {
  late HermesShapedServer back;
  late _Front server;
  setUp(() async {
    HttpOverrides.global = null;
    back = await HermesShapedServer.start();
    server = await _Front.start(back);
  });
  tearDown(() async {
    await server.close();
    await back.close();
  });

  testWidgets('Connect by hand opens the simple form, not the editor', (
    tester,
  ) async {
    await _open(tester);
    expect(find.byKey(const ValueKey('manual-address')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-user')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-password')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-connect')), findsOneWidget);
    expect(find.byType(InstanceEditScreen), findsNothing);
  });

  testWidgets('full form: signs in natively, saves Dashboard alone, the '
      'password is never stored', (tester) async {
    final manager = await _open(tester);
    await _fill(tester, server.url);
    await _wait(tester);
    expect(find.byKey(const ValueKey('manual-status')), findsOneWidget);
    expect(find.textContaining('9.9.9'), findsNothing);
    await _tap(tester, 'manual-connect');
    await _wait(tester, ms: 3000);
    await tester.pump(const Duration(seconds: 2));
    expect(back.requests, contains('POST /auth/password-login'));
    final saved = manager.getConnections().single;
    expect(saved.apiKey, isEmpty);
    expect(saved.effectiveDashboardUrl, server.url);
    expect(manager.activeConnectionId.value, saved.id);
    final secrets = await manager.getDashboardSecrets(saved.id);
    expect(secrets.sessionToken, isNotEmpty);
    expect(secrets.password, isNull);
    expect(await _everythingPersisted(manager), isNot(contains('CANARY')));
    expect(find.byKey(const ValueKey('manual-address')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typing the address shows the check, then «found»', (
    tester,
  ) async {
    await _open(tester);
    await _type(tester, 'manual-address', server.url);
    final s = _strings(tester);
    expect(find.text(s.onb3Checking), findsOneWidget);
    await _wait(tester);
    expect(find.text('✓ ${s.onb3Found}'), findsOneWidget);
    expect(server.requests, contains('GET /api/status'));
  });

  testWidgets('wrong password: one sentence and the way to recover access', (
    tester,
  ) async {
    final manager = await _open(tester);
    await _fill(tester, server.url, pass: 'not-the-password');
    await _tap(tester, 'manual-connect');
    await _wait(tester, ms: 3000);
    final s = _strings(tester);
    expect(find.text(s.onb2WrongPassword), findsOneWidget);
    expect(manager.getConnections(), isEmpty);
    await _tap(tester, 'onb3-recover');
    expect(find.byType(RecoverAccessPage), findsOneWidget);
  });

  testWidgets('unreachable address: «I can\'t reach it»', (tester) async {
    // A port that was open a moment ago and now refuses.
    final url = await tester.runAsync(() async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final address = 'http://127.0.0.1:${dead.port}';
      await dead.close(force: true);
      return address;
    });
    await _open(tester);
    await _type(tester, 'manual-address', url!);
    await _wait(tester);
    final s = _strings(tester);
    expect(find.text(s.onb3Unreachable), findsOneWidget);
    expect(find.text('✓ ${s.onb3Found}'), findsNothing);
  });

  testWidgets('http to a public host sends nothing at all', (tester) async {
    await _open(tester);
    var sockets = 0;
    final counter = _CountingOverrides();
    await IOOverrides.runZoned(
      () => HttpOverrides.runZoned(() async {
        await _fill(tester, 'http://example.com');
        await _wait(tester);
        final s = _strings(tester);
        expect(find.text(s.commonCleartextPublic), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('manual-connect')));
        await _wait(tester, ms: 500);
      }, createHttpClient: (c) => counter.createHttpClient(c)),
      socketConnect: (host, port, {sourceAddress, sourcePort = 0, timeout}) {
        sockets++;
        throw const SocketException('blocked by the test');
      },
    );
    expect(counter.requests, 0);
    expect(sockets, 0);
  });

  testWidgets('http on a private network needs the checkbox, https never', (
    tester,
  ) async {
    final manager = await _open(tester);
    await _fill(tester, 'http://192.168.1.20:9119');
    final connect = find.byKey(const ValueKey('manual-connect'));
    expect(find.byKey(const ValueKey('manual-consent')), findsOneWidget);
    expect(tester.widget<OnbPrimary>(connect).onTap, isNull);
    await tester.tap(connect);
    await _wait(tester, ms: 500);
    // Nothing was tried: still on the form, nothing saved.
    expect(find.byKey(const ValueKey('manual-address')), findsOneWidget);
    expect(manager.getConnections(), isEmpty);
    await tester.tap(find.byKey(const ValueKey('manual-consent')));
    await tester.pump();
    expect(tester.widget<OnbPrimary>(connect).onTap, isNotNull);

    await _type(tester, 'manual-address', 'https://mi-servidor.example');
    expect(find.byKey(const ValueKey('manual-consent')), findsNothing);
    expect(tester.widget<OnbPrimary>(connect).onTap, isNotNull);
  });

  testWidgets('«I don\'t know these» opens the help page', (tester) async {
    await _open(tester);
    await _tap(tester, 'manual-dont-know');
    expect(find.byKey(const ValueKey('manual-address')), findsNothing);
    expect(
      find.byKey(const ValueKey('onboarding-help-manual')),
      findsOneWidget,
    );
    expect(find.byType(DashboardSetupScreen), findsNothing);
  });
}

class _CountingOverrides extends HttpOverrides {
  int requests = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Counting(this);
}

class _Counting extends Fake implements HttpClient {
  _Counting(this._owner);
  final _CountingOverrides _owner;
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter || invocation.isGetter) return null;
    _owner.requests++;
    throw const SocketException('blocked by the test');
  }
}
