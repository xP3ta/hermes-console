import 'bridge_client.dart';

/// Provisions a Mobile Bridge token from the gateway API key.
typedef BridgeTokenProvisioner =
    Future<String?> Function(String bridgeUrl, String gatewayKey);

/// In-memory, per-connection cache of the token returned by
/// `POST /bridge/provision`.
///
/// Before this cache every model-picker open and every generated-image load
/// asked the bridge for a fresh token, which flooded its audit log. Tokens
/// live only in memory, are keyed by connection id, bridge URL and gateway
/// key (editing any of them misses the cache), expire after [ttl], and are
/// dropped when the bridge answers 401. Concurrent callers share one request.
/// A failed provision is remembered for [failureBackoff] so hosts without a
/// bridge are not probed on every open.
class BridgeTokenCache {
  BridgeTokenCache({
    BridgeTokenProvisioner? provision,
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 30),
  }) : _provision = provision ?? BridgeClient.provision,
       _now = now ?? DateTime.now;

  /// Shared cache for the app.
  static final BridgeTokenCache instance = BridgeTokenCache();

  static const Duration failureBackoff = Duration(seconds: 30);

  final BridgeTokenProvisioner _provision;
  final DateTime Function() _now;
  final Duration ttl;

  final Map<String, _Entry> _entries = {};
  final Map<String, Future<String?>> _inFlight = {};

  /// Returns a bridge token for the connection, or null when the bridge is
  /// not configured, unreachable or refuses the gateway key.
  Future<String?> token({
    required String connectionId,
    required String bridgeUrl,
    required String gatewayKey,
  }) {
    final url = bridgeUrl.trim();
    final key = gatewayKey.trim();
    if (url.isEmpty || key.isEmpty) return Future.value(null);
    final entry = _entries[connectionId];
    final now = _now();
    if (entry != null && entry.url == url && entry.key == key) {
      if (now.isBefore(entry.expiresAt)) return Future.value(entry.token);
    }
    final flightKey = '$connectionId\u0000$url\u0000$key';
    final pending = _inFlight[flightKey];
    if (pending != null) return pending;
    final future = () async {
      String? token;
      try {
        token = await _provision(url, key);
      } catch (_) {
        token = null;
      }
      final at = _now();
      final ok = token != null && token.isNotEmpty;
      _entries[connectionId] = _Entry(
        url: url,
        key: key,
        token: ok ? token : null,
        expiresAt: at.add(ok ? ttl : failureBackoff),
      );
      return ok ? token : null;
    }();
    _inFlight[flightKey] = future;
    return future.whenComplete(() {
      if (identical(_inFlight[flightKey], future)) _inFlight.remove(flightKey);
    });
  }

  /// Drops the cached token of [connectionId]. With [staleToken], only drops
  /// it when it is still that token (a concurrent caller may have refreshed).
  void invalidate(String connectionId, {String? staleToken}) {
    final entry = _entries[connectionId];
    if (entry == null) return;
    if (staleToken != null && entry.token != staleToken) return;
    _entries.remove(connectionId);
  }

  /// Runs [run] with a cached token. When the bridge answers 401 the token is
  /// invalidated and [run] is retried once with a freshly provisioned one.
  /// Returns null (without running) when no token can be obtained.
  Future<T?> withToken<T>({
    required String connectionId,
    required String bridgeUrl,
    required String gatewayKey,
    required Future<T> Function(String token) run,
  }) async {
    final first = await token(
      connectionId: connectionId,
      bridgeUrl: bridgeUrl,
      gatewayKey: gatewayKey,
    );
    if (first == null) return null;
    try {
      return await run(first);
    } on BridgeException catch (error) {
      if (error.status != 401) rethrow;
      invalidate(connectionId, staleToken: first);
      final fresh = await token(
        connectionId: connectionId,
        bridgeUrl: bridgeUrl,
        gatewayKey: gatewayKey,
      );
      if (fresh == null) rethrow;
      return run(fresh);
    }
  }
}

class _Entry {
  const _Entry({
    required this.url,
    required this.key,
    required this.token,
    required this.expiresAt,
  });
  final String url;
  final String key;
  final String? token;
  final DateTime expiresAt;
}
