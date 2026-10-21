// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'mobile_oauth.dart';
import 'secure_storage.dart';

/// One owner for native-session renewals, copied from Hermes Desktop's
/// `createNativeAccessTokenCoordinator` (apps/desktop/electron/
/// native-access-token.ts): a single flight per connection, an epoch that
/// discards a refresh finishing after a login/logout, and the rotated refresh
/// persisted BEFORE the new access is handed out. Unlike Desktop, Console has
/// several Dart engines in one process (UI, foreground service, notification
/// drain), so the flight is process-wide: one engine owns it and the others ask
/// it through an [IsolateNameServer] port.
///
/// Every failure here is a [MobileOAuthException] subtype with a fixed,
/// body-free text; no token, code or server detail is ever put in one.
class NativeSessionExpired extends MobileOAuthException {
  const NativeSessionExpired();
  @override
  String toString() => 'Native session expired';
}

class NativeRefreshTransient extends MobileOAuthException {
  const NativeRefreshTransient();
  @override
  String toString() => 'Native session refresh unavailable';
}

class NativeAuthChanged extends MobileOAuthException {
  const NativeAuthChanged();
  @override
  String toString() => 'Authentication changed while the request was running';
}

class NativeSessionStorageUnavailable extends MobileOAuthException {
  const NativeSessionStorageUnavailable();
  @override
  String toString() => 'Native session storage unavailable';
}

/// What a request needs from a renewal; never the refresh token.
class NativeAccess {
  const NativeAccess(this.accessToken, this.expiresAt, this.rev);
  final String accessToken;
  final int expiresAt;
  final int rev;
}

/// The one secure-storage slot holding the envelope (`dash_token_<id>`).
abstract class NativeEnvelopeStore {
  Future<String?> read(String connectionId);

  /// Returns only when the value is on disk (DJ-1 = A).
  Future<void> writeDurable(String connectionId, String raw);
  Future<void> delete(String connectionId);
}

class SecureNativeEnvelopeStore implements NativeEnvelopeStore {
  SecureNativeEnvelopeStore([SecureStorage? secure])
    : _secure = secure ?? SecureStorage();
  final SecureStorage _secure;
  @override
  Future<String?> read(String id) => _secure.readDashboardSecret(id, 'token');
  @override
  Future<void> writeDurable(String id, String raw) =>
      _secure.writeDashboardSecretDurable(id, 'token', raw);
  @override
  Future<void> delete(String id) => _secure.deleteDashboardSecret(id, 'token');
}

abstract class NativeRefreshPortRegistry {
  /// Atomic: false when the name is already taken.
  bool register(String name, SendPort port);
  SendPort? lookup(String name);
  void unregister(String name);
}

class IsolateNameServerRegistry implements NativeRefreshPortRegistry {
  const IsolateNameServerRegistry();
  @override
  bool register(String name, SendPort port) =>
      IsolateNameServer.registerPortWithName(port, name);
  @override
  SendPort? lookup(String name) => IsolateNameServer.lookupPortByName(name);
  @override
  void unregister(String name) => IsolateNameServer.removePortNameMapping(name);
}

class NativeSessionCoordinator {
  NativeSessionCoordinator({
    NativeEnvelopeStore? store,
    http.Client Function()? httpClient,
    DateTime Function()? now,
    this.cooldown = const Duration(seconds: 60),
    this.requestTimeout = const Duration(seconds: 10),
    this.forwardTimeout = const Duration(seconds: 25),
    NativeRefreshPortRegistry? registry,
    this.portName = defaultPortName,
  }) : _store = store ?? SecureNativeEnvelopeStore(),
       _httpClient = httpClient ?? http.Client.new,
       _now = now ?? DateTime.now,
       _registry = registry ?? const IsolateNameServerRegistry();

  static const defaultPortName = 'hermes.native_refresh.v1';

  /// tokenNeedsRefresh skew of native-oauth.ts:242-253.
  static const skewSeconds = 60;

  static NativeSessionCoordinator? _instance;
  static NativeSessionCoordinator get instance =>
      _instance ??= NativeSessionCoordinator();

  @visibleForTesting
  static void replaceInstanceForTesting(NativeSessionCoordinator? next) {
    _instance?.dispose();
    _instance = next;
  }

