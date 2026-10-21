// SPDX-License-Identifier: GPL-3.0-only
// S1 (coordinator level): the rotation order, the epoch, the cooldown, the
// process-wide single refresher and what survives a kill mid-rotation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';
import 'package:hermes_android/core/services/native_session_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 's1_fixtures.dart';

class MemStore implements NativeEnvelopeStore {
  final slots = <String, String>{};
  int writes = 0;
  int failWrites = 0; // next N writeDurable calls throw
  int dropWrites = 0; // next N writes are acknowledged but never persisted
  @override
  Future<String?> read(String id) async => slots[id];
  @override
  Future<void> writeDurable(String id, String raw) async {
    writes += 1;
    if (failWrites > 0) {
      failWrites -= 1;
      throw StateError('disk full');
    }
    if (dropWrites > 0) {
      dropWrites -= 1;
      return;
    }
    slots[id] = raw;
  }

  @override
  Future<void> delete(String id) async => slots.remove(id);
}

/// A store two isolates share: one file per connection.
class FileStore implements NativeEnvelopeStore {
  FileStore(this.dir);
  final String dir;
  File _f(String id) => File('$dir/$id.env');
  @override
  Future<String?> read(String id) async =>
      _f(id).existsSync() ? _f(id).readAsStringSync() : null;
  @override
  Future<void> writeDurable(String id, String raw) async =>
      _f(id).writeAsStringSync(raw, flush: true);
  @override
  Future<void> delete(String id) async {
    if (_f(id).existsSync()) _f(id).deleteSync();
  }
}

class MapRegistry implements NativeRefreshPortRegistry {
  final names = <String, SendPort>{};
  @override
  bool register(String name, SendPort port) {
    if (names.containsKey(name)) return false;
    names[name] = port;
    return true;
  }

  @override
  SendPort? lookup(String name) => names[name];
  @override
  void unregister(String name) => names.remove(name);
}

class Killed implements Exception {}

