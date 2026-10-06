import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/bridge_token_cache.dart';

void main() {
  late DateTime now;
  late List<String> calls;
  late List<String?> answers;

  BridgeTokenCache build({Duration ttl = const Duration(minutes: 30)}) =>
      BridgeTokenCache(
        ttl: ttl,
        now: () => now,
        provision: (url, key) async {
          calls.add('$url|$key');
          return answers.isEmpty ? 'tok-${calls.length}' : answers.removeAt(0);
        },
      );

  setUp(() {
    now = DateTime(2026, 10, 6, 12);
    calls = [];
    answers = [];
  });

  test('reuses the provisioned token for the same connection', () async {
    final cache = build();
    final a = await cache.token(
      connectionId: 'c1',
      bridgeUrl: 'http://h:9131',
      gatewayKey: 'k',
    );
    final b = await cache.token(
      connectionId: 'c1',
      bridgeUrl: 'http://h:9131',
      gatewayKey: 'k',
    );
    expect(a, 'tok-1');
    expect(b, 'tok-1');
    expect(calls, hasLength(1));
  });

  test('concurrent callers share one provision request', () async {
    final cache = build();
    final results = await Future.wait([
      for (var i = 0; i < 4; i++)
        cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k'),
    ]);
    expect(results.toSet(), {'tok-1'});
    expect(calls, hasLength(1));
  });

  test('provisions again after the token expires', () async {
    final cache = build(ttl: const Duration(minutes: 10));
    await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k');
    now = now.add(const Duration(minutes: 9));
    await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k');
    expect(calls, hasLength(1));
    now = now.add(const Duration(minutes: 2));
    final fresh = await cache.token(
      connectionId: 'c1',
      bridgeUrl: 'http://h',
      gatewayKey: 'k',
    );
    expect(fresh, 'tok-2');
    expect(calls, hasLength(2));
  });

  test('a different connection, URL or gateway key never shares a token',
      () async {
    final cache = build();
    await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k');
    await cache.token(connectionId: 'c2', bridgeUrl: 'http://h', gatewayKey: 'k');
    await cache.token(connectionId: 'c1', bridgeUrl: 'http://x', gatewayKey: 'k');
    await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k2');
    expect(calls, hasLength(4));
  });

  test('a failed provision is not cached as a token', () async {
    answers = [null, 'good'];
    final cache = build();
    expect(
      await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k'),
      isNull,
    );
    // Short back-off: an immediate retry does not hammer the bridge.
    expect(
      await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k'),
      isNull,
    );
    expect(calls, hasLength(1));
    now = now.add(BridgeTokenCache.failureBackoff + const Duration(seconds: 1));
    expect(
      await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k'),
      'good',
    );
    expect(calls, hasLength(2));
  });

  test('a thrown provision is not cached and reports null', () async {
    var throwOnce = true;
    final cache = BridgeTokenCache(
      now: () => now,
      provision: (url, key) async {
        calls.add(url);
        if (throwOnce) {
          throwOnce = false;
          throw Exception('offline');
        }
        return 'ok';
      },
    );
    expect(
      await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k'),
      isNull,
    );
    now = now.add(BridgeTokenCache.failureBackoff + const Duration(seconds: 1));
    expect(
      await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k'),
      'ok',
    );
  });

  test('withToken re-provisions once when the bridge answers 401', () async {
    final cache = build();
    final used = <String>[];
    final result = await cache.withToken<String>(
      connectionId: 'c1',
      bridgeUrl: 'http://h',
      gatewayKey: 'k',
      run: (token) async {
        used.add(token);
        if (token == 'tok-1') {
          throw const BridgeException(
            'http_401',
            'HTTP 401',
            kind: BridgeErrorKind.auth,
            status: 401,
          );
        }
        return 'done';
      },
    );
    expect(result, 'done');
    expect(used, ['tok-1', 'tok-2']);
    // The fresh token is the cached one from now on.
    expect(
      await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k'),
      'tok-2',
    );
    expect(calls, hasLength(2));
  });

  test('withToken does not retry on 403 or other failures', () async {
    final cache = build();
    var runs = 0;
    await expectLater(
      cache.withToken<void>(
        connectionId: 'c1',
        bridgeUrl: 'http://h',
        gatewayKey: 'k',
        run: (token) async {
          runs++;
          throw const BridgeException(
            'http_403',
            'HTTP 403',
            kind: BridgeErrorKind.auth,
            status: 403,
          );
        },
      ),
      throwsA(isA<BridgeException>()),
    );
    expect(runs, 1);
    expect(calls, hasLength(1));
  });

  test('withToken returns null without running when no token', () async {
    answers = [null];
    final cache = build();
    var runs = 0;
    final result = await cache.withToken<String>(
      connectionId: 'c1',
      bridgeUrl: 'http://h',
      gatewayKey: 'k',
      run: (_) async {
        runs++;
        return 'x';
      },
    );
    expect(result, isNull);
    expect(runs, 0);
  });

  test('invalidate drops only the matching stale token', () async {
    final cache = build();
    await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k');
    cache.invalidate('c1', staleToken: 'other');
    await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k');
    expect(calls, hasLength(1));
    cache.invalidate('c1', staleToken: 'tok-1');
    await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: 'k');
    expect(calls, hasLength(2));
  });

  test('an empty URL or gateway key never provisions', () async {
    final cache = build();
    expect(
      await cache.token(connectionId: 'c1', bridgeUrl: '', gatewayKey: 'k'),
      isNull,
    );
    expect(
      await cache.token(connectionId: 'c1', bridgeUrl: 'http://h', gatewayKey: ' '),
      isNull,
    );
    expect(calls, isEmpty);
  });
}
