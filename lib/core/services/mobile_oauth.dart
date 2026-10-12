// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../utils/transport_privacy.dart';

/// Deliberately body-free: provider messages, codes and tokens are not diagnostics.
class MobileOAuthException implements Exception {
  const MobileOAuthException();
  @override
  String toString() => 'Native sign-in unavailable, expired or cancelled';
}

/// Stored ONLY through the existing per-connection Dashboard secure token slot.
/// A tagged envelope distinguishes broker bearer authority from legacy page tokens.
class MobileOAuthSession {
  const MobileOAuthSession({
    required this.connectionId,
    required this.baseUrl,
    required this.accessToken,
    required this.expiresAt,
    required this.provider,
    required this.userId,
  });
  static const prefix = 'hermes-native-pkce-v1:';
  final String connectionId, baseUrl, accessToken, provider, userId;
  final int expiresAt;
  String encode() =>
      '$prefix${jsonEncode({'connection_id': connectionId, 'base_url': baseUrl, 'access_token': accessToken, 'expires_at': expiresAt, 'provider': provider, 'user_id': userId})}';
  // Compare effective ports: an omitted HTTPS/HTTP port is 443/80, not a
  // different authority. Keep every other URL component bound to the session.
  static bool _sameTarget(String stored, String target) {
    final a = Uri.parse(stored), b = Uri.parse(target);
    return (a.scheme == 'https' || a.scheme == 'http') &&
        a.scheme == b.scheme &&
        a.host == b.host &&
        a.port == b.port &&
        a.userInfo == b.userInfo &&
        a.path == b.path &&
        a.query == b.query &&
        a.fragment == b.fragment;
  }

  static MobileOAuthSession? decode(String? raw, String owner, String target) {
    if (raw == null || !raw.startsWith(prefix)) return null;
    try {
      final body = jsonDecode(raw.substring(prefix.length));
      if (body is! Map ||
          body['connection_id'] != owner ||
          body['base_url'] is! String ||
          !_sameTarget(body['base_url'] as String, target) ||
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
    } catch (_) {
      throw const MobileOAuthException();
    }
  }
}

/// RFC 8252 app-owned ephemeral IPv4 callback. The official broker accepts this
/// exact redirect contract; no provider registration, custom scheme or App Link.
/// Verifier/state live only in this attempt. Losing the process requires retry.
class MobileOAuthLogin {
  MobileOAuthLogin({
    Future<bool> Function(Uri)? openBrowser,
    DateTime Function()? now,
    this.timeout = const Duration(minutes: 5),
  }) : _openBrowser =
           openBrowser ??
           ((url) => launchUrl(url, mode: LaunchMode.externalApplication)),
       _now = now ?? DateTime.now;
  final Future<bool> Function(Uri) _openBrowser;
  final DateTime Function() _now;
  final Duration timeout;
  void Function()? _abort;
  bool _disposed = false;
  void cancel() {
    _disposed = true;
    _abort?.call();
  }

  String _random() {
    final rng = Random.secure();
    return base64UrlEncode(
      List<int>.generate(32, (_) => rng.nextInt(256)),
    ).replaceAll('=', '');
  }

