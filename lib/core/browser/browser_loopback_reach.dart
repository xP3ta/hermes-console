// Authenticated loopback forwarding over SSH for the in-app browser.
//
// Compared to Hermes Desktop (`apps/desktop/electron/preview-reach.ts`),
// Android runs every app in its own UID sandbox while sharing the device's
// loopback network namespace, and all Android WebViews share one CookieManager.
// We therefore do NOT copy Electron's raw `127.0.0.1:<port>` TCP forward:
//
// * Each HTTP loopback forward binds a unique cryptographically random
//   `h<24-hex>.localhost` host on the phone's loopback (dual-stack 127.0.0.1
//   and ::1 on the same port when IPv6 is available, preventing port
//   squatting). Chromium's `HostResolverManager::ServeLocalhost` resolves
//   `*.localhost` locally without DNS, and `CanonicalCookie` isolates sibling
//   `*.localhost` hosts from each other and from `localhost` without clearing
//   any normal website cookies.
// * Every connection to the local proxy must match the forward's `Host`, pass
//   same-origin / `Sec-Fetch-Site` checks, and present either a single-use
//   bootstrap header (`X-Hermes-Forward-Auth`, attached by our WebView load)
//   or the forward's `HttpOnly; SameSite=Strict` session cookie
//   (`__hermes_fwd`). Other apps on the phone or cross-origin pages receive
//   403 without dialing SSH.
// * `https://` loopback addresses are never downgraded to HTTP, never exposed
//   over an unauthenticated raw TLS forward, and never silently sent to the
//   phone; callers receive `BrowserLoopbackStatus.unsupportedHttps`.
// * Address family is respected: `[::1]` dials `::1` only, `127.0.0.1` and
//   `0.0.0.0` dial `127.0.0.1` only, and `localhost` dials `127.0.0.1` with
//   fallback to `::1`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

/// Opens a channel to [host]:[port] as the SSH server sees it
/// (`SSHClient.forwardLocal`).
typedef BrowserLoopbackDial = Future<SSHSocket> Function(String host, int port);

/// Header carrying the single-use bootstrap token on the WebView's initial
/// load of a forwarded loopback origin.
const String kBrowserForwardAuthHeader = 'x-hermes-forward-auth';

/// `HttpOnly; SameSite=Strict` cookie authenticating subsequent subresources,
/// navigations, and WebSockets on a forward's isolated `*.localhost` host.
const String kBrowserForwardCookieName = '__hermes_fwd';

/// Default idle/lease lifetime of a forward (matches Desktop's
/// `PREVIEW_REACH_LEASE_MS`).
const Duration kBrowserLoopbackLeaseDuration = Duration(minutes: 15);

/// Default deadline for opening and authenticating a browser-owned SSH client.
const Duration kBrowserSshConnectTimeout = Duration(seconds: 30);

/// Default deadline for opening a single forwarded SSH channel.
const Duration kBrowserSshDialTimeout = Duration(seconds: 15);

/// Hosts that mean "the machine this resolved on" (Desktop's
/// `LOOPBACK_HOSTS`).
const Set<String> _loopbackHosts = {'0.0.0.0', '127.0.0.1', '::1', 'localhost'};

final RegExp _internalForwardHostPattern = RegExp(
  r'^h[0-9a-f]{24}\.localhost$',
  caseSensitive: false,
);

/// True when [host] is an ephemeral isolated host minted by
/// [BrowserLoopbackReach].
bool isInternalBrowserForwardHost(String host) =>
    _internalForwardHostPattern.hasMatch(host);

/// Parsed loopback target for a browsable `http`/`https` URI.
@immutable
class BrowserLoopbackTarget {
  const BrowserLoopbackTarget({
    required this.scheme,
    required this.askedHost,
    required this.dialHosts,
    required this.port,
  });

  /// Requested scheme (`http` or `https`).
  final String scheme;

  /// Lowercase host as requested (`localhost`, `127.0.0.1`, `::1`, `0.0.0.0`).
  final String askedHost;

  /// Remote loopback address(es) to dial on the SSH server, in order.
  final List<String> dialHosts;

  /// Target port on the remote host.
  final int port;

  bool get isHttps => scheme == 'https';

  /// Unique origin key isolating forwards per `(askedHost, port)`.
  String get originKey => '$askedHost:$port';

  /// RFC 9110 authority for `Host`, `Origin`, and `Referer` headers.
  String get authority {
    final hostPart = askedHost.contains(':') ? '[$askedHost]' : askedHost;
    return port == 80 ? hostPart : '$hostPart:$port';
  }
}

/// Parses [uri] as a remote loopback target, or returns null when [uri] is not
/// a loopback `http`/`https` address.
BrowserLoopbackTarget? browserLoopbackTarget(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  final host = uri.host.toLowerCase();
  if (!_loopbackHosts.contains(host)) return null;
  final port = uri.port;
  if (port <= 0 || port >= 65536) return null;
  final dialHosts = switch (host) {
    '::1' => const ['::1'],
    '127.0.0.1' || '0.0.0.0' => const ['127.0.0.1'],
    _ => const ['127.0.0.1', '::1'],
  };
  return BrowserLoopbackTarget(
    scheme: scheme,
    askedHost: host,
    dialHosts: dialHosts,
    port: port,
  );
}

/// The server port a loopback [uri] points at, or null when [uri] is not a
/// loopback `http`/`https` address.
int? browserLoopbackPort(Uri uri) => browserLoopbackTarget(uri)?.port;

/// Rewrites an `http` loopback [uri] onto a forward's local endpoint, keeping
/// path, query, and fragment. Never silently downgrades `https` to `http`.
Uri browserLoopbackRewrite(
  Uri uri,
  int localPort, {
  required String localHost,
}) {
  if (uri.scheme.toLowerCase() != 'http') {
    throw ArgumentError.value(
      uri,
      'uri',
      'Only http loopback URIs can be rewritten onto a local forward',
    );
  }
  return uri.replace(scheme: 'http', host: localHost, port: localPort);
}

/// Outcome of resolving a URL against [BrowserLoopbackReach].
enum BrowserLoopbackStatus {
  /// Non-loopback web address: load directly as an ordinary web page.
  passthrough,

