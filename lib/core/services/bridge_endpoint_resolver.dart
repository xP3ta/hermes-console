import '../models/connection.dart';

class BridgeEndpoint {
  final String url;
  final bool derived;

  const BridgeEndpoint({required this.url, required this.derived});
}

/// Canonical bridge endpoint policy shared by probing, updates and installer
/// verification. HTTPS reverse proxies keep the external origin and base path;
/// direct HTTP/local connections retain the dedicated port 9131.
abstract final class BridgeEndpointResolver {
  static BridgeEndpoint resolve(
    SavedConnection connection, {
    String? savedUrl,
  }) {
    final override = savedUrl?.trim() ?? '';
    if (override.isNotEmpty) {
      return BridgeEndpoint(
        url: _withoutTrailingSlash(override),
        derived: false,
      );
    }

    final dashboard = Uri.tryParse(connection.effectiveDashboardUrl);
    if (dashboard != null &&
        dashboard.scheme.toLowerCase() == 'https' &&
        dashboard.host.isNotEmpty) {
      return BridgeEndpoint(
        url: _withoutTrailingSlash(dashboard.toString()),
        derived: true,
      );
    }

    return BridgeEndpoint(
      url: _withoutTrailingSlash(connection.derivedBridgeUrl),
      derived: true,
    );
  }

  static String _withoutTrailingSlash(String value) {
    var result = value;
    while (result.endsWith('/') && result.length > 1) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}
