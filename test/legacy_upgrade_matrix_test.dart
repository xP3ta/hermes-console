// Updating from a bridge-era install (≤ 1.2.14), case by case. Each test
// starts from what such a phone really holds (the saved connections, their
// Keystore secrets, the bridge leftovers), runs the app's own start-up
// migration and holds one rule: nobody ends up less connected than before.
// The Gateway key, the Dashboard sign-in, the active instance and its
// read-only flag are never touched; only `bridge_*` leftovers are deleted,
// and only after what was learned is stored.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/legacy_bridge_retirement.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};

  /// Set to a Keystore method name to make the next call of it throw once:
  /// the closest a test gets to the process dying at that exact point.
  String? dieOn;
  final deleted = <String>[];

  setUp(() {
    secureStore.clear();
    deleted.clear();
    dieOn = null;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            if (dieOn == call.method) {
              dieOn = null;
              throw PlatformException(code: 'killed');
            }
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'delete':
                deleted.add(args['key'] as String);
                secureStore.remove(args['key'] as String);
                return null;
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
  });

  /// One saved connection as ≤ 1.2.14 wrote it: metadata in preferences,
  /// secrets in the Keystore, the bridge alongside.
  Map<String, dynamic> saved(
    String id, {
    String host = '192.168.1.40',
    int port = 8642,
    String? kind = 'homelab',
    bool readOnly = false,
    String? dashboardUrl,
    String dashboardAuthMode = 'basic',
  }) => {
    'id': id,
    'label': 'Hermes $id',
    'host': host,
    'port': port,
    'use_https': false,
    'kind': ?kind,
    'read_only': readOnly,
    'dashboard_url': ?dashboardUrl,
    'dashboard_auth_mode': dashboardAuthMode,
  };

  void bridgeEra(String id, {bool dashboardLogin = false}) {
    secureStore['api_key_$id'] = 'gateway-key-$id';
    secureStore[LegacyBridgeRetirement.legacyUrlKey(id)] =
        'http://192.168.1.40:9131';
    secureStore[LegacyBridgeRetirement.legacyTokenKey(id)] = 'bridge-$id';
    if (dashboardLogin) {
      secureStore['dash_user_$id'] = 'admin';
      secureStore['dash_pass_$id'] = 'dashboard-pass-$id';
    }
  }

  Future<ConnectionManager> phone(
    List<Map<String, dynamic>> connections, {
    String? active,
  }) async {
    SharedPreferences.setMockInitialValues({
      'saved_connections': [for (final c in connections) jsonEncode(c)],
      'last_connection_id': ?active,
      LegacyBridgeRetirement.legacyPreference: true,
      'onboarding_done': true,
    });
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    return manager;
  }

  Map<String, String> bridgeLeftovers() => {
    for (final entry in secureStore.entries)
      if (entry.key.startsWith('bridge_')) entry.key: entry.value,
  };

  Map<String, String> ownSecrets() => {
    for (final entry in secureStore.entries)
      if (!entry.key.startsWith('bridge_')) entry.key: entry.value,
  };

  test('paired through the bridge and fully configured: nothing to do but '
      'say the bridge can go', () async {
    bridgeEra('c1', dashboardLogin: true);
    final manager = await phone([
      saved('c1', dashboardUrl: 'http://192.168.1.40:9119'),
    ], active: 'c1');
    final before = ownSecrets();
    final requests = <String>[];
    final work = LegacyBridgeRetirement(
      prefs: manager.prefs,
      // The real probe, against a Dashboard that accepts this phone's login.
      probe: (connection) => probeDashboardAccess(
        connection,
        httpClient: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          if (request.url.path == '/api/status') {
            return http.Response('{"auth_required": true}', 200);
          }
          if (request.url.path == '/auth/password-login') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (body['username'] == 'admin' &&
                body['password'] == 'dashboard-pass-c1') {
              return http.Response(
                '{"ok": true}',
                200,
                headers: {'set-cookie': 'hermes_session_at=AT1; Path=/'},
              );
            }
            return http.Response('{"error": "invalid_credentials"}', 401);
          }
          if (request.url.path == '/api/auth/me') {
            return request.headers['cookie']?.contains('hermes_session_at') ==
                    true
                ? http.Response('{"user": "admin"}', 200)
                : http.Response('{}', 401);
          }
          return http.Response('{}', 404);
        }),
      ),
    );

    await work.run(manager.getConnections());

    expect(work.access, {'c1': DashboardAccess.ready});
    expect(requests.where((r) => r.contains('/bridge')), isEmpty);
    expect(bridgeLeftovers(), isEmpty);
    expect(ownSecrets(), before);
    final connection = manager.getConnections().single;
    expect(connection.apiKey, 'gateway-key-c1');
    expect(connection.gatewayUrl, 'http://192.168.1.40:8642');
    expect(connection.effectiveDashboardUrl, 'http://192.168.1.40:9119');
    expect(manager.prefs.getString(ConnectionManager.lastConnKey), 'c1');
    expect(work.signInCandidate(manager.getConnections(), 'c1'), isNull);
    expect(work.shouldOfferRemoval(manager.getConnections()), isTrue);
  });

  test('paired but never had a Dashboard sign-in: still connected to the '
      'Gateway, told the one step that is left', () async {
    bridgeEra('c1');
    final manager = await phone([saved('c1')], active: 'c1');
    final before = ownSecrets();
    final work = LegacyBridgeRetirement(
      prefs: manager.prefs,
      probe: (connection) => probeDashboardAccess(
        connection,
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/status') {
            return http.Response('{"auth_required": true}', 200);
          }
          return http.Response('{"error": "unauthorized"}', 401);
        }),
      ),
    );

    await work.run(manager.getConnections());

    expect(work.access, {'c1': DashboardAccess.needsSignIn});
    expect(bridgeLeftovers(), isEmpty);
    expect(ownSecrets(), before);
    expect(manager.getConnections().single.apiKey, 'gateway-key-c1');
    expect(manager.prefs.getString(ConnectionManager.lastConnKey), 'c1');
    expect(work.signInCandidate(manager.getConnections(), 'c1')?.id, 'c1');
    // The bridge is not said to be removable while a step is still pending.
    expect(work.shouldOfferRemoval(manager.getConnections()), isFalse);

    // Signing in is what solves it; then, and only then, the bridge can go.
    await manager.setDashboardSecrets('c1', username: 'admin', password: 'p');
    await work.markSignInNoticeDone('c1', solved: true);
    expect(work.signInCandidate(manager.getConnections(), 'c1'), isNull);
    expect(work.shouldOfferRemoval(manager.getConnections()), isTrue);
    expect(manager.getConnections().single.apiKey, 'gateway-key-c1');
  });

  test('an instance on the phone\'s own loopback: its saved address moves to '
      'the Dashboard, and it is treated like any other', () async {
    bridgeEra('local');
    // ≤ 1.2.14 saved a Hermes reached on the phone's own loopback as
    // 127.0.0.1:8642 with the localhost kind (or none at all).
    final manager = await phone([
      saved(
        'local',
        host: '127.0.0.1',
        kind: 'localhost',
        dashboardAuthMode: 'cookie_session',
      ),
    ], active: 'local');
    final connection = manager.getConnections().single;
    // Its chat goes through Hermes' own Dashboard, so the address is
    // rewritten once to its port; the key is kept.
    expect(connection.onDeviceLoopback, isTrue);
    expect(connection.gatewayUrl, 'http://127.0.0.1:9119');
    expect(connection.effectiveDashboardUrl, 'http://127.0.0.1:9119');
    expect(connection.apiKey, 'gateway-key-local');
    final stored =
        jsonDecode(manager.prefs.getStringList('saved_connections')!.single)
            as Map<String, dynamic>;
    expect(stored['port'], 9119);
    expect(stored['dashboard_url'], 'http://127.0.0.1:9119');

    // Nothing answers on 127.0.0.1:9119: no verdict, so nothing is said.
    final work = LegacyBridgeRetirement(
      prefs: manager.prefs,
      probe: (connection) => probeDashboardAccess(
        connection,
        httpClient: MockClient(
          (_) async => throw http.ClientException('Connection refused'),
        ),
      ),
    );
    await work.run(manager.getConnections());

    expect(work.access, {'local': DashboardAccess.unknown});
    expect(work.signInCandidate(manager.getConnections(), 'local'), isNull);
    expect(work.shouldOfferRemoval(manager.getConnections()), isFalse);
    expect(manager.getConnections().single.apiKey, 'gateway-key-local');
    expect(bridgeLeftovers(), isEmpty);

    // Once it runs (on loopback it asks for no sign-in), the next launch
    // finds it and there is nothing left to say but that the bridge can go.
    final later = LegacyBridgeRetirement(
      prefs: manager.prefs,
      probe: (connection) => probeDashboardAccess(
        connection,
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/status') {
            return http.Response('{"auth_required": false}', 200);
          }
          if (request.url.path == '/api/profiles') {
            return http.Response('{"profiles": []}', 200);
          }
          // The page of a Dashboard that asks for no sign-in carries the
          // session token its own web UI uses.
          return http.Response(
            '<script>window.__HERMES_SESSION_TOKEN__="on-device";</script>',
            200,
          );
        }),
      ),
    );
    await later.run(manager.getConnections());
    expect(later.access, {'local': DashboardAccess.ready});
    expect(later.shouldOfferRemoval(manager.getConnections()), isTrue);
  });

  test('an instance that does not answer gets no notice', () async {
    bridgeEra('c1');
    final manager = await phone([saved('c1')], active: 'c1');
    final work = LegacyBridgeRetirement(
      prefs: manager.prefs,
      probe: (_) async => DashboardAccess.unknown,
    );
    await work.run(manager.getConnections());
    expect(work.access, {'c1': DashboardAccess.unknown});
    expect(work.signInCandidate(manager.getConnections(), 'c1'), isNull);
    expect(work.shouldOfferRemoval(manager.getConnections()), isFalse);
    expect(manager.getConnections().single.apiKey, 'gateway-key-c1');
  });

  test('several instances, mixed: each keeps what it had and gets its own '
      'verdict; the active one is said first', () async {
    bridgeEra('ready', dashboardLogin: true);
    bridgeEra('nologin');
    bridgeEra('away', dashboardLogin: true);
    secureStore['api_key_never'] =
        'gateway-key-never'; // added after, no bridge
    secureStore['api_key_readonly'] = 'gateway-key-readonly';
    secureStore[LegacyBridgeRetirement.legacyTokenKey('readonly')] = 'bridge';
    final manager = await phone([
      saved('ready', host: '192.168.1.41'),
      saved('nologin', host: '192.168.1.42'),
      saved('away', host: '192.168.1.43'),
      saved('never', host: '192.168.1.44'),
      saved('readonly', host: '192.168.1.45', readOnly: true),
    ], active: 'readonly');
    final before = ownSecrets();
    const verdicts = {
      'ready': DashboardAccess.ready,
      'nologin': DashboardAccess.needsSignIn,
      'away': DashboardAccess.unknown,
      'never': DashboardAccess.ready,
      'readonly': DashboardAccess.needsSignIn,
    };
    final work = LegacyBridgeRetirement(
      prefs: manager.prefs,
      probe: (connection) async => verdicts[connection.id]!,
    );

    await work.run(manager.getConnections());

    expect(work.access, verdicts);
    expect(bridgeLeftovers(), isEmpty);
    expect(ownSecrets(), before);
    final after = {for (final c in manager.getConnections()) c.id: c};
    expect(after.keys, ['ready', 'nologin', 'away', 'never', 'readonly']);
    for (final connection in after.values) {
      expect(connection.apiKey, 'gateway-key-${connection.id}');
      expect(connection.port, 8642);
    }
    expect(manager.prefs.getString(ConnectionManager.lastConnKey), 'readonly');
    // Read-only is a promise to the user: an update never lifts it.
    expect(after['readonly']!.readOnly, isTrue);
    expect(after['ready']!.readOnly, isFalse);
    // The active instance is the one said first; then the other.
    expect(
      work.signInCandidate(manager.getConnections(), 'readonly')?.id,
      'readonly',
    );
    await work.markSignInNoticeDone('readonly', solved: true);
    expect(
      work.signInCandidate(manager.getConnections(), 'readonly')?.id,
      'nologin',
    );
    expect(work.shouldOfferRemoval(manager.getConnections()), isFalse);
    await work.markSignInNoticeDone('nologin');
    expect(work.shouldOfferRemoval(manager.getConnections()), isTrue);
    expect(manager.getConnections().last.readOnly, isTrue);
  });

  test('a legacy code pasted again after the update finds the same instance '
      'and brings no bridge back', () async {
    bridgeEra('c1', dashboardLogin: true);
    final manager = await phone([
      saved('c1', dashboardUrl: 'http://192.168.1.40:9119'),
    ], active: 'c1');
    final work = LegacyBridgeRetirement(
      prefs: manager.prefs,
      probe: (_) async => DashboardAccess.ready,
    );
    await work.run(manager.getConnections());
    final before = Map<String, String>.from(secureStore);

    // What the bridge-era installer printed, kept in a note or a screenshot.
    final link = PairingLink.tryParse(
      'hermes://pair?host=192.168.1.40&port=8642&token=gateway-key-c1'
      '&dashboard=http%3A%2F%2F192.168.1.40%3A9119'
      '&bridge=http%3A%2F%2F192.168.1.40%3A9131&bridge_token=gateway-key-c1',
    )!;
    expect(link.hasDashboardLogin, isFalse);
    expect(link.build(), isNot(contains('bridge')));
    final draft = link.toDraftConnection();
    final existing = manager.findConnectionByEndpoint(
      host: draft.host,
      port: draft.port,
      useHttps: draft.useHttps,
    );
    expect(existing?.id, 'c1', reason: 'the same server is not added twice');

    // Accepting it updates that instance; its sign-in is not the link's to
    // erase and nothing of the bridge is written again.
    await manager.upsertConnection(
      existing!.copyWith(
        apiKey: draft.apiKey,
        dashboardUrl: draft.dashboardUrl,
      ),
    );
    expect(manager.getConnections(), hasLength(1));
    expect(secureStore, before);
    expect(bridgeLeftovers(), isEmpty);
    expect(secureStore['dash_pass_c1'], 'dashboard-pass-c1');

    // And the migration, having finished, never looks again.
    var probes = 0;
    final again = LegacyBridgeRetirement(
      prefs: manager.prefs,
      probe: (_) async {
        probes++;
        return DashboardAccess.needsSignIn;
      },
    );
    await again.run(manager.getConnections());
    expect(probes, 0);
    expect(again.access, {'c1': DashboardAccess.ready});
  });

  group('the app killed in the middle of the migration', () {
    Future<ConnectionManager> legacyPhone() async {
      bridgeEra('c1');
      return phone([saved('c1')], active: 'c1');
    }

    test('before the probe answered: nothing was deleted, and the next launch '
        'starts over', () async {
      final manager = await legacyPhone();
      final killed = LegacyBridgeRetirement(
        prefs: manager.prefs,
        probe: (_) => throw StateError('process died'),
      );
      // A probe that throws is "no verdict"; a real kill never returns at
      // all, which leaves even less behind. Either way:
      await killed.run(manager.getConnections());
      expect(killed.legacyInstall, isTrue);

      final next = LegacyBridgeRetirement(
        prefs: manager.prefs,
        probe: (_) async => DashboardAccess.needsSignIn,
      );
      await next.run(manager.getConnections());
      expect(next.access, {'c1': DashboardAccess.needsSignIn});
      expect(next.signInCandidate(manager.getConnections(), 'c1')?.id, 'c1');
      expect(manager.getConnections().single.apiKey, 'gateway-key-c1');
    });

    test('after the verdict was stored and before anything was deleted: the '
        'verdict survives and the leftovers go on the next launch', () async {
      final manager = await legacyPhone();
      final killed = LegacyBridgeRetirement(
        prefs: manager.prefs,
        probe: (_) async {
          // The first Keystore sweep after the probe is the deletion: the
          // process dies exactly there.
          dieOn = 'readAll';
          return DashboardAccess.needsSignIn;
        },
      );
      await expectLater(
        killed.run(manager.getConnections()),
        throwsA(isA<PlatformException>()),
      );
      // Nothing was deleted, and what was learned is already on disk.
      expect(deleted, isEmpty);
      expect(bridgeLeftovers(), hasLength(2));
      expect(killed.leftoversDeleted, isFalse);
      expect(killed.legacyInstall, isTrue);
      expect(killed.access, {'c1': DashboardAccess.needsSignIn});

      var probes = 0;
      final next = LegacyBridgeRetirement(
        prefs: manager.prefs,
        probe: (_) async {
          probes++;
          return DashboardAccess.ready;
        },
      );
      await next.run(manager.getConnections());
      expect(probes, 0, reason: 'the stored verdict is not asked for again');
      expect(next.access, {'c1': DashboardAccess.needsSignIn});
      expect(next.leftoversDeleted, isTrue);
      expect(bridgeLeftovers(), isEmpty);
      expect(manager.prefs.containsKey('bridge_auto_update'), isFalse);
      expect(next.signInCandidate(manager.getConnections(), 'c1')?.id, 'c1');
      expect(manager.getConnections().single.apiKey, 'gateway-key-c1');
    });

    test('half-way through the deletion: the rest goes on the next launch '
        'and the notice is still owed', () async {
      final manager = await legacyPhone();
      final killed = LegacyBridgeRetirement(
        prefs: manager.prefs,
        probe: (_) async {
          dieOn = 'delete';
          return DashboardAccess.needsSignIn;
        },
      );
      await expectLater(
        killed.run(manager.getConnections()),
        throwsA(isA<PlatformException>()),
      );
      expect(killed.leftoversDeleted, isFalse);
      expect(killed.access, {'c1': DashboardAccess.needsSignIn});

      // The leftovers are gone or half gone: they are no longer what tells
      // the app this was a bridge-era install. The stored state is.
      secureStore.removeWhere((key, _) => key.startsWith('bridge_'));
      final next = LegacyBridgeRetirement(
        prefs: manager.prefs,
        probe: (_) async => fail('already has its verdict'),
      );
      await next.run(manager.getConnections());
      expect(next.legacyInstall, isTrue);
      expect(next.leftoversDeleted, isTrue);
      expect(next.signInCandidate(manager.getConnections(), 'c1')?.id, 'c1');
      expect(ownSecrets(), {'api_key_c1': 'gateway-key-c1'});
    });

    test('a finished migration costs nothing on later launches', () async {
      final manager = await legacyPhone();
      final first = LegacyBridgeRetirement(
        prefs: manager.prefs,
        probe: (_) async => DashboardAccess.ready,
      );
      await first.run(manager.getConnections());
      expect(first.leftoversDeleted, isTrue);

      // Any Keystore read at all would throw here.
      dieOn = 'readAll';
      final later = LegacyBridgeRetirement(
        prefs: manager.prefs,
        probe: (_) async => fail('nothing left to learn'),
      );
      await later.run(manager.getConnections());
      await later.run(manager.getConnections());
      expect(dieOn, 'readAll', reason: 'the Keystore was not swept again');
      expect(later.access, {'c1': DashboardAccess.ready});
    });
  });
}