  /// HTTP loopback address mapped to an isolated, authenticated local forward.
  forwarded,

  /// HTTPS loopback address: refused with an explicit state (never downgraded
  /// to HTTP, never weakening TLS, never resolved to the phone).
  unsupportedHttps,

  /// Reach is closed or could not open the local forward: never fall back to
  /// resolving loopback on the phone.
  unavailable,
}

/// Result returned by [BrowserLoopbackReach.resolve].
@immutable
class BrowserLoopbackResolution {
  const BrowserLoopbackResolution._({
    required this.status,
    required this.uri,
    this.headers = const {},
    this.originKey,
    this.localHost,
    this.localPort,
  });

  const BrowserLoopbackResolution.passthrough(Uri uri)
    : this._(status: BrowserLoopbackStatus.passthrough, uri: uri);

  const BrowserLoopbackResolution.forwarded({
    required Uri uri,
    required Map<String, String> headers,
    required String originKey,
    required String localHost,
    required int localPort,
  }) : this._(
         status: BrowserLoopbackStatus.forwarded,
         uri: uri,
         headers: headers,
         originKey: originKey,
         localHost: localHost,
         localPort: localPort,
       );

  const BrowserLoopbackResolution.unsupportedHttps(Uri uri)
    : this._(status: BrowserLoopbackStatus.unsupportedHttps, uri: uri);

  const BrowserLoopbackResolution.unavailable(Uri uri)
    : this._(status: BrowserLoopbackStatus.unavailable, uri: uri);

  final BrowserLoopbackStatus status;
  final Uri uri;
  final Map<String, String> headers;
  final String? originKey;
  final String? localHost;
  final int? localPort;
}

/// Minimal SSH transport contract for loopback forwarding, allowing tests to
/// verify single-flight, deadlines, and disposal without a real SSH daemon.
abstract interface class BrowserSshTransport {
  bool get isClosed;
  Future<SSHSocket> forwardLocal(String remoteHost, int remotePort);
  void close();
}

class _DartSshTransport implements BrowserSshTransport {
  _DartSshTransport(this._client);

  final SSHClient _client;

  @override
  bool get isClosed => _client.isClosed;

  @override
  Future<SSHSocket> forwardLocal(String remoteHost, int remotePort) =>
      _client.forwardLocal(remoteHost, remotePort);

  @override
  void close() => _client.close();
}

/// Opens an [SSHClient] and completes authentication within [timeout],
/// guaranteeing the client is closed if authentication throws or times out.
Future<SSHClient> connectBrowserSshClient({
  required Future<SSHClient> Function() open,
  Duration timeout = kBrowserSshConnectTimeout,
}) async {
  final client = await open().timeout(timeout);
  try {
    await client.authenticated.timeout(timeout);
    return client;
  } catch (_) {
    client.close();
    rethrow;
  }
}

/// Single-flight owner of a browser's fallback SSH transport.
///
/// Reuses [live] whenever the terminal's SSH session is ready; otherwise opens
/// at most one browser-owned transport at a time with a bounded deadline,
/// tracks every transport ever opened, and closes all of them immediately on
/// [releaseOwned] or [dispose] without waiting on a stuck handshake.
class _SshTransportPool {
  _SshTransportPool({
    required this.live,
    required this.connect,
    required this.connectTimeout,
  });

  final BrowserSshTransport? Function() live;
  final Future<BrowserSshTransport> Function() connect;
  final Duration connectTimeout;

  bool _disposed = false;
  int _generation = 0;
  BrowserSshTransport? _active;
  Future<BrowserSshTransport>? _opening;
  void Function()? _abortOpening;
  final Set<BrowserSshTransport> _owned = {};

  Future<BrowserSshTransport> acquire() {
    if (_disposed) {
      return Future<BrowserSshTransport>.error(
        StateError('Browser SSH reach is closed'),
      );
    }
    final existingLive = live();
    if (existingLive != null && !existingLive.isClosed) {
      return Future<BrowserSshTransport>.value(existingLive);
    }
    final active = _active;
    if (active != null) {
      if (!active.isClosed) {
        return Future<BrowserSshTransport>.value(active);
      }
      _active = null;
      _owned.remove(active);
      _closeQuietly(active);
    }
    final inflight = _opening;
    if (inflight != null) return inflight;

    final generation = _generation;
    final completer = Completer<BrowserSshTransport>();
    final pending = completer.future;
    _opening = pending;

    Timer? timer;
    void clearInflight() {
      timer?.cancel();
      timer = null;
      if (identical(_opening, pending)) {
        _opening = null;
        _abortOpening = null;
      }
    }

    _abortOpening = () {
      clearInflight();
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Browser SSH reach closed while connecting'),
        );
      }
    };

    timer = Timer(connectTimeout, () {
      clearInflight();
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('SSH connection timed out', connectTimeout),
        );
      }
    });

    Future<BrowserSshTransport>.sync(connect).then(
      (transport) {
        clearInflight();
        if (_disposed || generation != _generation || completer.isCompleted) {
          _closeQuietly(transport);
          return;
        }
        _owned.add(transport);
        _active = transport;
        completer.complete(transport);
      },
      onError: (Object error, StackTrace stackTrace) {
        clearInflight();
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    return pending;
  }

  /// Drops and closes every browser-owned transport immediately without
  /// awaiting any in-flight handshake.
  void releaseOwned() {
    _generation++;
    _abortOpening?.call();
    _opening = null;
    _abortOpening = null;
    _active = null;
    final toClose = [..._owned];
    _owned.clear();
    for (final transport in toClose) {
      _closeQuietly(transport);
    }
  }

  void dispose() {
    _disposed = true;
    releaseOwned();
  }

  static void _closeQuietly(BrowserSshTransport transport) {
    try {
      transport.close();
    } catch (_) {
      // Already closed or torn down.
    }
  }
}

