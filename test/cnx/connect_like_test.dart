// SPDX-License-Identifier: GPL-3.0-only
// The Connect screen: Direct and SSH, three ways to sign in, a Connect that
// waits for what it needs, and the QR entry that stays.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dashboard_address.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../onb2q/hermes_shaped_server.dart';
import '../support/onboarding_fakes.dart';

const _address = 'http://127.0.0.1:19119';

Future<HostProbeResult> _found(DiscoveryTarget _) async =>
    const HostProbeResult(HostVerdict.hermes);

Future<ConnectionManager> _open(
  WidgetTester tester, {
  Future<bool> Function(Uri)? browser,
  String language = 'en',
}) async {
  final manager = await onboardingManager();
  await tester.pumpWidget(
    onboardingHost(
      OnboardingScreen(
        simpleConnectEnabled: true,
        cameraBuilder: (detect, _) => const SizedBox(),
        connManager: manager,
        playOpening: false,
        probe: _found,
        openOAuthBrowser: browser,
        onDone: () {},
      ),
      language: language,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('onboarding-manual')));
  await tester.pumpAndSettle();
  return manager;
}

Strings _s(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(ManualConnectPage)));

Future<void> _tap(WidgetTester tester, String key) async {
  final control = find.byKey(ValueKey(key));
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
}

Future<void> _method(WidgetTester tester, String option) async {
  await _tap(tester, 'cnx-method');
  await tester.tap(find.byKey(ValueKey('cnx-method-$option')));
  await tester.pumpAndSettle();
}

VoidCallback? _connectTap(WidgetTester tester) => tester
    .widget<OnbPrimary>(find.byKey(const ValueKey('manual-connect')))
    .onTap;

Future<void> _wait(WidgetTester tester, {int ms = 2000}) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// A Dashboard that accepts exactly one session token on `/api/profiles`.
Future<HttpServer> _tokenServer(String good) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final req in server) {
      final ok =
          req.uri.path == '/api/profiles' &&
          req.headers.value('X-Hermes-Session-Token') == good;
      req.response
        ..statusCode = ok ? 200 : 401
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(ok ? {'profiles': <Object>[]} : {'error': 'no'}));
      await req.response.close();
    }
  }());
  return server;
}

/// The native broker's two routes the Browser sign-in needs after the
/// callback: the one-use token exchange and the identity read.
Future<HttpServer> _brokerServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final req in server) {
      await utf8.decoder.bind(req).join();
      Object body = <String, Object>{};
      if (req.uri.path == '/auth/native/token') {
        body = {
          'access_token': 'synthetic-access',
          'token_type': 'Bearer',
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
          'provider': 'basic',
          'user_id': 'synthetic-user',
        };
      } else if (req.uri.path == '/api/auth/me') {
        body = {'provider': 'basic', 'user_id': 'synthetic-user'};
      } else {
        req.response.statusCode = 404;
      }
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await req.response.close();
    }
  }());
  return server;
}

