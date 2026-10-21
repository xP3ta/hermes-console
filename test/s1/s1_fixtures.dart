// SPDX-License-Identifier: GPL-3.0-only
// S1 fixtures: a Dashboard stand-in whose refresh endpoint ROTATES like the
// official `nous` provider (every refresh invalidates the previous one; a
// rotated refresh is answered from a 30 s cache and revokes the whole family
// after that), and a stateless `basic`-like mode. Synthetic tokens only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';

class FakeClock {
  FakeClock([DateTime? start]) : _now = start ?? DateTime.utc(2026, 10, 18, 12);
  DateTime _now;
  DateTime call() => _now;
  int get seconds => _now.millisecondsSinceEpoch ~/ 1000;
  void advance(Duration d) => _now = _now.add(d);
}

/// 0 = initial login pair (`test-at-0` / `test-rt-0`), n = n-th rotation.
String accessN(int n) => 'test-at-$n';
String refreshN(int n) => 'test-rt-$n';

class RotatingDashboard {
  RotatingDashboard({this.nous = true, FakeClock? clock, this.live = false})
    : clock = clock ?? FakeClock();

  /// `nous`: rotating refresh with reuse detection. Otherwise stateless
  /// (`basic`: any refresh the server ever issued keeps working).
  final bool nous;
  final FakeClock clock;

  /// Use the wall clock (client-level tests that cannot inject one).
  final bool live;
  late HttpServer server;
  String get base => 'http://127.0.0.1:${server.port}';

  int refreshCalls = 0;
  int rotations = 0;
  bool revoked = false;
  int? failStatus; // answer /auth/native/refresh with this status
  Completer<void>? hold; // park the refresh response until completed
  final reached = Completer<void>(); // first refresh request arrived
  final pings = <String>[]; // access tokens seen on /api/ping
  final orderViolations = <String>[];

  /// Reports the rev currently persisted by the client (order check).
  int Function()? persistedRev;

  final _issuedRefresh = <String>{refreshN(0)};
  String _currentRefresh = refreshN(0);
  String _currentAccess = accessN(0);
  Map<String, Object?>? _lastRotationBody;
  String? _previousRefresh;
  DateTime? _rotatedAt;

  DateTime get _now => live ? DateTime.now() : clock();
  int get nowSeconds => _now.millisecondsSinceEpoch ~/ 1000;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen(_handle);
  }

  Future<void> _json(HttpRequest r, int code, Object o) async {
    r.response.statusCode = code;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(o));
    await r.response.close();
  }

  Map<String, Object?> _rotate() {
    rotations += 1;
    _previousRefresh = _currentRefresh;
    _currentRefresh = refreshN(rotations);
    _currentAccess = accessN(rotations);
    _issuedRefresh.add(_currentRefresh);
    _rotatedAt = _now;
    return _lastRotationBody = {
      'token_type': 'Bearer',
      'access_token': _currentAccess,
      'refresh_token': _currentRefresh,
      'expires_at': nowSeconds + 3600,
      'provider': nous ? 'nous' : 'basic',
      'user_id': 'u1',
    };
  }

  Future<void> _handle(HttpRequest r) async {
    final body = await utf8.decoder.bind(r).join();
    if (r.uri.path == '/auth/native/refresh' && r.method == 'POST') {
      refreshCalls += 1;
      if (!reached.isCompleted) reached.complete();
      final parked = hold;
      if (parked != null) await parked.future;
      if (failStatus != null) {
        return _json(r, failStatus!, {'detail': 'provider unreachable'});
      }
      final sent = (jsonDecode(body) as Map)['refresh_token'];
      if (revoked) return _expired(r);
      if (!nous) {
        if (!_issuedRefresh.contains(sent)) return _expired(r);
        return _json(r, 200, _rotate());
      }
      if (sent == _currentRefresh) return _json(r, 200, _rotate());
      if (sent == _previousRefresh &&
          _rotatedAt != null &&
          _now.difference(_rotatedAt!) <= const Duration(seconds: 30)) {
        return _json(r, 200, _lastRotationBody!); // 30 s single-flight cache
      }
      revoked = true; // reuse of a rotated refresh revokes the family
      return _expired(r);
    }
    if (r.uri.path == '/api/ping') {
      final auth = r.headers.value('authorization');
      final access = auth?.startsWith('Bearer ') == true
          ? auth!.substring(7)
          : '';
      if (revoked || access != _currentAccess) {
        return _json(r, 401, {'error': 'unauthorized'});
      }
      pings.add(access);
      final n = int.tryParse(access.replaceFirst('test-at-', '')) ?? 0;
      final rev = persistedRev?.call();
      if (n > 0 && rev != null && rev < n) {
        orderViolations.add('access $n used while the store held rev $rev');
      }
      return _json(r, 200, {'ok': true});
    }
    await _json(r, 404, {});
  }

  Future<void> _expired(HttpRequest r) =>
      _json(r, 401, {'error': 'session_expired'});

  /// The envelope a login would have left: access already expired, refresh 0.
  String envelope(
    String connectionId, {
    bool expired = true,
    int rev = 0,
    bool withRefresh = true,
    int? expiresAt,
  }) => MobileOAuthSession(
    connectionId: connectionId,
    baseUrl: base,
    accessToken: accessN(0),
    expiresAt: expiresAt ?? (expired ? nowSeconds - 10 : nowSeconds + 3600),
    provider: nous ? 'nous' : 'basic',
    userId: 'u1',
    refreshToken: withRefresh ? refreshN(0) : null,
    rev: rev,
  ).encode();
}

/// flutter_secure_storage stand-in plus the durable-flush channel.
class SecureChannelFake {
  final storage = <String, String>{};
  int flushes = 0;
  bool failFlush = false;
  bool failTokenWrite = false;
  void install() {
    const secure = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    const durable = MethodChannel('hermes/durable_secrets');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secure, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String?;
      switch (call.method) {
        case 'write':
          if (failTokenWrite && key!.startsWith('dash_token_')) {
            throw PlatformException(code: 'write-failed');
          }
          storage[key!] = args['value'] as String;
          return null;
        case 'read':
          return storage[key];
        case 'readAll':
          return storage;
        case 'delete':
          storage.remove(key);
          return null;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(durable, (call) async {
      if (call.method == 'flush') {
        flushes += 1;
        return !failFlush;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(secure, null);
      messenger.setMockMethodCallHandler(durable, null);
    });
  }
}