/// Manages authenticated, per-origin isolated SSH loopback forwards for one
/// browser instance (authorized by one SSH profile scope).
class BrowserLoopbackReach {
  BrowserLoopbackReach({
    required this.dial,
    this.onSuspend,
    this.onClose,
    this.leaseDuration = kBrowserLoopbackLeaseDuration,
    this.dialTimeout = kBrowserSshDialTimeout,
    this.headerReadTimeout = const Duration(seconds: 15),
    this.bootstrapTokenTtl = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Builds a reach backed by an injectable [BrowserSshTransport] pool.
  factory BrowserLoopbackReach.overTransport({
    required BrowserSshTransport? Function() live,
    required Future<BrowserSshTransport> Function() connect,
    Duration connectTimeout = kBrowserSshConnectTimeout,
    Duration dialTimeout = kBrowserSshDialTimeout,
    Duration leaseDuration = kBrowserLoopbackLeaseDuration,
    Duration headerReadTimeout = const Duration(seconds: 15),
    Duration bootstrapTokenTtl = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) {
    final pool = _SshTransportPool(
      live: live,
      connect: connect,
      connectTimeout: connectTimeout,
    );
    return BrowserLoopbackReach(
      dial: (host, port) async =>
          (await pool.acquire()).forwardLocal(host, port),
      onSuspend: () async => pool.releaseOwned(),
      onClose: () async => pool.dispose(),
      leaseDuration: leaseDuration,
      dialTimeout: dialTimeout,
      headerReadTimeout: headerReadTimeout,
      bootstrapTokenTtl: bootstrapTokenTtl,
      clock: clock,
    );
  }

  /// Over the SSH profile of a connection: uses the terminal's own client
  /// while ready ([live]), else opens a single-flight client ([connect]) with
  /// [connectTimeout], closed when forwards are suspended or the browser goes.
  factory BrowserLoopbackReach.overSsh({
    required SSHClient? Function() live,
    required Future<SSHClient> Function() connect,
    Duration connectTimeout = kBrowserSshConnectTimeout,
    Duration dialTimeout = kBrowserSshDialTimeout,
    Duration leaseDuration = kBrowserLoopbackLeaseDuration,
  }) {
    return BrowserLoopbackReach.overTransport(
      live: () {
        final client = live();
        return client == null ? null : _DartSshTransport(client);
      },
      connect: () async => _DartSshTransport(
        await connectBrowserSshClient(open: connect, timeout: connectTimeout),
      ),
      connectTimeout: connectTimeout,
      dialTimeout: dialTimeout,
      leaseDuration: leaseDuration,
    );
  }

  /// Default owner identifier when a caller does not distinguish tabs.
  static const String defaultOwnerId = '_default';

  /// Opens each forwarded channel on the SSH server.
  final BrowserLoopbackDial dial;

  /// Called when all forwards are torn down while the reach remains reusable
  /// (last tab left, panel offstage, app in background).
  final Future<void> Function()? onSuspend;

  /// Called once on permanent [close].
  final Future<void> Function()? onClose;

  final Duration leaseDuration;
  final Duration dialTimeout;
  final Duration headerReadTimeout;
  final Duration bootstrapTokenTtl;
  final DateTime Function() _clock;

  final Map<String, Future<_LoopbackForward>> _forwards = {};
  final Map<String, _LoopbackForward> _liveForwards = {};
  final Map<String, _LoopbackForward> _byEndpoint = {};
  final Map<String, BrowserLoopbackTarget> _retiredReveal = {};
  final Map<String, Set<String>> _originOwners = {};
  final Map<String, String> _ownerOrigin = {};
  bool _closed = false;

  bool get isClosed => _closed;

  /// Resolves [uri] for [ownerId] (a tab or standalone browser screen).
  ///
  /// * Non-loopback URLs release any forward previously held by [ownerId] and
  ///   return [BrowserLoopbackStatus.passthrough].
  /// * `https://` loopback URLs release any previous forward and return
  ///   [BrowserLoopbackStatus.unsupportedHttps] (never downgraded to HTTP).
  /// * `http://` loopback URLs attach [ownerId] to an isolated, authenticated
  ///   local forward and return [BrowserLoopbackStatus.forwarded] with a
  ///   single-use bootstrap header.
  Future<BrowserLoopbackResolution> resolve(
    Uri uri, {
    String ownerId = defaultOwnerId,
  }) async {
    final target = browserLoopbackTarget(uri);
    if (target == null) {
      await releaseOwner(ownerId);
      return BrowserLoopbackResolution.passthrough(uri);
    }
    if (target.isHttps) {
      await releaseOwner(ownerId);
      return BrowserLoopbackResolution.unsupportedHttps(uri);
    }
    if (_closed) {
      return BrowserLoopbackResolution.unavailable(uri);
    }

    final originKey = target.originKey;
    await _attachOwner(ownerId, originKey);

    var pending = _forwards[originKey];
    if (pending != null) {
      final live = _liveForwards[originKey];
      if (live != null && (live.isClosed || live.isExpired)) {
        await _closeOrigin(originKey);
        pending = null;
      }
    }

    pending ??= _forwards[originKey] = _LoopbackForward.open(
      target: target,
      dial: dial,
      leaseDuration: leaseDuration,
      dialTimeout: dialTimeout,
      headerReadTimeout: headerReadTimeout,
      bootstrapTokenTtl: bootstrapTokenTtl,
      clock: _clock,
      onExpired: (forward) =>
          unawaited(_handleForwardExpired(originKey, forward)),
    );

    final _LoopbackForward forward;
    try {
      forward = await pending;
    } catch (error) {
      debugPrint(
        '[browser] loopback forward bind failed (${error.runtimeType})',
      );
      if (identical(_forwards[originKey], pending)) {
        _forwards.remove(originKey);
      }
      await _detachOwnerIfHolding(ownerId, originKey);
      return BrowserLoopbackResolution.unavailable(uri);
    }

    if (_closed || _ownerOrigin[ownerId] != originKey) {
      if (_closed || (_originOwners[originKey]?.isEmpty ?? true)) {
        await _closeForwardInstance(originKey, forward);
      }
      return BrowserLoopbackResolution.unavailable(uri);
    }

    _liveForwards[originKey] = forward;
    _byEndpoint[_endpointKey(forward.localHost, forward.localPort)] = forward;
    forward.touch();
    final bootstrap = forward.mintBootstrapToken();
    final rewritten = browserLoopbackRewrite(
      uri,
      forward.localPort,
      localHost: forward.localHost,
    );
    return BrowserLoopbackResolution.forwarded(
      uri: rewritten,
      headers: {kBrowserForwardAuthHeader: bootstrap},
      originKey: originKey,
      localHost: forward.localHost,
      localPort: forward.localPort,
    );
  }

  /// True when [ownerId] currently holds a live, non-expired forward matching
  /// [askedUri].
  bool hasLiveForwardFor(String ownerId, Uri askedUri) {
    if (_closed) return false;
    final target = browserLoopbackTarget(askedUri);
    if (target == null || target.isHttps) return false;
    final originKey = _ownerOrigin[ownerId];
    if (originKey != target.originKey) return false;
    final forward = _liveForwards[originKey];
    return forward != null && !forward.isClosed && !forward.isExpired;
  }

  /// True when [uri] points at the currently live forward held by [ownerId].
  bool isOwnLiveForwardUri(String ownerId, Uri uri) {
    if (_closed || uri.scheme.toLowerCase() != 'http') return false;
    final originKey = _ownerOrigin[ownerId];
    if (originKey == null) return false;
    final forward = _liveForwards[originKey];
    if (forward == null || forward.isClosed || forward.isExpired) return false;
    return uri.host.toLowerCase() == forward.localHost &&
        uri.port == forward.localPort;
  }

  /// True when [uri] points at a retired (suspended/expired) forward of this
  /// reach so a reload or link click can transparently re-establish it.
  bool isRetiredForwardUri(Uri uri) {
    if (_closed || uri.scheme.toLowerCase() != 'http') return false;
    return _retiredReveal.containsKey(_endpointKey(uri.host, uri.port));
  }

  /// Releases any forward held by [ownerId]. Closes the forward immediately
  /// when [ownerId] was its last owner.
  Future<void> releaseOwner(String ownerId) async {
    final originKey = _ownerOrigin.remove(ownerId);
    if (originKey == null) return;
    final owners = _originOwners[originKey];
    if (owners == null) return;
    owners.remove(ownerId);
    if (owners.isEmpty) {
      _originOwners.remove(originKey);
      await _closeOrigin(originKey);
      await _maybeSuspendTransport();
    }
  }

  /// Releases every owner not present in [activeOwnerIds], closing any
  /// forwards that become unowned.
  Future<void> retainOwners(Set<String> activeOwnerIds) async {
    final stale = [
      for (final owner in _ownerOrigin.keys)
        if (!activeOwnerIds.contains(owner)) owner,
    ];
    for (final owner in stale) {
      await releaseOwner(owner);
    }
  }

  /// Translates a forward's local `h<hex>.localhost:<port>` URL (active or
  /// retired) back to the loopback URL the user asked for.
  String reveal(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.toLowerCase() != 'http') return url;
    final key = _endpointKey(uri.host, uri.port);
    final target = _byEndpoint[key]?.target ?? _retiredReveal[key];
    if (target == null) return url;
    return uri
        .replace(scheme: 'http', host: target.askedHost, port: target.port)
        .toString();
  }

  /// Tears down every active forward and releases the browser-owned SSH
  /// transport (for panel offstage / app background). Unlike [close], this
  /// reach can transparently re-establish forwards when the user reloads.
  Future<void> suspend() async {
    if (_closed) return;
    final keys = [..._forwards.keys];
    _originOwners.clear();
    _ownerOrigin.clear();
    for (final key in keys) {
      await _closeOrigin(key);
    }
    await onSuspend?.call();
  }

  /// Permanently closes every forward, clears retired mappings, and disposes
  /// any browser-owned SSH transport.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final keys = [..._forwards.keys];
    _originOwners.clear();
    _ownerOrigin.clear();
    for (final key in keys) {
      await _closeOrigin(key);
    }
    _retiredReveal.clear();
    await onClose?.call();
  }

  /// Active listening addresses across live forwards, for tests.
  @visibleForTesting
  List<InternetAddress> get listeningAddresses => [
    for (final forward in _liveForwards.values) ...forward.addresses,
  ];

  /// Active forward count, for tests.
  @visibleForTesting
  int get activeForwardCount => _liveForwards.length;

  Future<void> _attachOwner(String ownerId, String originKey) async {
    final previous = _ownerOrigin[ownerId];
    if (previous == originKey) return;
    if (previous != null) {
      await releaseOwner(ownerId);
    }
    _ownerOrigin[ownerId] = originKey;
    (_originOwners[originKey] ??= <String>{}).add(ownerId);
  }

  Future<void> _detachOwnerIfHolding(String ownerId, String originKey) async {
    if (_ownerOrigin[ownerId] != originKey) return;
    await releaseOwner(ownerId);
  }

  Future<void> _handleForwardExpired(
    String originKey,
    _LoopbackForward forward,
  ) async {
    if (!identical(_liveForwards[originKey], forward)) return;
    final owners = _originOwners.remove(originKey);
    if (owners != null) {
      for (final owner in owners) {
        if (_ownerOrigin[owner] == originKey) {
          _ownerOrigin.remove(owner);
        }
      }
    }
    await _closeForwardInstance(originKey, forward);
    await _maybeSuspendTransport();
  }

  Future<void> _closeOrigin(String originKey) async {
    final pending = _forwards.remove(originKey);
    final live = _liveForwards.remove(originKey);
    if (live != null) {
      _retire(live);
      await live.close();
      return;
    }
    if (pending == null) return;
    try {
      final forward = await pending;
      _retire(forward);
      await forward.close();
    } catch (_) {
      // It never bound.
    }
  }

  Future<void> _closeForwardInstance(
    String originKey,
    _LoopbackForward forward,
  ) async {
    if (identical(_liveForwards[originKey], forward)) {
      _liveForwards.remove(originKey);
      _forwards.remove(originKey);
    }
    _retire(forward);
    await forward.close();
  }

  void _retire(_LoopbackForward forward) {
    final key = _endpointKey(forward.localHost, forward.localPort);
    if (identical(_byEndpoint[key], forward)) {
      _byEndpoint.remove(key);
    }
    if (!_closed) {
      if (_retiredReveal.length >= 64) {
        _retiredReveal.remove(_retiredReveal.keys.first);
      }
      _retiredReveal[key] = forward.target;
    }
  }

  Future<void> _maybeSuspendTransport() async {
    if (_closed) return;
    if (_forwards.isEmpty && _liveForwards.isEmpty) {
      await onSuspend?.call();
    }
  }

  static String _endpointKey(String host, int port) =>
      '${host.toLowerCase()}:$port';
}

/// One authenticated HTTP/1.1 + WebSocket forward bound to a unique ephemeral
/// `h<24-hex>.localhost` host on the device's loopback interface.
class _LoopbackForward {
  _LoopbackForward._({
    required this._serverV4,
    required this._serverV6,
    required this.localHost,
    required this.sessionToken,
    required this.target,
    required this._dial,
    required Duration leaseDuration,
    required this._dialTimeout,
    required this._headerReadTimeout,
    required this._bootstrapTokenTtl,
    required DateTime Function() clock,
    required this._onExpired,
  }) : _leaseDuration = leaseDuration,
       _clock = clock,
       _expiresAt = clock().add(leaseDuration) {
    _serverV4.listen((socket) => unawaited(_accept(socket)));
    _serverV6?.listen((socket) => unawaited(_accept(socket)));
    _armLeaseTimer();
  }