void main() {
  setUp(() => HttpOverrides.global = null);

  testWidgets('Direct is the first tab; SSH has its own fields and keeps '
      'Connect off', (tester) async {
    await _open(tester);
    expect(find.byKey(const ValueKey('manual-address')), findsOneWidget);
    expect(find.byKey(const ValueKey('cnx-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('cnx-ssh-host')), findsNothing);

    await _tap(tester, 'cnx-tab-ssh');
    expect(find.byKey(const ValueKey('manual-address')), findsNothing);
    for (final k in ['cnx-ssh-host', 'cnx-ssh-user', 'cnx-ssh-password']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    String text(String k) =>
        tester.widget<TextField>(find.byKey(ValueKey(k))).controller!.text;
    expect(text('cnx-ssh-port'), '22');
    expect(text('cnx-dash-host'), '127.0.0.1');
    expect(text('cnx-dash-port'), '9119');
    // The tunnel is real now: no "not available yet" line.
    expect(find.byKey(const ValueKey('cnx-ssh-soon')), findsNothing);
    await _type(tester, 'cnx-ssh-host', 'srv.example.com');
    await _type(tester, 'cnx-ssh-user', 'root');
    await _type(tester, 'cnx-ssh-password', 'pw');
    expect(_connectTap(tester), isNull);

    await _tap(tester, 'cnx-ssh-auth-key');
    expect(find.byKey(const ValueKey('cnx-ssh-key')), findsOneWidget);
    expect(find.byKey(const ValueKey('cnx-ssh-import')), findsOneWidget);
    expect(find.byKey(const ValueKey('cnx-ssh-password')), findsNothing);

    await _tap(tester, 'cnx-tab-direct');
    expect(find.byKey(const ValueKey('manual-address')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Method offers Password, Browser and Token; Password first', (
    tester,
  ) async {
    await _open(tester);
    final s = _s(tester);
    expect(find.byKey(const ValueKey('manual-user')), findsOneWidget);
    expect(find.byKey(const ValueKey('cnx-remember')), findsOneWidget);
    await _tap(tester, 'cnx-method');
    for (final o in ['password', 'browser', 'token']) {
      expect(find.byKey(ValueKey('cnx-method-$o')), findsOneWidget, reason: o);
    }
    expect(find.text(s.cnxMethodBrowser), findsOneWidget);
    expect(find.text(s.cnxMethodToken), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cnx-method-browser')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cnx-browser-note')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-user')), findsNothing);
    expect(find.byKey(const ValueKey('manual-password')), findsNothing);
    await _method(tester, 'token');
    expect(find.byKey(const ValueKey('cnx-token')), findsOneWidget);
    expect(find.byKey(const ValueKey('cnx-browser-note')), findsNothing);
    await _method(tester, 'password');
    expect(find.byKey(const ValueKey('manual-user')), findsOneWidget);
  });

  testWidgets('Connect stays off until what the method needs is filled', (
    tester,
  ) async {
    await _open(tester);
    expect(_connectTap(tester), isNull);
    await _type(tester, 'manual-address', _address);
    expect(_connectTap(tester), isNull);
    await _type(tester, 'manual-user', 'admin');
    expect(_connectTap(tester), isNull);
    await _type(tester, 'manual-password', 'x');
    expect(_connectTap(tester), isNotNull);
    await _type(tester, 'manual-user', '  ');
    expect(_connectTap(tester), isNull);

    await _method(tester, 'token');
    expect(_connectTap(tester), isNull);
    await _type(tester, 'cnx-token', 'abc');
    expect(_connectTap(tester), isNotNull);
    await _type(tester, 'cnx-token', '');
    expect(_connectTap(tester), isNull);

    await _method(tester, 'browser');
    expect(_connectTap(tester), isNotNull);
    await _type(tester, 'manual-address', '');
    expect(_connectTap(tester), isNull);
  });

  testWidgets('the QR entry is on Connect and goes to the scanner', (
    tester,
  ) async {
    await _open(tester);
    final s = _s(tester);
    expect(find.text(s.cnxScanQr), findsOneWidget);
    await _tap(tester, 'cnx-tab-ssh');
    expect(find.byKey(const ValueKey('manual-scan')), findsOneWidget);
    await _tap(tester, 'manual-scan');
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(ManualConnectPage), findsNothing);
    expect(find.byKey(const ValueKey('qr-help-panel')), findsOneWidget);
  });

  testWidgets('Browser opens the system browser through the sign-in seam', (
    tester,
  ) async {
    Uri? launched;
    final manager = await _open(
      tester,
      browser: (url) async {
        launched = url;
        return false;
      },
    );
    await _method(tester, 'browser');
    await _type(tester, 'manual-address', _address);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('manual-connect')));
      for (var i = 0; i < 50 && launched == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await _wait(tester, ms: 500);
    expect(launched?.path, '/auth/native/authorize');
    expect(launched?.queryParameters['code_challenge_method'], 'S256');
    // The browser never answered: said once, nothing saved.
    expect(
      find.text(_s(tester).dashboardSetupBrowserIncomplete),
      findsOneWidget,
    );
    expect(manager.getConnections(), isEmpty);
  });

  testWidgets('Browser: the callback becomes the saved session', (
    tester,
  ) async {
    final server = (await tester.runAsync(_brokerServer))!;
    addTearDown(() => server.close(force: true));
    final url = 'http://127.0.0.1:${server.port}';
    final manager = await _open(
      tester,
      browser: (launch) async {
        final back = Uri.parse(launch.queryParameters['redirect_uri']!).replace(
          queryParameters: {
            'code': 'synthetic-code',
            'state': launch.queryParameters['state']!,
          },
        );
        final native = HttpClient();
        try {
          final res = await (await native.getUrl(back)).close();
          await res.drain<void>();
        } finally {
          native.close(force: true);
        }
        return true;
      },
    );
    await _method(tester, 'browser');
    await _type(tester, 'manual-address', url);
    await tester.tap(find.byKey(const ValueKey('manual-connect')));
    await _wait(tester, ms: 3000);
    await tester.pump(const Duration(seconds: 3));
    final saved = manager.getConnections().single;
    expect(saved.effectiveDashboardUrl, url);
    expect(saved.dashboardAuthMode, AuthMode.sessionToken);
    final secrets = await manager.getDashboardSecrets(saved.id);
    final session = MobileOAuthSession.decode(
      secrets.sessionToken!,
      saved.id,
      url,
    );
    expect(session?.accessToken, 'synthetic-access');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('Token: a token the Dashboard accepts is saved as the session', (
    tester,
  ) async {
    final server = (await tester.runAsync(() => _tokenServer('good-token')))!;
    addTearDown(() => server.close(force: true));
    final url = 'http://127.0.0.1:${server.port}';
    final manager = await _open(tester);
    await _method(tester, 'token');
    await _type(tester, 'manual-address', url);
    await _type(tester, 'cnx-token', 'good-token');
    await _tap(tester, 'manual-connect');
    await _wait(tester, ms: 2500);
    await tester.pump(const Duration(seconds: 3));
    final saved = manager.getConnections().single;
    expect(saved.effectiveDashboardUrl, url);
    expect(saved.dashboardAuthMode, AuthMode.sessionToken);
    expect(manager.activeConnectionId.value, saved.id);
    final secrets = await manager.getDashboardSecrets(saved.id);
    expect(secrets.sessionToken, 'good-token');
    expect(secrets.password, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('Token: a refused token says so and saves nothing', (
    tester,
  ) async {
    final server = (await tester.runAsync(() => _tokenServer('good-token')))!;
    addTearDown(() => server.close(force: true));
    final manager = await _open(tester);
    await _method(tester, 'token');
    await _type(tester, 'manual-address', 'http://127.0.0.1:${server.port}');
    await _type(tester, 'cnx-token', 'wrong-token');
    await _tap(tester, 'manual-connect');
    await _wait(tester, ms: 2500);
    expect(find.text(_s(tester).cnxTokenRejected), findsOneWidget);
    expect(manager.getConnections(), isEmpty);
    expect(find.byKey(const ValueKey('manual-connect')), findsOneWidget);
  });

  group('Remember password', () {
    late HermesShapedServer back;
    setUp(() async {
      HttpOverrides.global = null;
      back = await HermesShapedServer.start();
    });
    tearDown(() => back.close());

    Future<(ConnectionManager, DashboardSecrets)> run(
      WidgetTester tester, {
      required bool remember,
    }) async {
      final manager = await _open(tester);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('cnx-remember')))
            .value,
        isFalse,
      );
      await _type(tester, 'manual-address', back.url);
      await _type(tester, 'manual-user', HermesShapedServer.user);
      await _type(tester, 'manual-password', HermesShapedServer.pass);
      await _type(tester, 'cnx-name', 'Studio');
      if (remember) await _tap(tester, 'cnx-remember');
      await _tap(tester, 'manual-connect');
      await _wait(tester, ms: 3000);
      await tester.pump(const Duration(seconds: 3));
      final saved = manager.getConnections().single;
      final secrets = await manager.getDashboardSecrets(saved.id);
      expect(saved.label, 'Studio');
      expect(secrets.sessionToken, isNotEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
      return (manager, secrets);
    }

    testWidgets('off (the default): only the session is kept', (tester) async {
      final (_, secrets) = await run(tester, remember: false);
      expect(secrets.password, isNull);
      expect(secrets.username, isNull);
    });

    testWidgets('on: the user and password are kept next to the session', (
      tester,
    ) async {
      final (_, secrets) = await run(tester, remember: true);
      expect(secrets.username, HermesShapedServer.user);
      expect(secrets.password, HermesShapedServer.pass);
    });
  });
}