  Future<MobileOAuthSession> run({
    required String connectionId,
    required String baseUrl,
    required bool Function() authorityCurrent,
    bool allowPrivateHttp = false,
  }) async {
    if (_disposed || _abort != null || !authorityCurrent()) {
      throw const MobileOAuthException();
    }
    final base = Uri.parse(TransportPrivacy.requireAllowed(baseUrl));
    if (!['https', 'http'].contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        base.path.isNotEmpty && base.path != '/') {
      // SavedConnection currently models origin-only Dashboard endpoints.
      throw const MobileOAuthException();
    }
    final loopback =
        base.host == 'localhost' ||
        (InternetAddress.tryParse(base.host)?.isLoopback ?? false);
    if (base.scheme == 'http' && !loopback && !allowPrivateHttp) {
      throw const MobileOAuthException();
    }
    final target = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final verifier = _random();
    final state = _random();
    final challenge = base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final deadline = _now().add(timeout);
    final result = Completer<MobileOAuthSession>();
    unawaited(result.future.then<void>((_) {}, onError: (_) {}));
    var consumed = false;
    HttpServer? listener;
    final client = http.Client();
    bool current() =>
        !_disposed &&
        authorityCurrent() &&
        _now().isBefore(deadline) &&
        !result.isCompleted;
    void fail() {
      if (!result.isCompleted) {
        result.completeError(const MobileOAuthException());
      }
      client.close();
      unawaited(listener?.close(force: true));
    }

    _abort = fail;
    final guard = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!current()) fail();
    });
    Future<Map<String, dynamic>> request(
      String path, {
      Map<String, dynamic>? body,
      String? bearer,
    }) async {
      if (!current()) throw const MobileOAuthException();
      final req = http.Request(
        body == null ? 'GET' : 'POST',
        Uri.parse('$target$path'),
      )..followRedirects = false;
      req.headers['Content-Type'] = 'application/json';
      if (bearer != null) req.headers['Authorization'] = 'Bearer $bearer';
      if (body != null) req.body = jsonEncode(body);
      final response = await client
          .send(req)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 15));
      if (!current() || response.statusCode != 200) {
        throw const MobileOAuthException();
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) throw const MobileOAuthException();
      return decoded;
    }

    try {
      listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      if (!current()) throw const MobileOAuthException();
      final callback = Uri.parse('http://127.0.0.1:${listener.port}/callback');
      listener.listen((req) async {
        req.response.headers.set('Cache-Control', 'no-store');
        req.response.headers.set('Referrer-Policy', 'no-referrer');
        final query = req.uri.queryParametersAll;
        final valid =
            current() &&
            !consumed &&
            req.method == 'GET' &&
            req.headers.value(HttpHeaders.hostHeader) == callback.authority &&
            !req.uri.hasScheme &&
            !req.uri.hasAuthority &&
            req.uri.path == callback.path &&
            query['state']?.length == 1 &&
            query['state']!.single == state &&
            query['code']?.length == 1 &&
            query['code']!.single.isNotEmpty &&
            !query.containsKey('error');
        req.response.statusCode = valid ? 200 : 400;
        req.response.write('Return to Console to check sign-in.');
        if (valid) consumed = true; // consume before ANY await/exchange
        await req.response.close();
        if (!valid) return;
        try {
          final tokens = await request(
            '/auth/native/token',
            body: {'code': query['code']!.single, 'code_verifier': verifier},
          );
          final access = tokens['access_token'];
          final expiry = tokens['expires_at'];
          final provider = tokens['provider'];
          final user = tokens['user_id'];
          if (tokens['token_type'] != 'Bearer' ||
              access is! String ||
              access.isEmpty ||
              expiry is! int ||
              expiry <= _now().millisecondsSinceEpoch ~/ 1000 ||
              provider is! String ||
              provider.isEmpty ||
              user is! String ||
              user.isEmpty) {
            throw const MobileOAuthException();
          }
          final me = await request('/api/auth/me', bearer: access);
          if (me['provider'] != provider ||
              me['user_id'] != user ||
              !current()) {
            throw const MobileOAuthException();
          }
          // Refresh tokens are intentionally not retained: expiry requires a new
          // browser attempt, not an unowned background refresh/persistence write.
          result.complete(
            MobileOAuthSession(
              connectionId: connectionId,
              baseUrl: target,
              accessToken: access,
              expiresAt: expiry,
              provider: provider,
              userId: user,
            ),
          );
        } catch (_) {
          fail();
        }
      }, onError: (_) => fail());
      final url = Uri.parse('$target/auth/native/authorize').replace(
        queryParameters: {
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'redirect_uri': callback.toString(),
          'state': state,
        },
      );
      if (!current()) throw const MobileOAuthException();
      // A platform launch that never returns cannot hold cancellation hostage.
      final opened = await Future.any<bool>([
        _openBrowser(url),
        result.future.then((_) => true),
      ]);
      if (!opened) throw const MobileOAuthException();
      return await result.future;
    } catch (_) {
      // Attach a handler before aborting so early launch/bind failure never
      // leaves a completer's error unobserved.
      unawaited(result.future.then<void>((_) {}, onError: (_) {}));
      fail();
      throw const MobileOAuthException();
    } finally {
      guard.cancel();
      _abort = null;
      client.close();
      await listener?.close(force: true);
    }
  }
}
