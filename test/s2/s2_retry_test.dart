// SPDX-License-Identifier: GPL-3.0-only
// S2 (client level): ONE retry after a 401 on a native session, then a plain
// "sign in again" error instead of a silent reconnect loop. Copy of Desktop's
// single retry after 401 (portal-session, main.ts:8189-8200).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/app_error_log.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/native_session_store.dart';

import '../s1/s1_fixtures.dart' show SecureChannelFake;
import 's2_fixtures.dart';

SavedConnection _conn(String id, String base) => SavedConnection(
  id: id,
  label: 'S2',
  host: '127.0.0.1',
  port: 9131,
  apiKey: 'test-key',
  dashboardUrl: base,
  dashboardAuthMode: AuthMode.sessionToken,
);

DashboardClient _client(String id, S2Dashboard d, String envelope) {
  final c = DashboardClient.forConnection(
    _conn(id, d.base),
    secrets: DashboardSecrets(sessionToken: envelope),
    simpleConnectOverride: true,
  );
  addTearDown(c.close);
  return c;
}

Future<(S2Dashboard, SecureChannelFake, String)> _setUp(
  String id, {
  bool withRefresh = true,
  int? expiresAt,
}) async {
  final d = S2Dashboard();
  await d.start();
  final secure = SecureChannelFake()..install();
  secure.storage['dash_token_$id'] = d.envelope(
    id,
    withRefresh: withRefresh,
    expiresAt: expiresAt,
  );
  return (d, secure, secure.storage['dash_token_$id']!);
}

