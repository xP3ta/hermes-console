// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
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
    this.refreshToken,
    this.rev = 0,
  });

  /// The prefix stays `-v1:` for the v2 envelope on purpose: an older Console
  /// reads the extra keys as nothing and still uses the access token until it
  /// expires, instead of sending the whole envelope as a page token.
  static const prefix = 'hermes-native-pkce-v1:';
  final String connectionId, baseUrl, accessToken, provider, userId;
  final int expiresAt;

  /// Envelope v2: the broker refresh token and a counter that rises on every
  /// rotation. Null = v1 envelope (access only), which cannot refresh.
  final String? refreshToken;
  final int rev;
  bool get refreshable => refreshToken != null;
  String encode() =>
      '$prefix${jsonEncode({
        'connection_id': connectionId,
        'base_url': baseUrl,
        'access_token': accessToken,
        'expires_at': expiresAt,
        'provider': provider,
        'user_id': userId,
        if (refreshToken != null) ...{'v': 2, 'refresh_token': refreshToken, 'rev': rev},
      })}';

  /// True when [raw] is a v2 envelope that carries a refresh token.
  static bool carriesRefresh(String? raw) {
    if (raw == null || !raw.startsWith(prefix)) return false;
    try {
      final body = jsonDecode(raw.substring(prefix.length));
      return body is Map &&
          body['v'] == 2 &&
          body['refresh_token'] is String &&
          (body['refresh_token'] as String).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

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
      final v2 = body is Map && body['v'] == 2;
      if (body is! Map ||
          (body.containsKey('v') && !v2) ||
          (v2 &&
              (body['refresh_token'] is! String ||
                  (body['refresh_token'] as String).isEmpty ||
                  body['rev'] is! int)) ||
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
        refreshToken: v2 ? body['refresh_token'] as String : null,
        rev: v2 ? body['rev'] as int : 0,
      );
    } catch (_) {
      throw const MobileOAuthException();
    }
  }
}

/// PKCE material (RFC 7636, S256) of ONE login attempt. Shared by the browser
/// login and the password login so both mint it the same way.
class PkceAttempt {
  PkceAttempt._(this.verifier, this.state, this.challenge);
  factory PkceAttempt.generate() {
    String random() {
      final rng = Random.secure();
      return base64UrlEncode(
        List<int>.generate(32, (_) => rng.nextInt(256)),
      ).replaceAll('=', '');
    }

    final verifier = random();
    return PkceAttempt._(
      verifier,
      random(),
      base64UrlEncode(
        sha256.convert(ascii.encode(verifier)).bytes,
      ).replaceAll('=', ''),
    );
  }
  final String verifier, state, challenge;
}

/// Validates the body of `POST /auth/native/token` and builds the session it
/// grants. [retainRefresh] keeps the broker refresh token (simple connect);
/// `basic` without one stays a v1 session. Body-free failure on any mismatch.
MobileOAuthSession sessionFromNativeTokens(
  Map<String, dynamic> tokens, {
  required String connectionId,
  required String baseUrl,
  required DateTime now,
  required bool retainRefresh,
}) {
  final access = tokens['access_token'];
  final expiry = tokens['expires_at'];
  final provider = tokens['provider'];
  final user = tokens['user_id'];
  final refresh = tokens['refresh_token'];
  final keepRefresh = retainRefresh && refresh is String && refresh.isNotEmpty;
  if (retainRefresh &&
      !keepRefresh &&
      (refresh != null || provider != 'basic')) {
    throw const MobileOAuthException();
  }
  if (tokens['token_type'] != 'Bearer' ||
      access is! String ||
      access.isEmpty ||
      expiry is! int ||
      expiry <= now.millisecondsSinceEpoch ~/ 1000 ||
      provider is! String ||
      provider.isEmpty ||
      user is! String ||
      user.isEmpty) {
    throw const MobileOAuthException();
  }
  return MobileOAuthSession(
    connectionId: connectionId,
    baseUrl: baseUrl,
    accessToken: access,
    expiresAt: expiry,
    provider: provider,
    userId: user,
    refreshToken: keepRefresh ? refresh : null,
  );
}