var _ports = 0;
NativeSessionCoordinator _coordinator(
  NativeEnvelopeStore store,
  RotatingDashboard d, {
  NativeRefreshPortRegistry? registry,
}) {
  final c = NativeSessionCoordinator(
    store: store,
    now: d.clock.call,
    registry: registry ?? MapRegistry(),
    portName: 'test.s1.${_ports++}',
    forwardTimeout: const Duration(seconds: 2),
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> _isolateMain(List<Object> a) async {
  final reply = a[0] as SendPort;
  try {
    final c = NativeSessionCoordinator(
      store: FileStore(a[2] as String),
      portName: a[3] as String,
    );
    final access = await c.ensureAccess(a[4] as String, a[1] as String);
    c.dispose();
    reply.send(access.accessToken);
  } catch (e) {
    reply.send('ERR ${e.runtimeType}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  const base = 's1c';
  late RotatingDashboard d;
  late MemStore store;
  Future<void> setUpDashboard({bool nous = true}) async {
    d = RotatingDashboard(nous: nous);
    await d.start();
    store = MemStore();
  }

  test('two engines racing for an expired access: ONE refresh in the whole '
      'process (real IsolateNameServer, real second isolate)', () async {
    d = RotatingDashboard(live: true);
    await d.start();
    final dir = Directory.systemTemp.createTempSync('s1-iso');
    addTearDown(() => dir.deleteSync(recursive: true));
    final files = FileStore(dir.path);
    const id = 's1-iso';
    await files.writeDurable(id, d.envelope(id));
    d.hold = Completer<void>(); // keep the answer parked so both ask
    final name = 'test.s1.real.${DateTime.now().microsecondsSinceEpoch}';
    final mine = NativeSessionCoordinator(store: files, portName: name);
    addTearDown(mine.dispose);
    final answer = ReceivePort();
    await Isolate.spawn(_isolateMain, [
      answer.sendPort,
      d.base,
      dir.path,
      name,
      id,
    ]);
    final first = mine.ensureAccess(id, d.base);
    await d.reached.future;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    d.hold!.complete();
    final other = await answer.first.timeout(const Duration(seconds: 20));
    final access = await first.timeout(const Duration(seconds: 20));
    expect(d.refreshCalls, 1);
    expect(access.accessToken, accessN(1));
    expect(other, accessN(1));
    final stored = MobileOAuthSession.decode(await files.read(id), id, d.base)!;
    expect(stored.rev, 1);
  });

  test('a second engine (same registry) asks the owner, never refreshes '
      'itself', () async {
    await setUpDashboard();
    const id = '${base}2';
    store.slots[id] = d.envelope(id);
    final registry = MapRegistry();
    final a = _coordinator(store, d, registry: registry);
    final b = NativeSessionCoordinator(
      store: store,
      now: d.clock.call,
      registry: registry,
      portName: a.portName,
    );
    addTearDown(b.dispose);
    final results = await Future.wait([
      a.ensureAccess(id, d.base),
      b.ensureAccess(id, d.base),
      b.ensureAccess(id, d.base),
    ]);
    expect(d.refreshCalls, 1);
    expect(results.map((r) => r.accessToken).toSet(), {accessN(1)});
  });

  test('an owner that stopped answering leaves a transient error, never a '
      'refresh from the asker; the stale name is freed', () async {
    await setUpDashboard();
    const id = '${base}3';
    store.slots[id] = d.envelope(id);
    final registry = MapRegistry();
    final dead = ReceivePort(); // registered, nobody serves it
    registry.register('test.s1.dead', dead.sendPort);
    addTearDown(dead.close);
    final b = NativeSessionCoordinator(
      store: store,
      now: d.clock.call,
      registry: registry,
      portName: 'test.s1.dead',
      forwardTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(b.dispose);
    await expectLater(
      b.ensureAccess(id, d.base),
      throwsA(isA<NativeRefreshTransient>()),
    );
    expect(d.refreshCalls, 0);
    expect(registry.lookup('test.s1.dead'), isNull);
    // Next cycle: this engine claims the name and refreshes.
    expect((await b.ensureAccess(id, d.base)).accessToken, accessN(1));
    expect(d.refreshCalls, 1);
  });

  test('the new refresh is on disk before the access is published; a failed '
      'write publishes nothing and leaves the old envelope', () async {
    await setUpDashboard();
    const id = '${base}4';
    final old = d.envelope(id);
    store.slots[id] = old;
    final c = _coordinator(store, d);

    store.failWrites = 2; // the write and its single retry both fail
    await expectLater(
      c.ensureAccess(id, d.base),
      throwsA(isA<NativeSessionStorageUnavailable>()),
    );
    expect(store.slots[id], old, reason: 'old envelope intact');
    expect(d.refreshCalls, 1);

    // The server already rotated (single-use refresh): the retry writes the
    // held result instead of spending refresh 0 a second time.
    final ok = await c.ensureAccess(id, d.base);
    expect(ok.accessToken, accessN(1));
    expect(d.refreshCalls, 1);
    expect(
      MobileOAuthSession.decode(store.slots[id], id, d.base)!.refreshToken,
      refreshN(1),
    );
  });

  test('one failed write is retried once in the same call', () async {
    await setUpDashboard();
    const id = '${base}4b';
    store.slots[id] = d.envelope(id);
    final c = _coordinator(store, d);
    store.failWrites = 1;
    expect((await c.ensureAccess(id, d.base)).accessToken, accessN(1));
    expect(d.refreshCalls, 1);
    expect(store.writes, 2);
  });

  test(
    'a write acknowledged but not persisted (apply()) is not trusted',
    () async {
      await setUpDashboard();
      const id = '${base}4c';
      final old = d.envelope(id);
      store.slots[id] = old;
      final c = _coordinator(store, d);
      store.dropWrites = 2;
      await expectLater(
        c.ensureAccess(id, d.base),
        throwsA(isA<NativeSessionStorageUnavailable>()),
      );
      expect(store.slots[id], old);
    },
  );

  group('killed between the server answer and the write', () {
    test('basic (stateless refresh): the relaunch simply works', () async {
      await setUpDashboard(nous: false);
      const id = '${base}5a';
      store.slots[id] = d.envelope(id);
      final first = _coordinator(store, d)
        ..debugAfterServerAnswer = () async => throw Killed();
      await expectLater(first.ensureAccess(id, d.base), throwsA(isA<Killed>()));
      first.dispose();
      final relaunched = _coordinator(store, d);
      d.clock.advance(const Duration(minutes: 5));
      expect(
        (await relaunched.ensureAccess(id, d.base)).accessToken,
        accessN(2),
      );
      expect(d.refreshCalls, 2);
    });

    test(
      'nous within the 30 s cache: the server answers the same pair',
      () async {
        await setUpDashboard();
        const id = '${base}5b';
        store.slots[id] = d.envelope(id);
        final first = _coordinator(store, d)
          ..debugAfterServerAnswer = () async => throw Killed();
        await expectLater(
          first.ensureAccess(id, d.base),
          throwsA(isA<Killed>()),
        );
        first.dispose();
        d.clock.advance(const Duration(seconds: 10));
        final relaunched = _coordinator(store, d);
        expect(
          (await relaunched.ensureAccess(id, d.base)).accessToken,
          accessN(1),
        );
      },
    );

    test('nous after +31 s: exactly ONE expired session, no loop', () async {
      await setUpDashboard();
      const id = '${base}5c';
      store.slots[id] = d.envelope(id);
      final first = _coordinator(store, d)
        ..debugAfterServerAnswer = () async => throw Killed();
      await expectLater(first.ensureAccess(id, d.base), throwsA(isA<Killed>()));
      first.dispose();
      d.clock.advance(const Duration(seconds: 31));
      final relaunched = _coordinator(store, d);
      for (var i = 0; i < 5; i++) {
        await expectLater(
          relaunched.ensureAccess(id, d.base),
          throwsA(isA<NativeSessionExpired>()),
        );
      }
      expect(d.refreshCalls, 2, reason: 'the cut one + ONE rejected');
      expect(store.slots[id], isNull, reason: 'dead session dropped once');
    });
  });

  test('503: envelope kept, never "expired", 60 s cooldown honoured', () async {
    await setUpDashboard();
    const id = '${base}6';
    final env = d.envelope(id);
    store.slots[id] = env;
    final c = _coordinator(store, d);
    d.failStatus = 503;
    await expectLater(
      c.ensureAccess(id, d.base),
      throwsA(isA<NativeRefreshTransient>()),
    );
    expect(store.slots[id], env);
    expect(d.refreshCalls, 1);
    d.clock.advance(const Duration(seconds: 59));
    d.failStatus = null;
    await expectLater(
      c.ensureAccess(id, d.base),
      throwsA(isA<NativeRefreshTransient>()),
    );
    expect(d.refreshCalls, 1, reason: 'cooldown: server not called');
    d.clock.advance(const Duration(seconds: 2));
    expect((await c.ensureAccess(id, d.base)).accessToken, accessN(1));
    expect(d.refreshCalls, 2);
  });

  test('a login while an old refresh is in flight: the old result is '
      'discarded and never overwrites the new session', () async {
    await setUpDashboard();
    const id = '${base}7';
    store.slots[id] = d.envelope(id);
    final c = _coordinator(store, d);
    d.hold = Completer<void>();
    final pending = c.ensureAccess(id, d.base);
    await d.reached.future;
    final login = MobileOAuthSession(
      connectionId: id,
      baseUrl: d.base,
      accessToken: 'test-at-login',
      expiresAt: d.clock.seconds + 3600,
      provider: 'nous',
      userId: 'u1',
      refreshToken: 'test-rt-login',
      rev: 0,
    ).encode();
    await c.storeAfterLogin(id, login);
    d.hold!.complete();
    final got = await pending;
    expect(got.accessToken, 'test-at-login');
    expect(store.slots[id], login);
    expect(d.refreshCalls, 1);
  });

  test('a login made by ANOTHER engine mid-flight is not overwritten '
      '(compare-and-swap on the stored refresh)', () async {
    await setUpDashboard();
    const id = '${base}7b';
    store.slots[id] = d.envelope(id);
    final c = _coordinator(store, d);
    d.hold = Completer<void>();
    final pending = c.ensureAccess(id, d.base);
    await d.reached.future;
    final login = MobileOAuthSession(
      connectionId: id,
      baseUrl: d.base,
      accessToken: 'test-at-login',
      expiresAt: d.clock.seconds + 3600,
      provider: 'nous',
      userId: 'u1',
      refreshToken: 'test-rt-login',
      rev: 0,
    ).encode();
    store.slots[id] = login; // written by another engine, no epoch here
    d.hold!.complete();
    final got = await pending;
    expect(got.accessToken, 'test-at-login');
    expect(store.slots[id], login);
  });

  test('invalidate() while a refresh is in flight (epoch): its result is '
      'dropped, nothing is written by it, the request retries once', () async {
    await setUpDashboard();
    const id = '${base}7c';
    store.slots[id] = d.envelope(id);
    final c = _coordinator(store, d);
    d.hold = Completer<void>();
    final pending = c.ensureAccess(id, d.base);
    await d.reached.future;
    c.invalidate(id); // e.g. the user signed out / in; the store is unchanged
    d.hold!.complete();
    final got = await pending;
    expect(got.accessToken, accessN(1));
    expect(d.refreshCalls, 2, reason: 'the discarded flight + the retry');
    expect(store.writes, 1, reason: 'only the retry wrote');
  });

  test('forceRefresh only rotates the access that was rejected', () async {
    await setUpDashboard();
    const id = '${base}8';
    store.slots[id] = d.envelope(id, expired: false);
    final c = _coordinator(store, d);
    final stale = await c.ensureAccess(
      id,
      d.base,
      forceRefresh: true,
      rejectedAccess: 'test-at-other',
    );
    expect(stale.accessToken, accessN(0));
    expect(d.refreshCalls, 0);
    final rotated = await c.ensureAccess(
      id,
      d.base,
      forceRefresh: true,
      rejectedAccess: accessN(0),
    );
    expect(rotated.accessToken, accessN(1));
    final again = await c.ensureAccess(
      id,
      d.base,
      forceRefresh: true,
      rejectedAccess: accessN(0),
    );
    expect(again.accessToken, accessN(1), reason: 'winner reused');
    expect(d.refreshCalls, 1);
  });

  test('renews inside the 60 s skew, not before', () async {
    await setUpDashboard();
    const id = '${base}9';
    store.slots[id] = d.envelope(
      id,
      expired: false,
      expiresAt: d.clock.seconds + 90,
    );
    final c = _coordinator(store, d);
    expect((await c.ensureAccess(id, d.base)).accessToken, accessN(0));
    d.clock.advance(const Duration(seconds: 31));
    expect((await c.ensureAccess(id, d.base)).accessToken, accessN(1));
  });

  test('v1 envelope (no refresh): used until it expires, then expired; the '
      'server is never asked', () async {
    await setUpDashboard();
    const id = '${base}10';
    final v1 = d.envelope(id, expired: false, withRefresh: false);
    store.slots[id] = v1;
    final c = _coordinator(store, d);
    expect((await c.ensureAccess(id, d.base)).accessToken, accessN(0));
    d.clock.advance(const Duration(hours: 2));
    await expectLater(
      c.ensureAccess(id, d.base),
      throwsA(isA<NativeSessionExpired>()),
    );
    expect(d.refreshCalls, 0);
    expect(store.slots[id], v1, reason: 'kept, not deleted');
  });

  test(
    'an unreadable envelope is kept for retry and reads as expired',
    () async {
      await setUpDashboard();
      const id = '${base}11';
      const junk = 'hermes-native-pkce-v1:{not json';
      store.slots[id] = junk;
      final c = _coordinator(store, d);
      await expectLater(
        c.ensureAccess(id, d.base),
        throwsA(isA<NativeSessionExpired>()),
      );
      expect(store.slots[id], junk);
      expect(d.refreshCalls, 0);
    },
  );

  test('a refresh answer for another user or without a next refresh is '
      'rejected as transient, nothing stored', () async {
    await setUpDashboard();
    const id = '${base}12';
    final env = d.envelope(id);
    store.slots[id] = env;
    final wrong = NativeSessionCoordinator(
      store: store,
      now: d.clock.call,
      registry: MapRegistry(),
      portName: 'test.s1.wrong',
      httpClient: () => MockClient(
        (_) async => http.Response(
          jsonEncode({
            'token_type': 'Bearer',
            'access_token': 'test-at-x',
            'expires_at': d.clock.seconds + 3600,
            'provider': 'nous',
            'user_id': 'someone-else',
            'refresh_token': 'test-rt-x',
          }),
          200,
        ),
      ),
    );
    addTearDown(wrong.dispose);
    await expectLater(
      wrong.ensureAccess(id, d.base),
      throwsA(isA<NativeRefreshTransient>()),
    );
    expect(store.slots[id], env);
  });
}
