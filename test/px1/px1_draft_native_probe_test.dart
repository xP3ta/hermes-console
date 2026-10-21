// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// PX1: a new connection signed in through the browser is probed with the
// envelope the form just obtained, before anything is saved. Real loopback
// HTTP Dashboard, real ConnectionDiagnostics, in-memory secure storage.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';
import 'package:hermes_android/core/services/native_session_store.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/onboarding_fakes.dart';
import '../support/px1_fake_dashboard.dart';

class _Browser extends UrlLauncherPlatform {
  _Browser(this.open);
  final Future<bool> Function(Uri) open;
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) =>
      open(Uri.parse(url));
}

class _Store implements NativeEnvelopeStore {
  _Store(this.raw);
  final Map<String, String> raw;
  @override
  Future<String?> read(String id) async => raw[id];
  @override
  Future<void> writeDurable(String id, String v) async => raw[id] = v;
  @override
  Future<void> delete(String id) async => raw.remove(id);
}

String _envelope(String id, String base, String token, {int? expires}) =>
    MobileOAuthSession(
      connectionId: id,
      baseUrl: base,
      accessToken: token,
      expiresAt:
          expires ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      provider: 'sso',
      userId: 'px1-user',
      refreshToken: 'px1-refresh',
      rev: 1,
    ).encode();

SavedConnection _conn(String id, String base) => SavedConnection(
  id: id,
  label: 'Px1',
  host: '127.0.0.1',
  port: 8642,
  apiKey: '',
  dashboardUrl: base,
  dashboardAuthMode: AuthMode.sessionToken,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);
  tearDown(() => NativeSessionCoordinator.replaceInstanceForTesting(null));

  testWidgets('a new connection signed in first is probed, then saved', (
    tester,
  ) async {
    final server = Px1FakeDashboard();
    await tester.runAsync(server.start);
    UrlLauncherPlatform.instance = _Browser(server.browse);
    final manager = await onboardingManager();
    await tester.pumpWidget(
      onboardingHost(
        InstanceEditScreen(
          simpleConnect: false,
          connManager: manager,
          prefill: _conn('px1', server.base),
          verifyChatBeforeSave: true,
          signInFirst: true,
        ),
      ),
    );
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    final signIn = find.byKey(const ValueKey('dashboard-oauth-browser'));
    await until(() => signIn.evaluate().isNotEmpty);
    await tester.tap(signIn);
    await until(() => manager.getConnections().isNotEmpty);
    expect(
      server.sessionsWithBearer,
      greaterThan(0),
      reason: 'the probe sent no Bearer: ${server.requests}',
    );
    final conn = manager.getConnections().single;
    final secrets = await manager.getDashboardSecrets(conn.id);
    final stored = MobileOAuthSession.decode(
      secrets.sessionToken,
      conn.id,
      server.base,
    );
    expect(stored?.accessToken, Px1FakeDashboard.issuedToken);
  });

  group('draft envelope guards', () {
    late Px1FakeDashboard server;
    late String base;
    setUp(() async {
      server = Px1FakeDashboard();
      await server.start();
      base = server.base;
    });

    Future<Map<String, String>> probe(
      String id,
      String? form,
      Map<String, String> store,
    ) async {
      NativeSessionCoordinator.replaceInstanceForTesting(
        NativeSessionCoordinator(store: _Store(store)),
      );
      final client = DashboardClient.forConnection(
        _conn(id, base),
        secrets: DashboardSecrets(sessionToken: form ?? ''),
      );
      addTearDown(client.close);
      return client.authHeadersForDiagnostics();
    }

    final loginRequired = throwsA(
      predicate(
        (e) =>
            e is DashboardAuthException &&
            e.code == DashboardAuthFailureCode.loginRequired,
      ),
    );

    test('(a) a saved one uses the store, a new one its draft', () async {
      final h = await probe('a', _envelope('a', base, 'draft'), {
        'a': _envelope('a', base, 'stored'),
      });
      expect(h['Authorization'], 'Bearer stored');
      final fresh = await probe('a', _envelope('a', base, 'draft'), {});
      expect(fresh['Authorization'], 'Bearer draft');
    });

    test('(b) an envelope of another connection or server is refused', () {
      expect(probe('a', _envelope('other', base, 'x'), {}), loginRequired);
      final elsewhere = _envelope('a', 'http://127.0.0.1:1', 'x');
      expect(probe('a', elsewhere, {}), loginRequired);
    });

    test('(c) an expired draft needs a login, no refresh', () async {
      final old = _envelope('a', base, 'x', expires: 1000);
      await expectLater(probe('a', old, {}), loginRequired);
      expect(server.requests, isEmpty);
    });

    test('(d) a dead saved session yields only to a live draft of the same '
        'connection and server, and is never overwritten', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      String v1(String id, String b, String t, int exp) => MobileOAuthSession(
        connectionId: id,
        baseUrl: b,
        accessToken: t,
        expiresAt: exp,
        provider: 'sso',
        userId: 'px1-user',
      ).encode();
      final dead = v1('a', base, 'stale', now - 10);
      final store = {'a': dead};
      final h = await probe('a', _envelope('a', base, 'draft'), store);
      expect(h['Authorization'], 'Bearer draft');
      expect(store['a'], dead, reason: 'the fallback must never persist');
      expect(server.requests, isEmpty, reason: 'a dead v1 is not refreshed');
      await expectLater(
        probe('a', _envelope('b', base, 'x'), store),
        loginRequired,
      );
      final elsewhere = _envelope('a', 'http://127.0.0.1:1', 'x');
      await expectLater(probe('a', elsewhere, store), loginRequired);
      final oldDraft = v1('a', base, 'old', now - 5);
      await expectLater(probe('a', oldDraft, store), loginRequired);
      expect(store['a'], dead);
    });
  });
}