  static const int _maxHeaderBytes = 64 * 1024;
  static const int _maxBootstrapTokens = 16;
  static final Random _random = Random.secure();

  static Future<_LoopbackForward> open({
    required BrowserLoopbackTarget target,
    required BrowserLoopbackDial dial,
    required Duration leaseDuration,
    required Duration dialTimeout,
    required Duration headerReadTimeout,
    required Duration bootstrapTokenTtl,
    required DateTime Function() clock,
    required void Function(_LoopbackForward) onExpired,
  }) async {
    final (serverV4, serverV6) = await _bindLoopbackPair();
    return _LoopbackForward._(
      serverV4: serverV4,
      serverV6: serverV6,
      localHost: 'h${_randomHex(12)}.localhost',
      sessionToken: _randomHex(32),
      target: target,
      dial: dial,
      leaseDuration: leaseDuration,
      dialTimeout: dialTimeout,
      headerReadTimeout: headerReadTimeout,
      bootstrapTokenTtl: bootstrapTokenTtl,
      clock: clock,
      onExpired: onExpired,
    );
  }

  /// Reserves the same ephemeral port on both 127.0.0.1 and ::1 (when IPv6
  /// loopback is available) so no other process can shadow `[::1]:<port>` when
  /// Chromium resolves `*.localhost` to `[::1, 127.0.0.1]`.
  static Future<(ServerSocket, ServerSocket?)> _bindLoopbackPair() async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final v4 = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      try {
        final v6 = await ServerSocket.bind(
          InternetAddress.loopbackIPv6,
          v4.port,
          v6Only: true,
        );
        return (v4, v6);
      } on SocketException {
        ServerSocket? probe;
        try {
          probe = await ServerSocket.bind(
            InternetAddress.loopbackIPv6,
            0,
            v6Only: true,
          );
        } on SocketException {
          // Host kernel has no IPv6 loopback; IPv4 alone cannot be shadowed.
          return (v4, null);
        } finally {
          await probe?.close();
        }
        await v4.close();
      }
    }
    throw const SocketException('Could not reserve dual-stack loopback port');
  }

  static String _randomHex(int byteCount) {
    final buf = StringBuffer();
    for (var i = 0; i < byteCount; i++) {
      buf.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  final ServerSocket _serverV4;
  final ServerSocket? _serverV6;
  final String localHost;
  final String sessionToken;
  final BrowserLoopbackTarget target;
  final BrowserLoopbackDial _dial;
  final Duration _leaseDuration;
  final Duration _dialTimeout;
  final Duration _headerReadTimeout;
  final Duration _bootstrapTokenTtl;
  final DateTime Function() _clock;
  final void Function(_LoopbackForward) _onExpired;

  final Map<String, DateTime> _bootstrapTokens = {};
  final Set<Socket> _sockets = {};
  final Set<SSHSocket> _channels = {};
  DateTime _expiresAt;
  Timer? _leaseTimer;
  bool _closed = false;

  int get localPort => _serverV4.port;
  bool get isClosed => _closed;
  bool get isExpired => !_clock().isBefore(_expiresAt);

  List<InternetAddress> get addresses => [
    _serverV4.address,
    if (_serverV6 != null) _serverV6.address,
  ];

  void touch() {
    if (_closed) return;
    _expiresAt = _clock().add(_leaseDuration);
    _armLeaseTimer();
  }

  void _armLeaseTimer() {
    _leaseTimer?.cancel();
    if (_closed) return;
    _leaseTimer = Timer(_leaseDuration, () {
      if (!_closed) _onExpired(this);
    });
  }

  String mintBootstrapToken() {
    final now = _clock();
    _bootstrapTokens.removeWhere((_, expiry) => !now.isBefore(expiry));
    while (_bootstrapTokens.length >= _maxBootstrapTokens) {
      _bootstrapTokens.remove(_bootstrapTokens.keys.first);
    }
    final token = _randomHex(32);
    _bootstrapTokens[token] = now.add(_bootstrapTokenTtl);
    return token;
  }

  bool _consumeBootstrapToken(String candidate) {
    final now = _clock();
    _bootstrapTokens.removeWhere((_, expiry) => !now.isBefore(expiry));
    String? matched;
    for (final token in _bootstrapTokens.keys) {
      if (_constantTimeEquals(candidate, token)) {
        matched = token;
      }
    }
    if (matched == null) return false;
    _bootstrapTokens.remove(matched);
    return true;
  }

  Future<void> _accept(Socket socket) async {
    if (_closed || isExpired) {
      socket.destroy();
      return;
    }
    _sockets.add(socket);
    socket.done.ignore();

    var ended = false;
    SSHSocket? channel;
    _StreamHeadSplitter? clientSplitter;
    _StreamHeadSplitter? upstreamSplitter;

    void end() {
      if (ended) return;
      ended = true;
      _sockets.remove(socket);
      if (channel != null) {
        _channels.remove(channel);
        channel.destroy();
      }
      clientSplitter?.cancel();
      upstreamSplitter?.cancel();
      socket.close().ignore();
    }

    clientSplitter = _StreamHeadSplitter(
      socket,
      maxHeaderBytes: _maxHeaderBytes,
      onError: end,
      onDone: () {
        if (!ended && channel != null) {
          channel.sink.close().ignore();
        }
      },
    );

    final Uint8List? rawReqHead;
    try {
      rawReqHead = await clientSplitter.readHead(_headerReadTimeout);
    } on _HeaderTooLargeException {
      _writeSimpleResponse(socket, '431 Request Header Fields Too Large', end);
      return;
    } catch (_) {
      end();
      return;
    }
    if (rawReqHead == null || ended || _closed || isExpired) {
      end();
      return;
    }

    final parsed = _parseHttpRequestHead(rawReqHead);
    if (parsed == null) {
      _writeSimpleResponse(socket, '400 Bad Request', end);
      return;
    }

    final expectedHost = '$localHost:$localPort';
    if (parsed.hosts.length != 1 ||
        parsed.hosts.single.toLowerCase() != expectedHost) {
      _writeSimpleResponse(socket, '403 Forbidden', end);
      return;
    }

    if (parsed.secFetchSite != null &&
        parsed.secFetchSite!.toLowerCase() == 'cross-site') {
      _writeSimpleResponse(socket, '403 Forbidden', end);
      return;
    }

    final expectedOrigin = 'http://$expectedHost';
    if (parsed.origin != null &&
        parsed.origin!.toLowerCase() != expectedOrigin) {
      _writeSimpleResponse(socket, '403 Forbidden', end);
      return;
    }

    final hasCookieAuth = _hasValidSessionCookie(parsed.cookieHeaders);
    final hasBootstrapAuth =
        parsed.bootstrapHeader != null &&
        _consumeBootstrapToken(parsed.bootstrapHeader!);
    if (!hasCookieAuth && !hasBootstrapAuth) {
      _writeSimpleResponse(socket, '403 Forbidden', end);
      return;
    }

    touch();

    try {
      channel = await _dialUpstream();
    } catch (error) {
      debugPrint('[browser] loopback forward failed (${error.runtimeType})');
      // Drain any unread bytes and send FIN so the page receives a clean empty
      // response instead of a TCP reset.
      clientSplitter.pipeRemainder((_) {});
      socket.close().then<void>((_) => end(), onError: (Object _) => end());
      return;
    }

    if (_closed || ended) {
      channel.destroy();
      end();
      return;
    }
    _channels.add(channel);
    channel.done.ignore();

    final isWebSocket =
        _headerHasToken(parsed.connectionHeaders, 'upgrade') &&
        parsed.upgradeHeader?.toLowerCase() == 'websocket';

    final upstreamRequest = _buildUpstreamRequest(
      parsed,
      isWebSocket: isWebSocket,
    );
    channel.sink.add(upstreamRequest);
    clientSplitter.pipeRemainder((chunk) {
      if (!ended) channel!.sink.add(chunk);
    });

    upstreamSplitter = _StreamHeadSplitter(
      channel.stream,
      maxHeaderBytes: _maxHeaderBytes,
      onError: end,
      onDone: end,
    );

    try {
      while (!ended && !_closed) {
        final rawRespHead = await upstreamSplitter.readHead(_headerReadTimeout);
        if (rawRespHead == null || ended || _closed) {
          end();
          return;
        }
        final resp = _parseHttpResponseHead(rawRespHead);
        if (resp == null) {
          end();
          return;
        }
        if (resp.statusCode >= 100 &&
            resp.statusCode < 200 &&
            resp.statusCode != 101) {
          socket.add(rawRespHead);
          socket.add(_crlfCrlf);
          continue;
        }
        final keepUpgrade = isWebSocket && resp.statusCode == 101;
        final rewrittenResp = _buildDownstreamResponse(
          resp,
          keepUpgrade: keepUpgrade,
          setAuthCookie: hasBootstrapAuth,
        );
        socket.add(rewrittenResp);
        upstreamSplitter.pipeRemainder((chunk) {
          if (!ended) socket.add(chunk);
        });
        return;
      }
    } catch (_) {
      end();
    }
  }

  Future<SSHSocket> _dialUpstream() async {
    Object? lastError;
    final hosts = target.dialHosts;
    for (var i = 0; i < hosts.length; i++) {
      if (_closed) throw StateError('Forward is closed');
      try {
        return await _dial(hosts[i], target.port).timeout(_dialTimeout);
      } on TimeoutException {
        rethrow;
      } catch (error) {
        lastError = error;
        if (i + 1 >= hosts.length || _closed) rethrow;
      }
    }
    throw lastError ?? const SocketException('Could not dial loopback');
  }

  bool _hasValidSessionCookie(List<String> cookieHeaders) {
    for (final header in cookieHeaders) {
      for (final part in header.split(';')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        final name = part.substring(0, eq).trim();
        if (name != kBrowserForwardCookieName) continue;
        final value = part.substring(eq + 1).trim();
        if (_constantTimeEquals(value, sessionToken)) return true;
      }
    }
    return false;
  }

  Uint8List _buildUpstreamRequest(
    _ParsedRequestHead req, {
    required bool isWebSocket,
  }) {
    final buf = StringBuffer('${req.requestLine}\r\n');
    final hopByHop = _hopByHopNames(req.connectionHeaders);
    final localOrigin = 'http://$localHost:$localPort';
    final remoteOrigin = 'http://${target.authority}';
    final keptCookies = <String>[];

    buf.write('Host: ${target.authority}\r\n');
    for (final (name, value) in req.headers) {
      final lower = name.toLowerCase();
      if (lower == 'host' || lower == kBrowserForwardAuthHeader) continue;
      if (lower == 'cookie') {
        final stripped = _stripForwardCookie(value);
        if (stripped != null) keptCookies.add(stripped);
        continue;
      }
      if (!isWebSocket &&
          (lower == 'connection' ||
              lower == 'keep-alive' ||
              hopByHop.contains(lower))) {
        continue;
      }
      if (lower == 'origin') {
        buf.write('Origin: $remoteOrigin\r\n');
        continue;
      }
      if (lower == 'referer') {
        final rewritten = _rewriteReferer(value, localOrigin, remoteOrigin);
        buf.write('Referer: $rewritten\r\n');
        continue;
      }
      buf.write('$name: $value\r\n');
    }
    if (keptCookies.isNotEmpty) {
      buf.write('Cookie: ${keptCookies.join('; ')}\r\n');
    }
    if (!isWebSocket) {
      buf.write('Connection: close\r\n');
    }
    buf.write('\r\n');
    return latin1.encode(buf.toString());
  }

  Uint8List _buildDownstreamResponse(
    _ParsedResponseHead resp, {
    required bool keepUpgrade,
    required bool setAuthCookie,
  }) {
    final buf = StringBuffer('${resp.statusLine}\r\n');
    for (final (name, value) in resp.headers) {
      final lower = name.toLowerCase();
      if (!keepUpgrade && (lower == 'connection' || lower == 'keep-alive')) {
        continue;
      }
      if (lower == 'set-cookie') {
        buf.write('Set-Cookie: ${_sanitizeSetCookie(value)}\r\n');
        continue;
      }
      if (lower == 'location') {
        buf.write('Location: ${_rewriteLocation(value)}\r\n');
        continue;
      }
      buf.write('$name: $value\r\n');
    }
    if (setAuthCookie) {
      buf.write(
        'Set-Cookie: $kBrowserForwardCookieName=$sessionToken; '
        'Path=/; HttpOnly; SameSite=Strict\r\n',
      );
    }
    if (!keepUpgrade) {
      buf.write('Connection: close\r\n');
    }
    buf.write('\r\n');
    return latin1.encode(buf.toString());
  }

  String _rewriteReferer(
    String value,
    String localOrigin,
    String remoteOrigin,
  ) {
    final trimmed = value.trim();
    if (trimmed.toLowerCase().startsWith(localOrigin)) {
      return '$remoteOrigin${trimmed.substring(localOrigin.length)}';
    }
    return value;
  }

  String _rewriteLocation(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme) return value;
    final locTarget = browserLoopbackTarget(uri);
    if (locTarget == null ||
        locTarget.isHttps ||
        locTarget.originKey != target.originKey) {
      return value;
    }
    return uri.replace(host: localHost, port: localPort).toString();
  }

  static String _sanitizeSetCookie(String value) {
    final parts = value.split(';');
    if (parts.length <= 1) return value;
    final kept = <String>[parts.first.trim()];
    for (var i = 1; i < parts.length; i++) {
      final attr = parts[i].trim();
      if (attr.isEmpty) continue;
      final eq = attr.indexOf('=');
      final attrName = (eq < 0 ? attr : attr.substring(0, eq))
          .trim()
          .toLowerCase();
      // Strip Domain attributes so cookies remain strictly host-only on this
      // forward's unique `h<hex>.localhost` label.
      if (attrName == 'domain') continue;
      kept.add(attr);
    }
    return kept.join('; ');
  }

  static String? _stripForwardCookie(String header) {
    final kept = <String>[];
    for (final part in header.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final eq = trimmed.indexOf('=');
      if (eq > 0 &&
          trimmed.substring(0, eq).trim() == kBrowserForwardCookieName) {
        continue;
      }
      kept.add(trimmed);
    }
    return kept.isEmpty ? null : kept.join('; ');
  }

  void _writeSimpleResponse(
    Socket socket,
    String status,
    void Function() onDone,
  ) {
    try {
      socket.add(
        latin1.encode(
          'HTTP/1.1 $status\r\n'
          'Content-Length: 0\r\n'
          'Connection: close\r\n\r\n',
        ),
      );
    } catch (_) {
      // Peer already closed.
    }
    onDone();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _bootstrapTokens.clear();
    await _serverV4.close();
    await _serverV6?.close();
    for (final socket in [..._sockets]) {
      socket.destroy();
    }
    for (final channel in [..._channels]) {
      channel.destroy();
    }
    _sockets.clear();
    _channels.clear();
  }
}