  final NativeEnvelopeStore _store;
  final http.Client Function() _httpClient;
  final DateTime Function() _now;
  final Duration cooldown, requestTimeout, forwardTimeout;
  final NativeRefreshPortRegistry _registry;
  final String portName;

  final _flights = <String, Future<NativeAccess>>{};
  final _epochs = <String, int>{};
  final _cooldownUntil = <String, DateTime>{};
  // A rotation the server already made whose write did not land: retried from
  // memory instead of burning the (single-use) refresh token a second time.
  final _pending = <String, _Rotation>{};
  ReceivePort? _ownerPort;

  /// Test seam: the process "dies" between the server's answer and the write.
  @visibleForTesting
  Future<void> Function()? debugAfterServerAnswer;

  int _epoch(String id) => _epochs[id] ?? 0;

  /// Moves on every login/logout/delete of [connectionId] on this engine.
  int epochOf(String connectionId) => _epoch(connectionId);

  /// An explicit auth change (login, logout, delete): any refresh that began
  /// before it must not store or publish anything.
  void invalidate(String connectionId) {
    _epochs[connectionId] = _epoch(connectionId) + 1;
    _flights.remove(connectionId);
    _pending.remove(connectionId);
    _cooldownUntil.remove(connectionId);
  }

  /// Logout / connection removal: drops the envelope on this phone only (the
  /// server has no native revocation, H6).
  Future<void> clear(String connectionId) async {
    invalidate(connectionId);
    await _store.delete(connectionId);
  }

  /// A fresh login replaces whatever was stored, durably.
  Future<void> storeAfterLogin(String connectionId, String raw) async {
    invalidate(connectionId);
    await _store.writeDurable(connectionId, raw);
    if (await _store.read(connectionId) != raw) {
      throw const NativeSessionStorageUnavailable();
    }
  }