bool _loginRequired(Object e) =>
    e is DashboardAuthException &&
    e.code == DashboardAuthFailureCode.loginRequired;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test('an access the server rejects inside its lifetime: ONE refresh and ONE '
      'retry succeed; the request is seen twice, not three times', () async {
    const id = 's2-retry';
    final (d, _, envelope) = await _setUp(id);
    d.rejectCurrent = true;
    final res = await _client(id, d, envelope).apiGet('ping');
    expect(res['ok'], true);
    expect(d.pings, [accessN(0), accessN(1)]);
    expect(d.refreshCalls, 1);
  });

  test('five concurrent rejections still cost ONE refresh', () async {
    const id = 's2-concurrent';
    final (d, _, envelope) = await _setUp(id);
    d.rejectCurrent = true;
    final client = _client(id, d, envelope);
    final results = await Future.wait(
      List.generate(5, (_) => client.apiGet('ping')),
    );
    expect(results, hasLength(5));
    expect(d.refreshCalls, 1);
    expect(d.pings.where((a) => a == accessN(1)), hasLength(5));
  });

  test('the retry is rejected too: sign-in required, exactly two requests, '
      'and the next call does not touch the server again', () async {
    const id = 's2-twice';
    final (d, _, envelope) = await _setUp(id);
    d.rejectAll = true;
    final client = _client(id, d, envelope);
    await expectLater(
      client.apiGet('ping'),
      throwsA(predicate(_loginRequired)),
    );
    expect(d.pings, [accessN(0), accessN(1)]);
    expect(d.refreshCalls, 1);
    await expectLater(
      client.apiGet('ping'),
      throwsA(predicate(_loginRequired)),
    );
    expect(d.pings, hasLength(2), reason: 'no third request');
    expect(d.refreshCalls, 1, reason: 'no second rotation');
  });

  test('the refresh says session_expired: sign-in required, envelope dropped, '
      'no more refresh calls afterwards', () async {
    const id = 's2-expired';
    final (d, secure, envelope) = await _setUp(id);
    d.rejectCurrent = true;
    d.refreshMode = RefreshMode.expired;
    final client = _client(id, d, envelope);
    await expectLater(
      client.apiGet('ping'),
      throwsA(predicate(_loginRequired)),
    );
    expect(d.refreshCalls, 1);
    expect(secure.storage['dash_token_$id'], isNull);
    await expectLater(
      client.apiGet('ping'),
      throwsA(predicate(_loginRequired)),
    );
    expect(d.refreshCalls, 1);
    expect(d.pings, hasLength(1));
  });

  test('H1: an expired envelope with no refresh is "sign in again", not an '
      'opaque native error', () async {
    const id = 's2-v1';
    final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 30;
    final (d, _, envelope) = await _setUp(
      id,
      withRefresh: false,
      expiresAt: past,
    );
    await expectLater(
      _client(id, d, envelope).apiGet('ping'),
      throwsA(predicate(_loginRequired)),
    );
    expect(d.pings, isEmpty);
  });

  test('403 is "no permission": no refresh, no retry, no sign-in', () async {
    const id = 's2-403';
    final (d, _, envelope) = await _setUp(id);
    d.forbid = true;
    await expectLater(
      _client(id, d, envelope).apiGet('ping'),
      throwsA(
        predicate((e) => e is DashboardHttpException && e.statusCode == 403),
      ),
    );
    expect(d.refreshCalls, 0);
    expect(d.pings, hasLength(1));
  });

  test('a refresh the provider could not answer (503) is transient: the '
      'envelope stays and it is never a sign-in request', () async {
    const id = 's2-503';
    final (d, secure, envelope) = await _setUp(id);
    d.rejectCurrent = true;
    d.refreshMode = RefreshMode.unavailable;
    await expectLater(
      _client(id, d, envelope).apiGet('ping'),
      throwsA(
        predicate(
          (e) => e is NativeRefreshTransient && e is! DashboardAuthException,
        ),
      ),
    );
    expect(secure.storage['dash_token_$id'], isNotNull);
  });

  test('a write rejected with 401 is resent ONCE under the guard: the server '
      'saw it twice, never three times', () async {
    const id = 's2-write';
    final (d, _, envelope) = await _setUp(id);
    d.rejectCurrent = true;
    await DashboardClient.guardedWrite(
      () => true,
      () => _client(id, d, envelope).apiPost('echo', body: {'n': 1}),
    );
    expect(d.writes, [accessN(0), accessN(1)]);
    expect(d.refreshCalls, 1);
  });

  test('a guard revoked between the 401 and the resend: nothing is sent '
      'again', () async {
    const id = 's2-write-revoked';
    final (d, _, envelope) = await _setUp(id);
    d.rejectCurrent = true;
    var authorized = true;
    d.onWrite = () => authorized = false; // revoked as the first send lands
    await expectLater(
      DashboardClient.guardedWrite(
        () => authorized,
        () => _client(id, d, envelope).apiPost('echo', body: {'n': 1}),
      ),
      throwsA(isA<DashboardWriteRevoked>()),
    );
    expect(d.writes, [accessN(0)]);
  });

  test(
    'log capture: no access/refresh token reaches debugPrint, print, '
    'AppErrorLog or an exception text on the retry and sign-in paths',
    () async {
      final lines = <String>[];
      final previous = debugPrint;
      debugPrint = (m, {wrapWidth}) {
        if (m != null) lines.add(m);
      };
      addTearDown(() => debugPrint = previous);
      AppErrorLog.resetForTesting();
      await runZoned(
        () async {
          for (final mode in [RefreshMode.ok, RefreshMode.expired]) {
            final id = 's2-log-${mode.name}';
            final (d, _, envelope) = await _setUp(id);
            d.rejectCurrent = true;
            d.refreshMode = mode;
            try {
              await _client(id, d, envelope).apiGet('ping');
            } catch (e) {
              lines.add(e.toString());
              if (e is DashboardAuthException) lines.add(e.code.name);
            }
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => lines.add(line),
        ),
      );
      lines.addAll(AppErrorLog.recent.map((e) => e.toString()));
      final canaries = [
        for (var n = 0; n < 3; n++) ...[accessN(n), refreshN(n)],
      ];
      for (final line in lines) {
        for (final canary in canaries) {
          expect(line, isNot(contains(canary)));
        }
      }
    },
  );
}