final Uint8List _crlfCrlf = Uint8List.fromList(const [13, 10, 13, 10]);

class _HeaderTooLargeException implements Exception {
  const _HeaderTooLargeException();
}

/// Reads `\r\n\r\n`-delimited HTTP heads from a single-subscription byte
/// stream, then hands the remainder directly to [pipeRemainder] without
/// buffering the body.
class _StreamHeadSplitter {
  _StreamHeadSplitter(
    Stream<Uint8List> stream, {
    required this._maxHeaderBytes,
    required this._onError,
    required this._onDone,
  }) {
    _sub = stream.listen(
      _onData,
      onError: (Object _) => _handleError(),
      onDone: _handleDone,
      cancelOnError: true,
    );
  }

  final int _maxHeaderBytes;
  final void Function() _onError;
  final void Function() _onDone;

  late final StreamSubscription<Uint8List> _sub;
  final List<int> _buffer = [];
  Completer<Uint8List?>? _headCompleter;
  void Function(Uint8List)? _sink;
  bool _done = false;
  bool _failed = false;

  Future<Uint8List?> readHead(Duration timeout) {
    final existing = _tryTakeHead();
    if (existing != null) return Future<Uint8List?>.value(existing);
    if (_failed) return Future<Uint8List?>.value(null);
    if (_done) return Future<Uint8List?>.value(null);

    final completer = Completer<Uint8List?>();
    _headCompleter = completer;
    if (_sub.isPaused) _sub.resume();
    return completer.future.timeout(timeout);
  }