  /// The access token to send now, renewing it first when it is within 60 s of
  /// expiry or [forceRefresh] is set for a [rejectedAccess] that is still the
  /// stored one (a different one means somebody already renewed).
  Future<NativeAccess> ensureAccess(
    String connectionId,
    String baseUrl, {
    bool forceRefresh = false,
    String? rejectedAccess,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _ensureOnce(
          _Request(connectionId, baseUrl, forceRefresh, rejectedAccess),
        );
      } on NativeAuthChanged {
        if (attempt >= 1) rethrow; // one retry after a login/logout raced us
      }
    }
  }

  Future<NativeAccess> _ensureOnce(_Request req) async {
    final session = await _load(req);
    if (!_needsRefresh(session, req)) return _access(session);
    _requireRefreshable(session, req);
    if (!session.refreshable) return _access(session);
    return _processWide(req);
  }

  NativeAccess _access(MobileOAuthSession s) =>
      NativeAccess(s.accessToken, s.expiresAt, s.rev);

  int get _nowSeconds => _now().millisecondsSinceEpoch ~/ 1000;

  bool _rejected(MobileOAuthSession s, _Request req) =>
      req.forceRefresh &&
      (req.rejectedAccess == null || req.rejectedAccess == s.accessToken);

  bool _needsRefresh(MobileOAuthSession s, _Request req) =>
      _rejected(s, req) || _nowSeconds >= s.expiresAt - skewSeconds;

  /// A v1 envelope has no refresh token: past its expiry (or once the server
  /// rejected it) the session is over; inside the skew window it still works.
  void _requireRefreshable(MobileOAuthSession s, _Request req) {
    if (!s.refreshable && (_rejected(s, req) || _nowSeconds >= s.expiresAt)) {
      throw const NativeSessionExpired();
    }
  }

  Future<MobileOAuthSession> _load(_Request req) async {
    final String? raw;
    try {
      raw = await _store.read(req.connectionId);
    } catch (_) {
      throw const NativeSessionStorageUnavailable();
    }
    if (raw == null) throw const NativeSessionExpired();
    final MobileOAuthSession? session;
    try {
      session = MobileOAuthSession.decode(raw, req.connectionId, req.baseUrl);
    } on MobileOAuthException {
      // Unreadable or bound elsewhere: kept for a retry, never deleted here
      // (native-token-store.ts:140-152); signing in again overwrites it.
      throw const NativeSessionExpired();
    }
    if (session == null) throw const NativeSessionExpired();
    return session;
  }

  // ── process-wide single refresher (H2) ──────────────────────────────────

  Future<NativeAccess> _processWide(_Request req) async {
    if (_tryBecomeOwner()) return _ownerRefresh(req);
    final port = _registry.lookup(portName);
    if (port == null) {
      if (_tryBecomeOwner()) return _ownerRefresh(req);
      throw const NativeRefreshTransient();
    }
    final reply = ReceivePort();
    try {
      port.send({
        'conn': req.connectionId,
        'base': req.baseUrl,
        'force': req.forceRefresh,
        'rejected': req.rejectedAccess,
        'reply': reply.sendPort,
      });
      final answer = await reply.first.timeout(forwardTimeout);
      return _fromAnswer(answer);
    } on TimeoutException {
      // The owner engine may be gone: free a stale name so the next cycle
      // can claim it. This engine never refreshes on its own.
      if (_registry.lookup(portName) == port) _registry.unregister(portName);
      throw const NativeRefreshTransient();
    } finally {
      reply.close();
    }
  }

  bool _tryBecomeOwner() {
    if (_ownerPort != null) return true;
    final port = ReceivePort();
    if (!_registry.register(portName, port.sendPort)) {
      port.close();
      return false;
    }
    _ownerPort = port;
    port.listen(_onRequest);
    return true;
  }

  Future<void> _onRequest(dynamic message) async {
    if (message is! Map || message['reply'] is! SendPort) return;
    final reply = message['reply'] as SendPort;
    try {
      final access = await _ownerRefresh(
        _Request(
          message['conn'] as String,
          message['base'] as String,
          message['force'] == true,
          message['rejected'] as String?,
        ),
      );
      reply.send({
        'ok': [access.accessToken, access.expiresAt, access.rev],
      });
    } catch (e) {
      reply.send({'error': _codes[e.runtimeType] ?? 'transient'});
    }
  }

  static const _codes = <Type, String>{
    NativeSessionExpired: 'expired',
    NativeAuthChanged: 'changed',
    NativeSessionStorageUnavailable: 'storage',
  };

  NativeAccess _fromAnswer(dynamic answer) {
    if (answer is Map && answer['ok'] is List) {
      final ok = answer['ok'] as List;
      return NativeAccess(ok[0] as String, ok[1] as int, ok[2] as int);
    }
    throw switch (answer is Map ? answer['error'] : null) {
      'expired' => const NativeSessionExpired(),
      'changed' => const NativeAuthChanged(),
      'storage' => const NativeSessionStorageUnavailable(),
      _ => const NativeRefreshTransient(),
    };
  }

  /// Stops listening and frees the name. Tests, and an engine shutting down.
  void dispose() {
    final port = _ownerPort;
    if (port == null) return;
    _ownerPort = null;
    _registry.unregister(portName);
    port.close();
  }

  // ── the rotation ────────────────────────────────────────────────────────

  Future<NativeAccess> _ownerRefresh(_Request req) {
    final id = req.connectionId;
    final existing = _flights[id];
    if (existing != null) return existing;
    final until = _cooldownUntil[id];
    if (until != null && _now().isBefore(until)) {
      return Future<NativeAccess>.error(const NativeRefreshTransient());
    }
    final flight = _rotate(req);
    _flights[id] = flight;
    return flight.whenComplete(() {
      if (identical(_flights[id], flight)) _flights.remove(id);
    });
  }

  Future<NativeAccess> _rotate(_Request req) async {
    final id = req.connectionId;
    final epoch = _epoch(id);
    void assertCurrent() {
      if (_epoch(id) != epoch) throw const NativeAuthChanged();
    }

    // (1) reread: another engine may already have rotated.
    final session = await _load(req);
    if (!_needsRefresh(session, req)) return _access(session);
    _requireRefreshable(session, req);
    if (!session.refreshable) return _access(session);

    var rotation = _pending[id];
    if (rotation != null && rotation.from != session.refreshToken) {
      _pending.remove(id);
      rotation = null;
    }
    if (rotation == null) {
      // (2) + (3) ask the server and validate the answer.
      final next = await _askServer(session, assertCurrent);
      assertCurrent();
      rotation = _pending[id] = _Rotation(session.refreshToken!, next);
    }
    await debugAfterServerAnswer?.call();
    // (4) persist durably, (5) only then publish.
    await _persist(id, session, rotation.next, assertCurrent);
    _pending.remove(id);
    return _access(rotation.next);
  }

  Future<MobileOAuthSession> _askServer(
    MobileOAuthSession session,
    void Function() assertCurrent,
  ) async {
    final id = session.connectionId;
    final client = _httpClient();
    final http.Response response;
    try {
      final request = http.Request(
        'POST',
        Uri.parse('${session.baseUrl}/auth/native/refresh'),
      )..followRedirects = false;
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode({
        'refresh_token': session.refreshToken,
        'provider': session.provider,
      });
      response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(requestTimeout);
    } catch (_) {
      assertCurrent();
      _startCooldown(id);
      throw const NativeRefreshTransient();
    } finally {
      client.close();
    }
    assertCurrent();
    if (response.statusCode == 401 && _isSessionExpired(response.body)) {
      // Only a server verdict on the refresh itself ends the session
      // (main.ts:7930-7933: 503/transient keeps the tokens).
      await _dropIfUnchanged(session);
      throw const NativeSessionExpired();
    }
    final next = response.statusCode == 200
        ? _parse(response.body, session)
        : null;
    if (next == null) {
      _startCooldown(id);
      throw const NativeRefreshTransient();
    }
    return next;
  }

  bool _isSessionExpired(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['error'] == 'session_expired';
    } catch (_) {
      return false;
    }
  }

  /// Same rules as the code exchange (mobile_oauth.dart), plus: the answer is
  /// for the same provider and user, and it carries the next refresh token.
  MobileOAuthSession? _parse(String body, MobileOAuthSession from) {
    try {
      final t = jsonDecode(body);
      if (t is! Map ||
          t['token_type'] != 'Bearer' ||
          t['access_token'] is! String ||
          (t['access_token'] as String).isEmpty ||
          t['refresh_token'] is! String ||
          (t['refresh_token'] as String).isEmpty ||
          t['expires_at'] is! int ||
          (t['expires_at'] as int) <= _nowSeconds ||
          t['provider'] != from.provider ||
          t['user_id'] != from.userId) {
        return null;
      }
      return MobileOAuthSession(
        connectionId: from.connectionId,
        baseUrl: from.baseUrl,
        accessToken: t['access_token'] as String,
        expiresAt: t['expires_at'] as int,
        provider: from.provider,
        userId: from.userId,
        refreshToken: t['refresh_token'] as String,
        rev: from.rev + 1,
      );
    } catch (_) {
      return null;
    }
  }

  void _startCooldown(String id) => _cooldownUntil[id] = _now().add(cooldown);

  Future<void> _dropIfUnchanged(MobileOAuthSession used) async {
    final id = used.connectionId;
    _pending.remove(id);
    try {
      final raw = await _store.read(id);
      final now = MobileOAuthSession.decode(raw, id, used.baseUrl);
      if (now?.refreshToken == used.refreshToken) await _store.delete(id);
    } catch (_) {
      // Unreadable or locked: keep it; the login screen overwrites it.
    }
  }

  Future<void> _persist(
    String id,
    MobileOAuthSession from,
    MobileOAuthSession next,
    void Function() assertCurrent,
  ) async {
    final encoded = next.encode();
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        // Compare-and-swap against another engine's login.
        final MobileOAuthSession? current;
        try {
          current = MobileOAuthSession.decode(
            await _store.read(id),
            id,
            from.baseUrl,
          );
        } on MobileOAuthException {
          throw const NativeAuthChanged();
        }
        if (current == null ||
            current.refreshToken != from.refreshToken ||
            current.rev != from.rev) {
          throw const NativeAuthChanged();
        }
        assertCurrent();
        await _store.writeDurable(id, encoded);
        if (await _store.read(id) == encoded) return;
      } on NativeAuthChanged {
        _pending.remove(id);
        rethrow;
      } catch (_) {
        // fall through: one more try with the result held in memory
      }
    }
    throw const NativeSessionStorageUnavailable();
  }
}

class _Request {
  const _Request(
    this.connectionId,
    this.baseUrl,
    this.forceRefresh,
    this.rejectedAccess,
  );
  final String connectionId, baseUrl;
  final bool forceRefresh;
  final String? rejectedAccess;
}

class _Rotation {
  _Rotation(this.from, this.next);
  final String from;
  final MobileOAuthSession next;
}