/// RFC 8252 app-owned ephemeral IPv4 callback. The official broker accepts this
/// exact redirect contract; no provider registration, custom scheme or App Link.
/// Verifier/state live only in this attempt. Losing the process requires retry.
class MobileOAuthLogin {
  MobileOAuthLogin({
    Future<bool> Function(Uri)? openBrowser,
    DateTime Function()? now,
    this.timeout = const Duration(minutes: 5),
    this.retainRefresh = false,
    this.foreground,
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _openBrowser =
           openBrowser ??
           ((url) => launchUrl(url, mode: LaunchMode.externalApplication)),
       _now = now ?? DateTime.now;
  final Future<bool> Function(Uri) _openBrowser;
  final DateTime Function() _now;
  final Duration timeout;
  final Future<void> Function()? foreground;
  final http.Client Function() _clientFactory;

  /// Simple connect: keep the broker refresh token in a v2 envelope. Required
  /// for every provider but `basic`; `basic` without one stays a v1 session.
  final bool retainRefresh;
  void Function()? _abort;
  bool _disposed = false;
  void cancel() {
    _disposed = true;
    _abort?.call();
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
    final pkce = PkceAttempt.generate();
    final verifier = pkce.verifier, state = pkce.state;
    final deadline = _now().add(timeout);
    final result = Completer<MobileOAuthSession>();
    unawaited(result.future.then<void>((_) {}, onError: (_) {}));
    var consumed = false;
    HttpServer? listener;
    final client = _clientFactory();
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
    // Android freezes or firewalls a backgrounded app while the browser is
    // still open: hold every request until Console is in front again.
    Future<void> inForeground() => Future.any<void>([
      (foreground ?? _lifecycleResumed)(),
      result.future.then<void>((_) {}),
    ]);
    Future<Map<String, dynamic>> request(
      String path, {
      Map<String, dynamic>? body,
      String? bearer,
    }) async {
      await inForeground();
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
        final headers = req.response.headers;
        headers.set('Cache-Control', 'no-store');
        headers.set('Referrer-Policy', 'no-referrer');
        headers.set('X-Content-Type-Options', 'nosniff');
        headers.set(
          'Content-Security-Policy',
          "default-src 'none'; style-src 'unsafe-inline'",
        );
        headers.contentType = ContentType('text', 'html', charset: 'utf-8');
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
        req.response.write(
          _callbackPage(
            ok: valid,
            spanish: _prefersSpanish(req.headers.value('accept-language')),
          ),
        );
        if (valid) consumed = true; // consume before ANY await/exchange
        await req.response.close();
        if (!valid) return;
        try {
          Future<Map<String, dynamic>> exchange() => request(
            '/auth/native/token',
            body: {'code': query['code']!.single, 'code_verifier': verifier},
          );
          Map<String, dynamic> tokens;
          try {
            tokens = await exchange();
          } on SocketException {
            tokens = await exchange(); // one retry, network errors only
          } on http.ClientException {
            tokens = await exchange();
          }
          final issued = sessionFromNativeTokens(
            tokens,
            connectionId: connectionId,
            baseUrl: target,
            now: _now(),
            retainRefresh: retainRefresh,
          );
          final me = await request('/api/auth/me', bearer: issued.accessToken);
          if (me['provider'] != issued.provider ||
              me['user_id'] != issued.userId ||
              !current()) {
            throw const MobileOAuthException();
          }
          // The refresh token is kept only for simple connect (v2 envelope);
          // rotating it is the single coordinator's job (S1), never this login's.
          result.complete(issued);
        } catch (_) {
          fail();
        }
      }, onError: (_) => fail());
      final url = Uri.parse('$target/auth/native/authorize').replace(
        queryParameters: {
          'code_challenge': pkce.challenge,
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

/// Completes when the app is resumed (at once if it already is, or if no
/// binding exists, e.g. a plain Dart isolate).
Future<void> _lifecycleResumed() {
  final WidgetsBinding binding;
  try {
    binding = WidgetsBinding.instance;
  } catch (_) {
    return Future.value();
  }
  final state = binding.lifecycleState;
  if (state == null || state == AppLifecycleState.resumed) {
    return Future.value();
  }
  final done = Completer<void>();
  late final WidgetsBindingObserver observer;
  observer = _ResumeObserver(() {
    binding.removeObserver(observer);
    if (!done.isCompleted) done.complete();
  });
  binding.addObserver(observer);
  return done.future;
}

class _ResumeObserver with WidgetsBindingObserver {
  _ResumeObserver(this.onResumed);
  final void Function() onResumed;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResumed();
  }
}

// Static page for the loopback callback. The listener has no BuildContext, so
// the texts live here. Nothing from the request is echoed into the page.
bool _prefersSpanish(String? acceptLanguage) {
  final first = (acceptLanguage ?? '').split(',').first.trim().toLowerCase();
  return first.startsWith('es');
}

String _callbackPage({required bool ok, required bool spanish}) {
  final (title, body) = switch ((ok, spanish)) {
    (true, true) => (
      'Sesión iniciada',
      'Puedes cerrar esta pestaña y volver a Console.',
    ),
    (true, false) => (
      'Signed in',
      'You can close this tab and go back to Console.',
    ),
    (false, true) => (
      'No se pudo completar el acceso',
      'Vuelve a Console e inténtalo de nuevo.',
    ),
    (false, false) => (
      "Sign-in didn't finish",
      'Go back to Console and try again.',
    ),
  };
  return '<!doctype html><html lang="${spanish ? 'es' : 'en'}"><head>'
      '<meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<meta name="color-scheme" content="light dark">'
      '<title>$title</title><style>'
      ':root{color-scheme:light dark}'
      'body{margin:0;min-height:100vh;display:grid;place-items:center;'
      'font:18px/1.5 system-ui,sans-serif;background:#faf7f2;color:#2b2b2b}'
      'main{padding:24px;max-width:28em;text-align:center}'
      'h1{font-size:1.5em;margin:0 0 .5em}p{margin:0;font-size:1em}'
      '@media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#eeeae4}}'
      '</style></head><body><main><h1>$title</h1><p>$body</p></main></body></html>';
}