  void pipeRemainder(void Function(Uint8List) sink) {
    _sink = sink;
    if (_buffer.isNotEmpty) {
      final leftover = Uint8List.fromList(_buffer);
      _buffer.clear();
      sink(leftover);
    }
    if (_sub.isPaused) _sub.resume();
    if (_done) _onDone();
  }

  /// Body bytes kept while nobody reads them (the SSH channel still
  /// opening) before the sender is held back.
  static const int _heldBodyBytes = 64 * 1024;

  void cancel() {
    _done = true;
    final pending = _headCompleter;
    _headCompleter = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(null);
    }
    unawaited(_sub.cancel());
  }

  void _onData(Uint8List chunk) {
    final sink = _sink;
    if (sink != null) {
      sink(chunk);
      return;
    }
    _buffer.addAll(chunk);
    final waiting = _headCompleter;
    if (waiting == null || waiting.isCompleted) {
      // The head was already read and its body has nowhere to go yet (the
      // SSH channel is still opening). These bytes are the BODY: they are
      // kept as they came. Looking for the next «\r\n\r\n» in them took a
      // multipart upload's own blank lines for a head and threw away what
      // came before, and a body past the head limit ended the request.
      if (_buffer.length >= _heldBodyBytes && !_sub.isPaused) _sub.pause();
      return;
    }
    final head = _tryTakeHead();
    if (head != null) {
      final pending = _headCompleter;
      _headCompleter = null;
      if (pending != null && !pending.isCompleted) {
        pending.complete(head);
      }
      return;
    }
    if (_buffer.length > _maxHeaderBytes) {
      _failed = true;
      final pending = _headCompleter;
      _headCompleter = null;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(const _HeaderTooLargeException());
      }
      unawaited(_sub.cancel());
    }
  }

  Uint8List? _tryTakeHead() {
    for (var i = 0; i <= _buffer.length - 4; i++) {
      if (_buffer[i] == 13 &&
          _buffer[i + 1] == 10 &&
          _buffer[i + 2] == 13 &&
          _buffer[i + 3] == 10) {
        final head = Uint8List.fromList(_buffer.sublist(0, i));
        _buffer.removeRange(0, i + 4);
        return head;
      }
    }
    return null;
  }

  void _handleError() {
    _failed = true;
    final pending = _headCompleter;
    _headCompleter = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(null);
    }
    _onError();
  }

  void _handleDone() {
    _done = true;
    final pending = _headCompleter;
    _headCompleter = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(null);
    }
    if (_sink != null) _onDone();
  }
}

