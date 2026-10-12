// What a bridge-era install (≤ 1.2.14) left on the phone is found once,
// each instance's Dashboard is probed once with the credentials it has, and
// only then the leftovers are deleted. No request ever goes to `/bridge/*`.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/legacy_bridge_retirement.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  var readAllCalls = 0;

  setUp(() {
    secureStore.clear();
    readAllCalls = 0;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'readAll':
                readAllCalls++;
                return Map<String, String>.from(secureStore);
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
  });

  SavedConnection conn(String id, {String host = 'lab.invalid'}) =>
      SavedConnection(
        id: id,
        label: 'Server $id',
        host: host,
        port: 8642,
        apiKey: 'gateway-key',
        useHttps: true,
        dashboardUrl: 'https://$host:9119',
        dashboardAuthMode: AuthMode.basicAuth,
      );

  test('a phone that never had the bridge is left alone', () async {
    SharedPreferences.setMockInitialValues({'hermes_auto_update': true});
    secureStore['api_key_c1'] = 'gateway-key';
    final prefs = await SharedPreferences.getInstance();
    var probes = 0;
    final work = LegacyBridgeRetirement(
      prefs: prefs,
      probe: (_) async {
        probes++;
        return DashboardAccess.ready;
      },
    );

    await work.run([conn('c1')]);
    await work.run([conn('c1')]);

    expect(work.legacyInstall, isFalse);
    expect(probes, 0);
    expect(readAllCalls, 1, reason: 'looked for leftovers exactly once');
    expect(secureStore, {'api_key_c1': 'gateway-key'});
    expect(work.signInCandidate([conn('c1')], 'c1'), isNull);
    expect(work.shouldOfferRemoval([conn('c1')]), isFalse);
  });

  test(
    'a legacy install is probed once, then its leftovers are deleted',
    () async {
      SharedPreferences.setMockInitialValues({
        LegacyBridgeRetirement.legacyPreference: true,
        'components_auto_update': true,
        'hermes_auto_update': true,
      });
      secureStore.addAll({
        'api_key_c1': 'gateway-key',
        'dash_user_c1': 'owner',
        'dash_pass_c1': 'dashboard-pass',
        LegacyBridgeRetirement.legacyUrlKey('c1'): 'http://lab.invalid:9131',
        LegacyBridgeRetirement.legacyTokenKey('c1'): 'retired-token',
        LegacyBridgeRetirement.legacyTokenKey('c2'): 'retired-token-2',
      });
      final prefs = await SharedPreferences.getInstance();
      final probed = <String>[];
      final work = LegacyBridgeRetirement(
        prefs: prefs,
        probe: (connection) async {
          // The probe runs BEFORE the purge.
          expect(secureStore.keys.where((k) => k.startsWith('bridge_')), [
            'bridge_url_c1',
            'bridge_token_c1',
            'bridge_token_c2',
          ]);
          probed.add(connection.id);
          return connection.id == 'c1'
              ? DashboardAccess.ready
              : DashboardAccess.needsSignIn;
        },
      );
      final connections = [conn('c1'), conn('c2', host: 'other.invalid')];

      await work.run(connections);

      expect(probed, ['c1', 'c2']);
      expect(work.legacyInstall, isTrue);
      expect(secureStore.keys.toList()..sort(), [
        'api_key_c1',
        'dash_pass_c1',
        'dash_user_c1',
      ]);
      expect(prefs.getKeys().where((k) => k.startsWith('bridge_')), isEmpty);
      // The Hermes auto-update choice is not a bridge leftover.
      expect(prefs.getBool('components_auto_update'), isTrue);
      expect(prefs.getBool('hermes_auto_update'), isTrue);
      expect(work.access, {
        'c1': DashboardAccess.ready,
        'c2': DashboardAccess.needsSignIn,
      });
      // Nothing secret went into the remembered state.
      final remembered = prefs.getString(LegacyBridgeRetirement.stateKey)!;
      expect(remembered, isNot(contains('retired-token')));
      expect(remembered, isNot(contains('dashboard-pass')));

      await work.run(connections);
      expect(probed, ['c1', 'c2'], reason: 'a verdict is never asked twice');
    },
  );

  test('no verdict is asked again on later launches, a few times', () async {
    SharedPreferences.setMockInitialValues({});
    secureStore[LegacyBridgeRetirement.legacyTokenKey('c1')] = 'retired';
    final prefs = await SharedPreferences.getInstance();
    var probes = 0;
    final work = LegacyBridgeRetirement(
      prefs: prefs,
      probe: (_) async {
        probes++;
        throw StateError('offline');
      },
    );

    for (var launch = 0; launch < 7; launch++) {
      await work.run([conn('c1')]);
    }

    expect(probes, LegacyBridgeRetirement.maxProbeAttempts);
    expect(work.access, {'c1': DashboardAccess.unknown});
    expect(secureStore, isEmpty, reason: 'purged on the first launch anyway');
    expect(work.signInCandidate([conn('c1')], 'c1'), isNull);
    expect(work.shouldOfferRemoval([conn('c1')]), isFalse);
  });

  test('what is said is said once: sign-in first, then goodbye', () async {
    SharedPreferences.setMockInitialValues({});
    secureStore[LegacyBridgeRetirement.legacyTokenKey('c1')] = 'retired';
    final prefs = await SharedPreferences.getInstance();
    final connections = [conn('c1'), conn('c2'), conn('c3')];
    final work = LegacyBridgeRetirement(
      prefs: prefs,
      probe: (c) async =>
          c.id == 'c1' ? DashboardAccess.ready : DashboardAccess.needsSignIn,
    );
    await work.run(connections);

    // The active instance first; nothing about removal while a sign-in waits.
    expect(work.signInCandidate(connections, 'c3')?.id, 'c3');
    expect(work.signInCandidate(connections, 'c1')?.id, 'c2');
    expect(work.shouldOfferRemoval(connections), isFalse);

    await work.markSignInNoticeDone('c3', solved: true);
    expect(work.access['c3'], DashboardAccess.ready);
    expect(work.signInCandidate(connections, 'c3')?.id, 'c2');

    await work.markSignInNoticeDone('c2'); // dismissed, not solved
    expect(work.access['c2'], DashboardAccess.needsSignIn);
    expect(work.signInCandidate(connections, 'c2'), isNull);

    expect(work.shouldOfferRemoval(connections), isTrue);
    await work.markRemovalNoticeDone();
    expect(work.shouldOfferRemoval(connections), isFalse);

    // A new object reads the same remembered answers.
    final later = LegacyBridgeRetirement(prefs: prefs);
    expect(later.signInCandidate(connections, 'c2'), isNull);
    expect(later.shouldOfferRemoval(connections), isFalse);
  });

  group('the silent probe', () {
    test('a Dashboard that wants a sign-in this phone lacks', () async {
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/status') {
          return http.Response(jsonEncode({'auth_required': true}), 200);
        }
        return http.Response('{"detail":"Unauthorized"}', 401);
      });

      final verdict = await probeDashboardAccess(
        conn('probe-none', host: 'probe-none.invalid'),
        httpClient: client,
      );

      expect(verdict, DashboardAccess.needsSignIn);
      expect(paths.first, 'GET /api/status');
      expect(paths.where((p) => p.contains('/bridge/')), isEmpty);
      expect(paths.where((p) => !p.startsWith('GET ')), isEmpty);
    });

    test('a Dashboard whose stored sign-in works', () async {
      secureStore['dash_user_probe-ok'] = 'owner';
      secureStore['dash_pass_probe-ok'] = 'dashboard-pass';
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        switch (request.url.path) {
          case '/api/status':
            return http.Response(jsonEncode({'auth_required': true}), 200);
          case '/auth/password-login':
            return http.Response(
              '{"ok":true}',
              200,
              headers: {'set-cookie': 'hermes_session_at=cookie; Path=/'},
            );
          case '/api/auth/me':
            return http.Response('{"user":"owner"}', 200);
        }
        return http.Response('{}', 404);
      });

      final verdict = await probeDashboardAccess(
        conn('probe-ok', host: 'probe-ok.invalid'),
        httpClient: client,
      );

      expect(verdict, DashboardAccess.ready);
      expect(paths, [
        'GET /api/status',
        'POST /auth/password-login',
        'GET /api/auth/me',
      ]);
    });

    test('a stored password the Dashboard no longer accepts', () async {
      secureStore['dash_user_probe-bad'] = 'owner';
      secureStore['dash_pass_probe-bad'] = 'old-pass';
      final client = MockClient((request) async {
        if (request.url.path == '/api/status') {
          return http.Response(jsonEncode({'auth_required': true}), 200);
        }
        return http.Response('{"detail":"Invalid credentials"}', 401);
      });

      expect(
        await probeDashboardAccess(
          conn('probe-bad', host: 'probe-bad.invalid'),
          httpClient: client,
        ),
        DashboardAccess.needsSignIn,
      );
    });

    test(
      'no answer is no verdict, and public cleartext sends nothing',
      () async {
        var requests = 0;
        final dead = MockClient((request) async {
          requests++;
          throw http.ClientException('unreachable', request.url);
        });
        expect(
          await probeDashboardAccess(
            conn('probe-dead', host: 'probe-dead.invalid'),
            httpClient: dead,
          ),
          DashboardAccess.unknown,
        );
        expect(requests, 1);

        requests = 0;
        final cleartext = SavedConnection(
          id: 'probe-clear',
          label: 'Public',
          host: 'public.example.com',
          port: 8642,
          apiKey: 'gateway-key',
          dashboardUrl: 'http://public.example.com:9119',
        );
        expect(
          await probeDashboardAccess(cleartext, httpClient: dead),
          DashboardAccess.unknown,
        );
        expect(requests, 0);
      },
    );
  });
}
