// Authenticated, isolated SSH loopback forwarding for the in-app browser.
// Uses real private loopback HTTP/1.1 & WebSocket servers and transport doubles
// to verify access control, cookie/origin isolation, lifecycle teardown,
// single-flight SSH setup with deadlines, protocol/IPv6 fidelity, and WebView
// navigation/redirect handling.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/browser_loopback_reach.dart';
import 'package:hermes_android/core/browser/browser_tabs.dart';
import 'package:hermes_android/core/browser/in_app_browser_screen.dart';
import 'package:hermes_android/core/browser/in_app_tabbed_browser.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_webview_platform.dart';

/// Private local HTTP/1.1 + WebSocket test server representing a remote dev
/// server reached over SSH.
class _TestDevServer {
  _TestDevServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<_TestDevServer> start({InternetAddress? address}) async {
    final server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      0,
    );
    return _TestDevServer._(server);
  }

  final HttpServer _server;
  final List<Map<String, String>> seenHeaders = [];
  final List<String> seenBodies = [];
  final List<String> seenPaths = [];
  String? setCookieHeader;
  String? redirectLocation;

  int get port => _server.port;

  Future<void> _handle(HttpRequest req) async {
    if (WebSocketTransformer.isUpgradeRequest(req)) {
      final map = <String, String>{};
      req.headers.forEach((k, v) => map[k.toLowerCase()] = v.join(', '));
      seenHeaders.add(map);
      seenPaths.add(req.uri.toString());
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((msg) => ws.add('ws-echo:$msg'));
      return;
    }

    final map = <String, String>{};
    req.headers.forEach((k, v) => map[k.toLowerCase()] = v.join(', '));
    seenHeaders.add(map);
    seenPaths.add(req.uri.toString());
    final body = await utf8.decoder.bind(req).join();
    seenBodies.add(body);

    if (redirectLocation != null) {
      req.response.statusCode = HttpStatus.found;
      req.response.headers.set('location', redirectLocation!);
      if (setCookieHeader != null) {
        req.response.headers.add('set-cookie', setCookieHeader!);
      }
      await req.response.close();
      return;
    }
    if (setCookieHeader != null) {
      req.response.headers.add('set-cookie', setCookieHeader!);
    }
    req.response.statusCode = HttpStatus.ok;
    req.response.write(
      body.isEmpty ? 'ok:${req.method}:${req.uri}' : 'ok:$body',
    );
    await req.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

/// Stands for `SSHClient.forwardLocal`: records `(host, port)` dials and opens
/// a real loopback socket to the mapped test server.
class _Dialer {
  _Dialer(this.routes);

  /// `(remoteHost, remotePort)` -> `(localAddress, localPort)`.
  final Map<(String, int), (String, int)> routes;
  final List<(String, int)> dialed = [];

  Future<SSHSocket> call(String host, int port) {
    dialed.add((host, port));
    final target = routes[(host, port)];
    if (target == null) {
      throw const SocketException('nothing listens there');
    }
    return SSHSocket.connect(target.$1, target.$2);
  }
}

/// Lightweight SSH transport double for single-flight / deadline / close tests.
class _FakeSshTransport implements BrowserSshTransport {
  _FakeSshTransport(this._dial);

  final BrowserLoopbackDial _dial;
  bool _closed = false;
  int closeCount = 0;

  @override
  bool get isClosed => _closed;

  @override
  Future<SSHSocket> forwardLocal(String remoteHost, int remotePort) {
    if (_closed) throw StateError('transport closed');
    return _dial(remoteHost, remotePort);
  }

  @override
  void close() {
    _closed = true;
    closeCount++;
  }
}

/// Raw HTTP/1.1 request helper over a loopback TCP socket, returning the raw
/// HTTP response string.
Future<String> _rawHttp(
  int port,
  String request, {
  InternetAddress? address,
}) async {
  final socket = await Socket.connect(
    address ?? InternetAddress.loopbackIPv4,
    port,
  );
  socket.add(latin1.encode(request));
  await socket.flush();
  final answer = await latin1.decoder.bind(socket).join();
  socket.destroy();
  return answer;
}

String? _extractCookieValue(String rawResponse, String name) {
  for (final line in rawResponse.split('\r\n')) {
    if (!line.toLowerCase().startsWith('set-cookie:')) continue;
    final body = line.substring('set-cookie:'.length).trim();
    final firstPair = body.split(';').first.trim();
    final eq = firstPair.indexOf('=');
    if (eq > 0 && firstPair.substring(0, eq).trim() == name) {
      return firstPair.substring(eq + 1).trim();
    }
  }
  return null;
}

Future<void> _expectPortRefuses(int port) async {
  for (var i = 0; i < 20; i++) {
    try {
      final probe = await Socket.connect(InternetAddress.loopbackIPv4, port);
      probe.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } on SocketException {
      return;
    }
  }
  fail('expected port $port to stop listening');
}

Widget _browserApp(Widget child) => MaterialApp(
  theme: AppTheme.hermesRedDark,
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: child,
);

void main() {
  group('target parsing, protocol, and address family', () {
    test('parses loopback http/https and preserves dial family', () {
      final local = browserLoopbackTarget(Uri.parse('http://localhost:5173/'));
      expect(local, isNotNull);
      expect(local!.port, 5173);
      expect(local.dialHosts, ['127.0.0.1', '::1']);
      expect(local.authority, 'localhost:5173');

      final v4 = browserLoopbackTarget(Uri.parse('http://127.0.0.1:3000'));
      expect(v4!.dialHosts, ['127.0.0.1']);
      expect(v4.authority, '127.0.0.1:3000');

      final any = browserLoopbackTarget(Uri.parse('http://0.0.0.0:4321'));
      expect(any!.dialHosts, ['127.0.0.1']);

      final v6 = browserLoopbackTarget(Uri.parse('http://[::1]:8080/x'));
      expect(v6!.port, 8080);
      expect(v6.dialHosts, ['::1']);
      expect(v6.authority, '[::1]:8080');

      final https = browserLoopbackTarget(Uri.parse('https://localhost/'));
      expect(https!.isHttps, isTrue);
      expect(https.port, 443);
      expect(browserLoopbackPort(Uri.parse('http://LOCALHOST/')), 80);
    });

    test('never matches non-loopback hosts or other schemes', () {
      for (final url in [
        'https://example.com/',
        'http://192.168.1.10:5173/',
        'http://10.0.0.5:3000/',
        'http://localhost.example.com:5173/',
        'ftp://localhost:21/',
      ]) {
        expect(browserLoopbackTarget(Uri.parse(url)), isNull, reason: url);
      }
    });

    test('rewrite keeps path/query/fragment for http and refuses https', () {
      expect(
        browserLoopbackRewrite(
          Uri.parse('http://localhost:5173/app/page?q=1#top'),
          40123,
          localHost: 'habcdef0123456789abcdef01.localhost',
        ).toString(),
        'http://habcdef0123456789abcdef01.localhost:40123/app/page?q=1#top',
      );
      expect(
        () => browserLoopbackRewrite(
          Uri.parse('https://localhost:5173/'),
          40123,
          localHost: 'habcdef0123456789abcdef01.localhost',
        ),
        throwsArgumentError,
      );
    });
  });

  group('access control, HTTP/WebSocket proxy, and cookie isolation', () {
    late _TestDevServer server;
    late _Dialer dialer;
    late BrowserLoopbackReach reach;

    setUp(() async {
      server = await _TestDevServer.start();
      dialer = _Dialer({('127.0.0.1', 5173): ('127.0.0.1', server.port)});
      reach = BrowserLoopbackReach(dial: dialer.call);
    });

    tearDown(() async {
      await reach.close();
      await server.stop();
    });

    test('unauthenticated local connections get 403 and never dial SSH', () async {
      final res = await reach.resolve(Uri.parse('http://localhost:5173/app'));
      expect(res.status, BrowserLoopbackStatus.forwarded);
      final hostHeader = '${res.localHost}:${res.localPort}';

      // Missing auth header & cookie (e.g. another app on the phone).
      final unauth = await _rawHttp(
        res.localPort!,
        'GET /app HTTP/1.1\r\nHost: $hostHeader\r\n\r\n',
      );
      expect(unauth, startsWith('HTTP/1.1 403 Forbidden'));

      // Wrong Host header.
      final wrongHost = await _rawHttp(
        res.localPort!,
        'GET /app HTTP/1.1\r\n'
        'Host: 127.0.0.1:${res.localPort}\r\n'
        '$kBrowserForwardAuthHeader: ${res.headers[kBrowserForwardAuthHeader]}\r\n'
        '\r\n',
      );
      expect(wrongHost, startsWith('HTTP/1.1 403 Forbidden'));

      // Cross-site request.
      final crossSite = await _rawHttp(
        res.localPort!,
        'GET /app HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        'Sec-Fetch-Site: cross-site\r\n'
        '$kBrowserForwardAuthHeader: ${res.headers[kBrowserForwardAuthHeader]}\r\n'
        '\r\n',
      );
      expect(crossSite, startsWith('HTTP/1.1 403 Forbidden'));

      // Foreign Origin header.
      final badOrigin = await _rawHttp(
        res.localPort!,
        'GET /app HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        'Origin: https://untrusted.example\r\n'
        '$kBrowserForwardAuthHeader: ${res.headers[kBrowserForwardAuthHeader]}\r\n'
        '\r\n',
      );
      expect(badOrigin, startsWith('HTTP/1.1 403 Forbidden'));

      expect(dialer.dialed, isEmpty);
      expect(server.seenPaths, isEmpty);
    });

    test('bootstrap authenticates once, sets HttpOnly SameSite=Strict cookie, '
        'rewrites Host/Origin/Referer, strips internal auth, and strips '
        'loopback Domain on Set-Cookie', () async {
      server.setCookieHeader = 'dev_sid=xyz; Domain=localhost; Path=/; HttpOnly';
      final res = await reach.resolve(
        Uri.parse('http://localhost:5173/app?x=1'),
      );
      expect(res.status, BrowserLoopbackStatus.forwarded);
      expect(isInternalBrowserForwardHost(res.localHost!), isTrue);
      final hostHeader = '${res.localHost}:${res.localPort}';
      final bootstrap = res.headers[kBrowserForwardAuthHeader]!;

      final first = await _rawHttp(
        res.localPort!,
        'GET /app?x=1 HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        'Origin: http://$hostHeader\r\n'
        'Referer: http://$hostHeader/start\r\n'
        '$kBrowserForwardAuthHeader: $bootstrap\r\n'
        '\r\n',
      );
      expect(first, startsWith('HTTP/1.1 200 OK'));
      expect(first, contains('ok:GET:/app?x=1'));
      // Upstream saw requested localhost authority and never saw internal auth.
      expect(server.seenHeaders.last['host'], 'localhost:5173');
      expect(server.seenHeaders.last['origin'], 'http://localhost:5173');
      expect(
        server.seenHeaders.last['referer'],
        'http://localhost:5173/start',
      );
      expect(
        server.seenHeaders.last.containsKey(kBrowserForwardAuthHeader),
        isFalse,
      );
      // Upstream Set-Cookie had Domain=localhost stripped.
      expect(first, contains('Set-Cookie: dev_sid=xyz; Path=/; HttpOnly'));
      expect(first.toLowerCase(), isNot(contains('domain=localhost')));

      // Proxy set its own HttpOnly SameSite=Strict session cookie.
      final sessionCookie = _extractCookieValue(first, kBrowserForwardCookieName);
      expect(sessionCookie, isNotNull);
      expect(
        first,
        contains(
          'Set-Cookie: $kBrowserForwardCookieName=$sessionCookie; '
          'Path=/; HttpOnly; SameSite=Strict',
        ),
      );

      // Replaying the single-use bootstrap token is rejected.
      final replay = await _rawHttp(
        res.localPort!,
        'GET /app HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        '$kBrowserForwardAuthHeader: $bootstrap\r\n'
        '\r\n',
      );
      expect(replay, startsWith('HTTP/1.1 403 Forbidden'));

      // Subsequent POST with session cookie + app cookie succeeds and strips
      // only the internal forward cookie.
      final post = await _rawHttp(
        res.localPort!,
        'POST /api HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        'Cookie: dev_sid=xyz; $kBrowserForwardCookieName=$sessionCookie\r\n'
        'Content-Length: 11\r\n'
        '\r\n'
        'hello=world',
      );
      expect(post, startsWith('HTTP/1.1 200 OK'));
      expect(post, contains('ok:hello=world'));
      expect(server.seenBodies.last, 'hello=world');
      expect(server.seenHeaders.last['cookie'], 'dev_sid=xyz');
    });

    test('a multipart upload sent while the SSH channel is still opening '
        'reaches the server byte for byte', () async {
      // The channel takes a while: the whole body arrives before it opens.
      final slow = BrowserLoopbackReach(
        dial: (host, port) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return dialer.call(host, port);
        },
      );
      addTearDown(slow.close);
      final res = await slow.resolve(Uri.parse('http://localhost:5173/upload'));
      final hostHeader = '${res.localHost}:${res.localPort}';
      final bootstrap = res.headers[kBrowserForwardAuthHeader]!;
      // Parts are separated by blank lines, the very thing a head ends with,
      // and the file is larger than any head may be.
      final filler = List.filled(96 * 1024, 'x').join();
      final body =
          '--edge\r\n'
          'Content-Disposition: form-data; name="title"\r\n'
          '\r\n'
          'first part\r\n'
          '--edge\r\n'
          'Content-Disposition: form-data; name="file"; filename="a.txt"\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          '$filler\r\n'
          '--edge--\r\n';
      final response = await _rawHttp(
        res.localPort!,
        'POST /upload HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        'Origin: http://$hostHeader\r\n'
        '$kBrowserForwardAuthHeader: $bootstrap\r\n'
        'Content-Type: multipart/form-data; boundary=edge\r\n'
        'Content-Length: ${body.length}\r\n'
        '\r\n'
        '$body',
      );
      expect(response, startsWith('HTTP/1.1 200 OK'));
      expect(server.seenBodies.last.length, body.length);
      expect(server.seenBodies.last, body);
    });

    test('WebSocket upgrade requires session cookie and relays frames', () async {
      final wsNonce = base64Encode(List<int>.filled(16, 42));
      final res = await reach.resolve(Uri.parse('http://localhost:5173/'));
      final hostHeader = '${res.localHost}:${res.localPort}';
      final bootstrap = res.headers[kBrowserForwardAuthHeader]!;

      // Unauthenticated WS upgrade is refused before dialing SSH.
      final refusedWs = await _rawHttp(
        res.localPort!,
        'GET /hmr HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Key: $wsNonce\r\n'
        'Sec-WebSocket-Version: 13\r\n'
        '\r\n',
      );
      expect(refusedWs, startsWith('HTTP/1.1 403 Forbidden'));
      expect(dialer.dialed, isEmpty);

      // Bootstrap to obtain session cookie.
      final init = await _rawHttp(
        res.localPort!,
        'GET / HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        '$kBrowserForwardAuthHeader: $bootstrap\r\n'
        '\r\n',
      );
      final cookie = _extractCookieValue(init, kBrowserForwardCookieName)!;

      // Connect real WebSocket over loopback using the session cookie and
      // matching Host/Origin.
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        res.localPort!,
      );
      socket.add(
        latin1.encode(
          'GET /hmr HTTP/1.1\r\n'
          'Host: $hostHeader\r\n'
          'Origin: http://$hostHeader\r\n'
          'Cookie: $kBrowserForwardCookieName=$cookie\r\n'
          'Upgrade: websocket\r\n'
          'Connection: Upgrade\r\n'
          'Sec-WebSocket-Key: $wsNonce\r\n'
          'Sec-WebSocket-Version: 13\r\n'
          '\r\n',
        ),
      );
      await socket.flush();
      final completer = Completer<String>();
      final buf = <int>[];
      late StreamSubscription<List<int>> sub;
      sub = socket.listen((chunk) {
        buf.addAll(chunk);
        final text = latin1.decode(buf);
        if (text.contains('\r\n\r\n') && !completer.isCompleted) {
          completer.complete(text);
        }
      });
      final handshake = await completer.future.timeout(
        const Duration(seconds: 5),
      );
      expect(handshake, startsWith('HTTP/1.1 101'));
      expect(server.seenHeaders.last['origin'], 'http://localhost:5173');
      await sub.cancel();
      socket.destroy();
    });

    test('same-origin redirect Location rewrites to local host while '
        'cross-port Location stays remote for WebView interception', () async {
      final res = await reach.resolve(Uri.parse('http://localhost:5173/'));
      final hostHeader = '${res.localHost}:${res.localPort}';
      final bootstrap = res.headers[kBrowserForwardAuthHeader]!;

      server.redirectLocation = 'http://localhost:5173/dashboard?a=1';
      final sameOrigin = await _rawHttp(
        res.localPort!,
        'GET / HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        '$kBrowserForwardAuthHeader: $bootstrap\r\n'
        '\r\n',
      );
      expect(sameOrigin, startsWith('HTTP/1.1 302'));
      expect(
        sameOrigin,
        contains('Location: http://$hostHeader/dashboard?a=1'),
      );
      final cookie = _extractCookieValue(sameOrigin, kBrowserForwardCookieName)!;

      server.redirectLocation = 'http://localhost:8080/other';
      final crossPort = await _rawHttp(
        res.localPort!,
        'GET /go HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        'Cookie: $kBrowserForwardCookieName=$cookie\r\n'
        '\r\n',
      );
      expect(crossPort, startsWith('HTTP/1.1 302'));
      expect(crossPort, contains('Location: http://localhost:8080/other'));
    });

    test('distinct isolated *.localhost host per port, loopback host, '
        'SSH profile, and after teardown', () async {
      final r1 = await reach.resolve(
        Uri.parse('http://localhost:5173/'),
        ownerId: 'tab-1',
      );
      final r2 = await reach.resolve(
        Uri.parse('http://localhost:8080/'),
        ownerId: 'tab-2',
      );
      final r3 = await reach.resolve(
        Uri.parse('http://127.0.0.1:5173/'),
        ownerId: 'tab-3',
      );

      final otherProfile = BrowserLoopbackReach(dial: dialer.call);
      addTearDown(otherProfile.close);
      final r4 = await otherProfile.resolve(
        Uri.parse('http://localhost:5173/'),
        ownerId: 'tab-1',
      );

      final hosts = {r1.localHost, r2.localHost, r3.localHost, r4.localHost};
      expect(hosts, hasLength(4));
      for (final h in hosts) {
        expect(isInternalBrowserForwardHost(h!), isTrue);
      }

      // Listening addresses are strictly loopback only.
      expect(reach.listeningAddresses, isNotEmpty);
      for (final address in reach.listeningAddresses) {
        expect(address.isLoopback, isTrue);
      }

      // Reopening after teardown mints a brand-new host label.
      await reach.releaseOwner('tab-1');
      final r1Reopened = await reach.resolve(
        Uri.parse('http://localhost:5173/'),
        ownerId: 'tab-1',
      );
      expect(r1Reopened.localHost, isNot(r1.localHost));

      // reveal maps back to the asked host and ignores unrelated URLs.
      expect(
        reach.reveal('http://${r2.localHost}:${r2.localPort}/docs?a=b'),
        'http://localhost:8080/docs?a=b',
      );
      expect(reach.reveal('https://example.com/'), 'https://example.com/');
    });

    test('unreachable remote server ends authorized connections cleanly '
        'with an empty answer and no TCP reset', () async {
      final res = await reach.resolve(Uri.parse('http://localhost:9/'));
      final hostHeader = '${res.localHost}:${res.localPort}';
      for (var attempt = 0; attempt < 5; attempt++) {
        final fresh = await reach.resolve(Uri.parse('http://localhost:9/'));
        final token = fresh.headers[kBrowserForwardAuthHeader]!;
        final answer = await _rawHttp(
          res.localPort!,
          'GET / HTTP/1.1\r\n'
          'Host: $hostHeader\r\n'
          '$kBrowserForwardAuthHeader: $token\r\n'
          '\r\n',
        );
        expect(answer, isEmpty, reason: 'attempt $attempt');
      }
      // localhost tries 127.0.0.1 then falls back to ::1 when refused.
      expect(dialer.dialed, hasLength(10));
      expect(dialer.dialed[0], ('127.0.0.1', 9));
      expect(dialer.dialed[1], ('::1', 9));
    });
  });

  group('protocol and IPv6 family fidelity', () {
    test('https loopback is explicitly refused and never dialed', () async {
      final dialer = _Dialer(const {});
      final reach = BrowserLoopbackReach(dial: dialer.call);
      addTearDown(reach.close);

      for (final url in [
        'https://localhost:8443/app',
        'https://127.0.0.1:8443/',
        'https://[::1]:8443/',
      ]) {
        final res = await reach.resolve(Uri.parse(url));
        expect(res.status, BrowserLoopbackStatus.unsupportedHttps, reason: url);
      }
      expect(reach.activeForwardCount, 0);
      expect(dialer.dialed, isEmpty);
    });

    test('[::1] dials ::1 only and localhost falls back to ::1', () async {
      _TestDevServer? v6Server;
      try {
        v6Server = await _TestDevServer.start(
          address: InternetAddress.loopbackIPv6,
        );
      } on SocketException {
        // Test environment lacks IPv6 loopback; still verify dialed host via
        // IPv4-backed socket so the contract is asserted everywhere.
      }
      final fallbackServer = v6Server == null
          ? await _TestDevServer.start()
          : null;
      addTearDown(() async {
        await v6Server?.stop();
        await fallbackServer?.stop();
      });

      final targetAddr = v6Server != null ? '::1' : '127.0.0.1';
      final targetPort = v6Server?.port ?? fallbackServer!.port;
      final dialer = _Dialer({('::1', 5173): (targetAddr, targetPort)});
      final reach = BrowserLoopbackReach(dial: dialer.call);
      addTearDown(reach.close);

      // Explicit [::1] dials ::1 ONLY (never 127.0.0.1).
      final v6Res = await reach.resolve(
        Uri.parse('http://[::1]:5173/v6'),
        ownerId: 'tab-v6',
      );
      expect(v6Res.status, BrowserLoopbackStatus.forwarded);
      final v6Resp = await _rawHttp(
        v6Res.localPort!,
        'GET /v6 HTTP/1.1\r\n'
        'Host: ${v6Res.localHost}:${v6Res.localPort}\r\n'
        '$kBrowserForwardAuthHeader: '
        '${v6Res.headers[kBrowserForwardAuthHeader]}\r\n'
        '\r\n',
      );
      expect(v6Resp, startsWith('HTTP/1.1 200 OK'));
      expect(dialer.dialed, [('::1', 5173)]);
      final seenHost = (v6Server ?? fallbackServer)!.seenHeaders.last['host'];
      expect(seenHost, '[::1]:5173');
      expect(
        reach.reveal('http://${v6Res.localHost}:${v6Res.localPort}/v6'),
        'http://[::1]:5173/v6',
      );

      // localhost tries 127.0.0.1, then falls back to ::1 and succeeds.
      dialer.dialed.clear();
      final localRes = await reach.resolve(
        Uri.parse('http://localhost:5173/fb'),
        ownerId: 'tab-local',
      );
      final localResp = await _rawHttp(
        localRes.localPort!,
        'GET /fb HTTP/1.1\r\n'
        'Host: ${localRes.localHost}:${localRes.localPort}\r\n'
        '$kBrowserForwardAuthHeader: '
        '${localRes.headers[kBrowserForwardAuthHeader]}\r\n'
        '\r\n',
      );
      expect(localResp, startsWith('HTTP/1.1 200 OK'));
      expect(dialer.dialed, [('127.0.0.1', 5173), ('::1', 5173)]);
    });
  });

  group('lifecycle, TTL, single-flight, and SSH deadlines', () {
    test('forward lives only while an owner tab holds that origin', () async {
      final dialer = _Dialer(const {});
      var suspendCount = 0;
      final reach = BrowserLoopbackReach(
        dial: dialer.call,
        onSuspend: () async => suspendCount++,
      );
      addTearDown(reach.close);

      final t1 = await reach.resolve(
        Uri.parse('http://localhost:5173/a'),
        ownerId: 'tab-1',
      );
      final t2 = await reach.resolve(
        Uri.parse('http://localhost:5173/b'),
        ownerId: 'tab-2',
      );
      expect(t2.localPort, t1.localPort);
      expect(t2.localHost, t1.localHost);

      // Closing tab-1 keeps the forward open for tab-2.
      await reach.releaseOwner('tab-1');
      expect(reach.activeForwardCount, 1);

      // Navigating tab-2 away to an ordinary web site closes the forward.
      final away = await reach.resolve(
        Uri.parse('https://example.com/'),
        ownerId: 'tab-2',
      );
      expect(away.status, BrowserLoopbackStatus.passthrough);
      expect(reach.activeForwardCount, 0);
      expect(suspendCount, 1);
      await _expectPortRefuses(t1.localPort!);
    });

    test('deterministic lease TTL tears down idle forward', () async {
      final dialer = _Dialer(const {});
      final reach = BrowserLoopbackReach(
        dial: dialer.call,
        leaseDuration: const Duration(milliseconds: 60),
      );
      addTearDown(reach.close);

      final res = await reach.resolve(Uri.parse('http://localhost:5173/'));
      expect(reach.activeForwardCount, 1);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(reach.activeForwardCount, 0);
      await _expectPortRefuses(res.localPort!);
      // Retired reveal still maps old URL back to asked loopback.
      expect(
        reach.reveal('http://${res.localHost}:${res.localPort}/x'),
        'http://localhost:5173/x',
      );
    });

    test('single-flight reconnect closes dead client and opens only one '
        'replacement under concurrent dials', () async {
      final server = await _TestDevServer.start();
      addTearDown(server.stop);
      final dialer = _Dialer({('127.0.0.1', 5173): ('127.0.0.1', server.port)});

      var connectCalls = 0;
      final opened = <_FakeSshTransport>[];
      Completer<_FakeSshTransport>? gate;

      final reach = BrowserLoopbackReach.overTransport(
        live: () => null,
        connect: () {
          connectCalls++;
          final currentGate = gate;
          if (currentGate != null) return currentGate.future;
          final t = _FakeSshTransport(dialer.call);
          opened.add(t);
          return Future.value(t);
        },
      );
      addTearDown(reach.close);

      final res = await reach.resolve(Uri.parse('http://localhost:5173/'));
      final hostHeader = '${res.localHost}:${res.localPort}';
      final first = await _rawHttp(
        res.localPort!,
        'GET /1 HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        '$kBrowserForwardAuthHeader: ${res.headers[kBrowserForwardAuthHeader]}\r\n'
        '\r\n',
      );
      expect(first, startsWith('HTTP/1.1 200 OK'));
      final cookie = _extractCookieValue(first, kBrowserForwardCookieName)!;
      expect(connectCalls, 1);

      // Simulate cached client closing, then fire two concurrent requests.
      opened.first.close();
      gate = Completer<_FakeSshTransport>();
      final reqA = _rawHttp(
        res.localPort!,
        'GET /a HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        'Cookie: $kBrowserForwardCookieName=$cookie\r\n'
        '\r\n',
      );
      final reqB = _rawHttp(
        res.localPort!,
        'GET /b HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        'Cookie: $kBrowserForwardCookieName=$cookie\r\n'
        '\r\n',
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(connectCalls, 2, reason: 'concurrent accepts share one reconnect');

      final replacement = _FakeSshTransport(dialer.call);
      opened.add(replacement);
      gate.complete(replacement);

      final answers = await Future.wait([reqA, reqB]);
      expect(answers[0], startsWith('HTTP/1.1 200 OK'));
      expect(answers[1], startsWith('HTTP/1.1 200 OK'));

      await reach.close();
      expect(replacement.isClosed, isTrue);
      expect(replacement.closeCount, greaterThanOrEqualTo(1));
    });

    test('connect deadline bounds hung SSH auth and closes late client; '
        'close() never waits on hung connect', () async {
      final hung = Completer<_FakeSshTransport>();
      var connectCalls = 0;
      final reach = BrowserLoopbackReach.overTransport(
        live: () => null,
        connect: () {
          connectCalls++;
          return hung.future;
        },
        connectTimeout: const Duration(milliseconds: 50),
      );

      final res = await reach.resolve(Uri.parse('http://localhost:5173/'));
      final hostHeader = '${res.localHost}:${res.localPort}';
      final started = DateTime.now();
      final answer = await _rawHttp(
        res.localPort!,
        'GET / HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        '$kBrowserForwardAuthHeader: ${res.headers[kBrowserForwardAuthHeader]}\r\n'
        '\r\n',
      );
      expect(answer, isEmpty);
      expect(connectCalls, 1);
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 2)),
      );

      // Start a second hung connect and call close() immediately: close must
      // not block, and when the hung connect finishes later it must be closed.
      final hung2 = Completer<_FakeSshTransport>();
      final reach2 = BrowserLoopbackReach.overTransport(
        live: () => null,
        connect: () => hung2.future,
        connectTimeout: const Duration(seconds: 30),
      );
      final res2 = await reach2.resolve(Uri.parse('http://localhost:5173/'));
      final inflightReq = _rawHttp(
        res2.localPort!,
        'GET / HTTP/1.1\r\n'
        'Host: ${res2.localHost}:${res2.localPort}\r\n'
        '$kBrowserForwardAuthHeader: '
        '${res2.headers[kBrowserForwardAuthHeader]}\r\n'
        '\r\n',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final closeStart = DateTime.now();
      await reach2.close();
      expect(
        DateTime.now().difference(closeStart),
        lessThan(const Duration(seconds: 1)),
      );
      await inflightReq.catchError((_) => '');

      // Late arrivals from both hung connects must be closed immediately.
      final late1 = _FakeSshTransport(_Dialer(const {}).call);
      final late2 = _FakeSshTransport(_Dialer(const {}).call);
      hung.complete(late1);
      hung2.complete(late2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(late1.isClosed, isTrue);
      expect(late2.isClosed, isTrue);
      await reach.close();
    });
  });

  group('browser widget integration', () {
    late FakeWebViewPlatform web;

    setUp(() {
      web = FakeWebViewPlatform();
      WebViewPlatform.instance = web;
    });

    Future<Uri> waitForForwardLoad(
      WidgetTester tester, {
      int skip = 0,
    }) async {
      for (var i = 0; i < 25; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        final all = web.controllers
            .expand((c) => c.loadedRequests)
            .where((u) => isInternalBrowserForwardHost(u.host))
            .toList();
        if (all.length > skip) return all[skip];
      }
      fail('expected a forwarded *.localhost load');
    }

    testWidgets('loads via isolated *.localhost with bootstrap header, shows '
        'asked URL, and closes forward on last tab close and Close all', (
      tester,
    ) async {
      final dialer = _Dialer(const {});
      BrowserLoopbackReach? made;
      final tabs = BrowserTabs()
        ..open(url: Uri.parse('http://localhost:5173/app'));

      await tester.pumpWidget(
        _browserApp(
          InAppTabbedBrowser(
            tabs: tabs,
            loopbackReachScope: 'profile-1',
            loopbackReach: () =>
                made = BrowserLoopbackReach(dial: dialer.call),
          ),
        ),
      );
      final loaded = await waitForForwardLoad(tester);
      expect(made, isNotNull);
      expect(loaded.path, '/app');
      expect(
        web.controllers.first.loadedRequestHeaders.last[kBrowserForwardAuthHeader],
        isNotEmpty,
      );
      expect(
        web.controllers
            .expand((c) => c.loadedRequests)
            .where((u) => u.host == 'localhost'),
        isEmpty,
        reason: 'the phone loopback is never requested',
      );

      web.delegates.last.load(loaded.toString());
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('in-app-browser-address')),
            )
            .controller!
            .text,
        'http://localhost:5173/app',
      );

      // Closing the last tab on that origin immediately tears down the port
      // even though the tabbed browser stays mounted with a blank tab.
      tabs.close(tabs.active!.id);
      await tester.pump();
      await tester.runAsync(() => _expectPortRefuses(loaded.port));
      expect(made!.activeForwardCount, 0);

      // Open two forwarded origins, then Close all: both forwards close.
      tabs.open(url: Uri.parse('http://localhost:5173/one'));
      await tester.pump();
      final p1 = await waitForForwardLoad(tester, skip: 1);
      tabs.open(url: Uri.parse('http://localhost:8080/two'));
      await tester.pump();
      final p2 = await waitForForwardLoad(tester, skip: 2);
      expect(made!.activeForwardCount, 2);

      tabs.closeAll();
      await tester.pump();
      await tester.runAsync(() async {
        await _expectPortRefuses(p1.port);
        await _expectPortRefuses(p2.port);
      });
      expect(made!.activeForwardCount, 0);
    });

    testWidgets('removing or changing SSH profile closes old reach and ports', (
      tester,
    ) async {
      final dialer = _Dialer(const {});
      final created = <BrowserLoopbackReach>[];
      final tabs = BrowserTabs()
        ..open(url: Uri.parse('http://localhost:5173/app'));

      await tester.pumpWidget(
        _browserApp(
          InAppTabbedBrowser(
            tabs: tabs,
            loopbackReachScope: 'profile-a',
            loopbackReach: () {
              final r = BrowserLoopbackReach(dial: dialer.call);
              created.add(r);
              return r;
            },
          ),
        ),
      );
      final first = await waitForForwardLoad(tester);
      expect(created, hasLength(1));

      // Changing SSH profile scope closes profile-a's reach and creates a new
      // isolated reach for profile-b.
      await tester.pumpWidget(
        _browserApp(
          InAppTabbedBrowser(
            tabs: tabs,
            loopbackReachScope: 'profile-b',
            loopbackReach: () {
              final r = BrowserLoopbackReach(dial: dialer.call);
              created.add(r);
              return r;
            },
          ),
        ),
      );
      await tester.pump();
      expect(created, hasLength(2));
      expect(created[0].isClosed, isTrue);
      await tester.runAsync(() => _expectPortRefuses(first.port));

      // Removing SSH profile (loopbackReach == null) closes profile-b's reach.
      await tester.pumpWidget(
        _browserApp(InAppTabbedBrowser(tabs: tabs)),
      );
      await tester.pump();
      expect(created[1].isClosed, isTrue);
    });

    testWidgets('offstage panel and app background tear down forwards after '
        'grace period and reload re-establishes transparently', (tester) async {
      final dialer = _Dialer(const {});
      BrowserLoopbackReach? made;
      final tabs = BrowserTabs()
        ..open(url: Uri.parse('http://localhost:5173/app'));

      Widget host({required bool offstage}) => _browserApp(
        Offstage(
          offstage: offstage,
          child: TickerMode(
            enabled: !offstage,
            child: InAppTabbedBrowser(
              tabs: tabs,
              loopbackReachScope: 'profile-1',
              hiddenGraceDuration: const Duration(milliseconds: 40),
              loopbackReach: () =>
                  made = BrowserLoopbackReach(dial: dialer.call),
            ),
          ),
        ),
      );

      await tester.pumpWidget(host(offstage: false));
      final first = await waitForForwardLoad(tester);
      web.delegates.last.load(first.toString());
      await tester.pump();

      // Hide panel offstage -> grace expires -> forward closes.
      await tester.pumpWidget(host(offstage: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.runAsync(() => _expectPortRefuses(first.port));
      expect(made!.activeForwardCount, 0);

      // Bring panel back and tap Reload -> fresh isolated forward opens.
      await tester.pumpWidget(host(offstage: false));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('in-app-browser-reload')));
      await tester.pump();
      final second = await waitForForwardLoad(tester, skip: 1);
      expect(second.host, isNot(first.host));
      web.delegates.last.load(second.toString());
      await tester.pump();

      // App goes to background -> grace expires -> forward closes.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.runAsync(() => _expectPortRefuses(second.port));
      expect(made!.activeForwardCount, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('WebView loopback redirects, subframe loopback, cross-forward '
        'links, and HTTPS loopback are handled safely without hitting phone', (
      tester,
    ) async {
      final dialer = _Dialer(const {});
      final reach = BrowserLoopbackReach(dial: dialer.call);
      addTearDown(reach.close);

      await tester.pumpWidget(
        _browserApp(
          InAppBrowserScreen(
            initialUrl: Uri.parse('http://localhost:5173/start'),
            loopbackReach: reach,
          ),
        ),
      );
      final first = await waitForForwardLoad(tester);
      web.delegates.last.load(first.toString());
      await tester.pump();

      // Main-frame redirect to another loopback port is prevented from hitting
      // the phone and re-routed through SSH reach.
      final redirectDecision = await web.delegates.last.request(
        'http://localhost:8080/next',
      );
      expect(redirectDecision, NavigationDecision.prevent);
      final second = await waitForForwardLoad(tester, skip: 1);
      expect(second.host, isNot(first.host));
      expect(second.path, '/next');
      // Old port 5173 forward closed when tab moved to 8080.
      await tester.runAsync(() => _expectPortRefuses(first.port));

      // Subframe attempting raw phone loopback is blocked.
      expect(
        await web.delegates.last.request(
          'http://localhost:8080/embed',
          mainFrame: false,
        ),
        NavigationDecision.prevent,
      );

      // Cross-forward attempt to another internal *.localhost host is blocked.
      expect(
        await web.delegates.last.request(
          'http://h0123456789abcdef01234567.localhost:9999/secret',
        ),
        NavigationDecision.prevent,
      );

      // Explicit HTTPS loopback redirect is refused with clear UI, never
      // downgraded or loaded on the phone.
      final httpsDecision = await web.delegates.last.request(
        'https://localhost:8443/secure',
      );
      expect(httpsDecision, NavigationDecision.prevent);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('in-app-browser-loopback-https-unsupported')),
        findsOneWidget,
      );
      expect(
        web.controllers
            .expand((c) => c.loadedRequests)
            .where((u) => u.host == 'localhost'),
        isEmpty,
      );
    });

    testWidgets('without SSH ordinary web and non-SSH loopback paths stay '
        'intact', (tester) async {
      final tabs = BrowserTabs()
        ..open(url: Uri.parse('https://example.com/docs'));
      await tester.pumpWidget(
        _browserApp(
          InAppTabbedBrowser(key: const ValueKey('web'), tabs: tabs),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        web.controllers.expand((c) => c.loadedRequests),
        contains(Uri.parse('https://example.com/docs')),
      );

      final localTabs = BrowserTabs()
        ..open(url: Uri.parse('http://localhost:5173/app'));
      await tester.pumpWidget(
        _browserApp(
          InAppTabbedBrowser(key: const ValueKey('local'), tabs: localTabs),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        web.controllers.expand((c) => c.loadedRequests),
        contains(Uri.parse('http://localhost:5173/app')),
      );
    });
  });
}
