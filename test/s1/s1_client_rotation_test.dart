// SPDX-License-Identifier: GPL-3.0-only
// S1 (client level): a Dashboard client holding a native envelope renews it
// through the single coordinator, persists the rotated refresh BEFORE using the
// new access, and never trusts its own memory over the store.
// Written against public API only so it also runs on the C2b base (RED there).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/app_error_log.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';

import 's1_fixtures.dart';

SavedConnection _conn(String id, String base) => SavedConnection(
  id: id,
  label: 'S1',
  host: '127.0.0.1',
  port: 9131,
  apiKey: 'test-api-key',
  dashboardUrl: base,
  dashboardAuthMode: AuthMode.sessionToken,
);

DashboardClient _client(String id, RotatingDashboard d, String envelope) {
  final c = DashboardClient.forConnection(
    _conn(id, d.base),
    secrets: DashboardSecrets(sessionToken: envelope),
  );
  addTearDown(c.close);
  return c;
}

/// The legacy decode of f047e636 (C1 closed), copied verbatim as a fixture of
/// code: what a downgraded Console would run on a v2 envelope.
MobileOAuthSession? _oldDecode(String? raw, String owner, String target) {
  if (raw == null || !raw.startsWith(MobileOAuthSession.prefix)) return null;
  final body = jsonDecode(raw.substring(MobileOAuthSession.prefix.length));
  if (body is! Map ||
      body['connection_id'] != owner ||
      body['base_url'] is! String ||
      body['access_token'] is! String ||
      (body['access_token'] as String).isEmpty ||
      body['expires_at'] is! int ||
      body['provider'] is! String ||
      body['user_id'] is! String) {
    throw const MobileOAuthException();
  }
  return MobileOAuthSession(
    connectionId: owner,
    baseUrl: target,
    accessToken: body['access_token'] as String,
    expiresAt: body['expires_at'] as int,
    provider: body['provider'] as String,
    userId: body['user_id'] as String,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test(
    '20 concurrent requests with an expired access: ONE refresh, the '
    'rotated pair is stored before any request uses the new access',
    () async {
      final d = RotatingDashboard(live: true);
      await d.start();
      final secure = SecureChannelFake()..install();
      const id = 's1-conc';
      secure.storage['dash_token_$id'] = d.envelope(id);
      d.persistedRev = () => MobileOAuthSession.decode(
        secure.storage['dash_token_$id'],
        id,
        d.base,
      )!.rev;
      final client = _client(id, d, d.envelope(id));

      final results = await Future.wait(
        List.generate(20, (_) => client.apiGet('ping')),
      );

      expect(results, hasLength(20));
      expect(d.refreshCalls, 1);
      expect(d.pings, hasLength(20));
      expect(d.pings.toSet(), {accessN(1)});
      expect(d.orderViolations, isEmpty);
      final stored = MobileOAuthSession.decode(
        secure.storage['dash_token_$id'],
        id,
        d.base,
      )!;
      expect(stored.refreshToken, refreshN(1));
      expect(stored.rev, 1);
      expect(stored.accessToken, accessN(1));
      expect(secure.flushes, greaterThanOrEqualTo(1), reason: 'durable write');
    },
  );

  test('a valid access is used as is: no refresh call', () async {
    final d = RotatingDashboard(live: true);
    await d.start();
    final secure = SecureChannelFake()..install();
    const id = 's1-valid';
    secure.storage['dash_token_$id'] = d.envelope(id, expired: false);
    final client = _client(id, d, d.envelope(id, expired: false));
    await client.apiGet('ping');
    expect(d.refreshCalls, 0);
    expect(d.pings, [accessN(0)]);
  });

  test(
    'the store is the truth, not the client memory: a second client '
    'holding a stale envelope reuses the rotation another one stored',
    () async {
      final d = RotatingDashboard(live: true);
      await d.start();
      final secure = SecureChannelFake()..install();
      const id = 's1-truth';
      final stale = d.envelope(id);
      secure.storage['dash_token_$id'] = stale;
      await _client(id, d, stale).apiGet('ping');
      expect(d.refreshCalls, 1);

      await _client(id, d, stale).apiGet('ping'); // memory still says expired
      expect(
        d.refreshCalls,
        1,
        reason: 'must reread the store, not rotate again',
      );
      expect(d.pings, [accessN(1), accessN(1)]);
    },
  );

  test(
    'legacy reader (f047e636) still accepts the v2 envelope it finds',
    () async {
      final d = RotatingDashboard(live: true);
      await d.start();
      final secure = SecureChannelFake()..install();
      const id = 's1-cross';
      secure.storage['dash_token_$id'] = d.envelope(id);
      await _client(id, d, d.envelope(id)).apiGet('ping');
      final raw = secure.storage['dash_token_$id']!;
      expect(raw, startsWith(MobileOAuthSession.prefix));
      expect(raw, contains('"v":2'));
      final old = _oldDecode(raw, id, d.base)!;
      expect(old.accessToken, accessN(1));
      expect(old.userId, 'u1');
    },
  );

  test('log capture: no access/refresh token reaches debugPrint, print, '
      'AppErrorLog or an exception text, on success and on failure', () async {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (m, {wrapWidth}) {
      if (m != null) lines.add(m);
    };
    addTearDown(() => debugPrint = previous);
    AppErrorLog.resetForTesting();
    final d = RotatingDashboard(live: true);
    await d.start();
    final secure = SecureChannelFake()..install();
    await runZoned(
      () async {
        for (final status in [null, 503]) {
          final id = 's1-log-${status ?? 200}';
          d.failStatus = status;
          secure.storage['dash_token_$id'] = d.envelope(id);
          try {
            await _client(id, d, d.envelope(id)).apiGet('ping');
          } catch (e) {
            lines.add(e.toString());
          }
        }
        // A revoked family: the next refresh answers 401 session_expired.
        d.failStatus = null;
        d.revoked = true;
        const id = 's1-log-401';
        secure.storage['dash_token_$id'] = d.envelope(id);
        try {
          await _client(id, d, d.envelope(id)).apiGet('ping');
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
      for (var n = 0; n < 4; n++) ...[accessN(n), refreshN(n)],
    ];
    for (final line in lines) {
      for (final canary in canaries) {
        expect(line, isNot(contains(canary)));
      }
    }
  });

  group('backups stay closed (H7)', () {
    test('allowBackup=false and every extraction exclusion is present', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('android:allowBackup="false"'));
      expect(manifest, contains('android:fullBackupContent="false"'));
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
      final rules = File(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      ).readAsStringSync();
      for (final section in ['cloud-backup', 'device-transfer']) {
        final block = RegExp(
          '<$section[^>]*>([\\s\\S]*?)</$section>',
        ).firstMatch(rules);
        expect(block, isNotNull, reason: section);
        for (final domain in [
          'root',
          'file',
          'database',
          'sharedpref',
          'external',
        ]) {
          expect(
            block!.group(1),
            contains('<exclude domain="$domain" path="." />'),
            reason: '$section excludes $domain',
          );
        }
      }
    });
  });

  group('durable write (DJ-1 = A)', () {
    final kotlin = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/DurableSecretWriter.kt',
    );
    test('the writer flushes the SAME preferences file the plugin writes', () {
      final src = kotlin.readAsStringSync();
      expect(src, contains('"FlutterSecureStorage"'));
      expect(src, contains('.commit()'));
      expect(src, isNot(contains('.apply()')));
      expect(src, contains('"hermes/durable_secrets"'));
    });
    test('every engine that can rotate registers the channel', () {
      for (final f in [
        'MainActivity.kt',
        'HermesApplication.kt',
        'HermesActionDrainWorker.kt',
      ]) {
        final src = File(
          'android/app/src/main/kotlin/com/hermesagent/hermes_android/$f',
        ).readAsStringSync();
        expect(src, contains('DurableSecretWriter.attach'), reason: f);
      }
    });
  });
}