class _ParsedRequestHead {
  const _ParsedRequestHead({
    required this.requestLine,
    required this.headers,
    required this.hosts,
    required this.cookieHeaders,
    required this.connectionHeaders,
    this.bootstrapHeader,
    this.origin,
    this.secFetchSite,
    this.upgradeHeader,
  });

  final String requestLine;
  final List<(String, String)> headers;
  final List<String> hosts;
  final List<String> cookieHeaders;
  final List<String> connectionHeaders;
  final String? bootstrapHeader;
  final String? origin;
  final String? secFetchSite;
  final String? upgradeHeader;
}

class _ParsedResponseHead {
  const _ParsedResponseHead({
    required this.statusLine,
    required this.statusCode,
    required this.headers,
  });

  final String statusLine;
  final int statusCode;
  final List<(String, String)> headers;
}

final RegExp _requestLinePattern = RegExp(
  r'^[A-Z]+ [^\r\n ]+ HTTP/1\.[01]$',
);

final RegExp _responseLinePattern = RegExp(
  r'^HTTP/1\.[01] (\d{3})(?: .*)?$',
);

_ParsedRequestHead? _parseHttpRequestHead(Uint8List raw) {
  final text = latin1.decode(raw);
  final lines = text.split('\r\n');
  if (lines.isEmpty) return null;
  final requestLine = lines.first;
  if (!_requestLinePattern.hasMatch(requestLine)) return null;

  final headers = <(String, String)>[];
  final hosts = <String>[];
  final cookies = <String>[];
  final connections = <String>[];
  String? bootstrap;
  String? origin;
  String? secFetchSite;
  String? upgrade;

  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    final colon = line.indexOf(':');
    if (colon <= 0) return null;
    final name = line.substring(0, colon).trim();
    if (name.isEmpty) return null;
    final value = line.substring(colon + 1).trim();
    headers.add((name, value));
    switch (name.toLowerCase()) {
      case 'host':
        hosts.add(value);
      case 'cookie':
        cookies.add(value);
      case 'connection':
        connections.add(value);
      case kBrowserForwardAuthHeader:
        bootstrap = value;
      case 'origin':
        origin = value;
      case 'sec-fetch-site':
        secFetchSite = value;
      case 'upgrade':
        upgrade = value;
    }
  }
  return _ParsedRequestHead(
    requestLine: requestLine,
    headers: headers,
    hosts: hosts,
    cookieHeaders: cookies,
    connectionHeaders: connections,
    bootstrapHeader: bootstrap,
    origin: origin,
    secFetchSite: secFetchSite,
    upgradeHeader: upgrade,
  );
}

