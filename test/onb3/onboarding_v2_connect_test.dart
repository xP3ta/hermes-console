// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/recover_access_page.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../onb2q/hermes_shaped_server.dart';
import '../support/onboarding_fakes.dart';

/// Counts every request the app tries to make (public cleartext: none).
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

String _link(
  String url, {
  String? pass = HermesShapedServer.pass,
  String user = HermesShapedServer.user,
  String extra = '',
}) =>
    'hermes://pair?v=2&url=${Uri.encodeQueryComponent(url)}&user=$user'
    '${pass == null ? '' : '&pass=${Uri.encodeQueryComponent(pass)}'}$extra';

Future<ConnectionManager> _open(
  WidgetTester tester,
  String link, {
  void Function()? onDone,
  bool scan = true,
}) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => call.method == 'Clipboard.getData' ? {'text': link} : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  final manager = await onboardingManager();
  ValueChanged<String>? detected;
  await tester.pumpWidget(
    onboardingHost(
      OnboardingScreen(
        simpleConnectEnabled: scan,
        cameraBuilder: (detect, _) {
          detected = detect;
          return const SizedBox();
        },
        connManager: manager,
        onDone: onDone ?? () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _tap(tester, 'onboarding-scan');
  detected!(link);
  await tester.pump(const Duration(seconds: 3));
  return manager;
}

/// The simple-connect screens keep an ambient animation alive, so these tests
/// pump fixed spans instead of waiting for them to settle.
Future<void> _tap(WidgetTester tester, String key) async {
  final control = find.byKey(ValueKey(key));
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Taps Connect and lets the REAL socket round trips finish.
Future<void> _connect(WidgetTester tester) async {
  await _tap(tester, 'onboarding-confirm');
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(seconds: 2));
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
  late HermesShapedServer server;
  setUp(() async {
    // The test binding answers every HttpClient with a 400; these tests talk
    // to a real server on 127.0.0.1.
    HttpOverrides.global = null;
    server = await HermesShapedServer.start();
  });
  tearDown(() async => server.close());

  testWidgets('v2 link: confirm shows the Dashboard text, Connect signs in '
      'natively, the password is never stored', (tester) async {
    final manager = await _open(tester, _link(server.url));
    final s = onboardingStrings(tester);
    expect(find.text(s.onb3ConfirmDashboard), findsOneWidget);
    expect(find.text('127.0.0.1:${Uri.parse(server.url).port}'), findsWidgets);
    await _connect(tester);
    expect(server.requests, contains('POST /auth/password-login'));
    expect(server.tokenPosts, 1);
    final saved = manager.getConnections().single;
    expect(saved.apiKey, isEmpty);
    expect(saved.effectiveDashboardUrl, server.url);
    expect(manager.activeConnectionId.value, saved.id);
    final secrets = await manager.getDashboardSecrets(saved.id);
    expect(secrets.sessionToken, isNotEmpty);
    expect(secrets.password, isNull);
    expect(await _everythingPersisted(manager), isNot(contains('CANARY')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('v2 token / host / port never create a Gateway connection', (
    tester,
  ) async {
    final manager = await _open(
      tester,
      _link(
        server.url,
        extra: '&token=gw-secret&host=evil.invalid&port=1&https=1',
      ),
    );
    await _connect(tester);
    final saved = manager.getConnections().single;
    expect(saved.host, '127.0.0.1');
    expect(saved.port, Uri.parse(server.url).port);
    expect(saved.useHttps, isFalse);
    expect(saved.apiKey, isEmpty);
    expect(await _everythingPersisted(manager), isNot(contains('gw-secret')));
    expect(server.requests.every((r) => !r.contains('evil')), isTrue);
  });

  testWidgets('without a password in the link it is asked once', (
    tester,
  ) async {
    final manager = await _open(tester, _link(server.url, pass: null));
    final field = find.byKey(const ValueKey('onb3-password'));
    expect(field, findsOneWidget);
    // Connect is dead until something is typed; nothing was sent.
    await _tap(tester, 'onboarding-confirm');
    expect(server.requests, isEmpty);
    await tester.enterText(field, HermesShapedServer.pass);
    await tester.pump();
    await _connect(tester);
    expect(
      server.requests.where((r) => r == 'POST /auth/password-login'),
      hasLength(1),
    );
    expect(manager.getConnections(), hasLength(1));
    expect(await _everythingPersisted(manager), isNot(contains('CANARY')));
  });

  testWidgets('wrong password: one sentence, a way to recover access', (
    tester,
  ) async {
    final manager = await _open(
      tester,
      _link(server.url, pass: 'not-the-password'),
    );
    await _connect(tester);
    expect(find.byKey(const ValueKey('onb3-wrong-password')), findsOneWidget);
    expect(find.byKey(const ValueKey('onb3-password')), findsOneWidget);
    expect(manager.getConnections(), isEmpty);
    await _tap(tester, 'onb3-recover');
    expect(find.byType(RecoverAccessPage), findsOneWidget);
  });

  testWidgets('retry after a transient failure resends the typed password', (
    tester,
  ) async {
    final manager = await _open(tester, _link(server.url, pass: null));
    server.rateLimitAfter = 0;
    await tester.enterText(
      find.byKey(const ValueKey('onb3-password')),
      HermesShapedServer.pass,
    );
    await tester.pump();
    await _connect(tester);
    expect(find.byKey(const ValueKey('onboarding-retry')), findsOneWidget);
    server.rateLimitAfter = 99;
    await _tap(tester, 'onboarding-retry');
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 2));
    expect(
      server.requests.where((r) => r == 'POST /auth/password-login'),
      hasLength(2),
    );
    expect(manager.getConnections(), hasLength(1));
  });

  testWidgets('no password route (404): saved, falls to the browser sign-in', (
    tester,
  ) async {
    server.loginStatus = 404;
    final manager = await _open(tester, _link(server.url));
    final missingStep = onboardingStrings(tester).o2MissingStep;
    await _connect(tester);
    expect(find.byKey(const ValueKey('onboarding-sign-in')), findsNothing);
    expect(find.text(missingStep), findsNothing);
    expect(find.byType(DashboardSetupScreen), findsOneWidget);
    final saved = manager.getConnections().single;
    expect(saved.apiKey, isEmpty);
    expect(await _everythingPersisted(manager), isNot(contains('CANARY')));
  });

  testWidgets('unreachable server shows the unreachable sentence', (
    tester,
  ) async {
    final dead = (await tester.runAsync(() async {
      final gone = await HermesShapedServer.start();
      final url = gone.url;
      await gone.close();
      return url;
    }))!;
    await _open(tester, _link(dead));
    await _connect(tester);
    expect(find.text(onboardingStrings(tester).o2Unreachable), findsOneWidget);
  });

  testWidgets('http to a PUBLIC host: zero sockets, a clear message', (
    tester,
  ) async {
    final counting = _CountingOverrides();
    await HttpOverrides.runWithHttpOverrides(() async {
      await _open(tester, _link('http://hermes.example.com:9119'));
      await _connect(tester);
    }, counting);
    expect(counting.requests, 0);
    expect(
      find.text(onboardingStrings(tester).commonCleartextPublic),
      findsOneWidget,
    );
  });

  testWidgets('http on a private network needs the existing consent', (
    tester,
  ) async {
    final manager = await _open(tester, _link('http://192.168.1.50:9119'));
    final consent = find.byKey(const ValueKey('pairing-http-consent'));
    expect(consent, findsOneWidget);
    await _tap(tester, 'onboarding-confirm');
    expect(find.byKey(const ValueKey('onboarding-confirm')), findsOneWidget);
    expect(manager.getConnections(), isEmpty);
  });

  testWidgets('a pasted v2 link shows the same Dashboard confirmation', (
    tester,
  ) async {
    await _open(tester, _link(server.url), scan: false);
    expect(
      find.text(onboardingStrings(tester).onb3ConfirmDashboard),
      findsOneWidget,
    );
  });

  testWidgets('https needs no consent', (tester) async {
    await _open(tester, _link('https://hermes.example.com'));
    expect(find.byKey(const ValueKey('pairing-http-consent')), findsNothing);
  });

  testWidgets('a v1 link still shows the legacy confirmation', (tester) async {
    await _open(tester, fakeFullPairing.build(), scan: false);
    final s = onboardingStrings(tester);
    expect(find.text(s.o2ConfirmFull), findsOneWidget);
    expect(find.text(s.onb3ConfirmDashboard), findsNothing);
    expect(find.byKey(const ValueKey('onb3-password')), findsNothing);
  });
}