_ParsedResponseHead? _parseHttpResponseHead(Uint8List raw) {
  final text = latin1.decode(raw);
  final lines = text.split('\r\n');
  if (lines.isEmpty) return null;
  final statusLine = lines.first;
  final match = _responseLinePattern.firstMatch(statusLine);
  if (match == null) return null;
  final statusCode = int.parse(match.group(1)!);
  final headers = <(String, String)>[];
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final name = line.substring(0, colon).trim();
    if (name.isEmpty) continue;
    headers.add((name, line.substring(colon + 1).trim()));
  }
  return _ParsedResponseHead(
    statusLine: statusLine,
    statusCode: statusCode,
    headers: headers,
  );
}

bool _headerHasToken(List<String> values, String token) {
  final wanted = token.toLowerCase();
  for (final value in values) {
    for (final part in value.split(',')) {
      if (part.trim().toLowerCase() == wanted) return true;
    }
  }
  return false;
}

Set<String> _hopByHopNames(List<String> connectionHeaders) {
  final names = <String>{};
  for (final header in connectionHeaders) {
    for (final part in header.split(',')) {
      final name = part.trim().toLowerCase();
      if (name.isNotEmpty) names.add(name);
    }
  }
  return names;
}

bool _constantTimeEquals(String a, String b) {
  final aBytes = utf8.encode(a);
  final bBytes = utf8.encode(b);
  if (aBytes.length != bBytes.length) return false;
  var diff = 0;
  for (var i = 0; i < aBytes.length; i++) {
    diff |= aBytes[i] ^ bBytes[i];
  }
  return diff == 0;
}
