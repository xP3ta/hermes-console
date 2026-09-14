import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/bridge_endpoint_resolver.dart';

void main() {
  group('BridgeEndpointResolver', () {
    test('saved override always wins including custom path and port', () {
      final resolved = BridgeEndpointResolver.resolve(
        _connection(useHttps: true, dashboardUrl: 'https://dash.example/root'),
        savedUrl: 'https://bridge.example:9443/custom/',
      );
      expect(resolved.url, 'https://bridge.example:9443/custom');
      expect(resolved.derived, isFalse);
    });

    test('HTTPS without override uses external dashboard origin and path', () {
      final resolved = BridgeEndpointResolver.resolve(
        _connection(
          useHttps: true,
          dashboardUrl: 'https://console.example:8443/hermes/',
        ),
      );
      expect(resolved.url, 'https://console.example:8443/hermes');
      expect(resolved.derived, isTrue);
      expect(Uri.parse(resolved.url).port, 8443);
    });

    test('HTTPS gateway without dashboard override keeps gateway port', () {
      final resolved = BridgeEndpointResolver.resolve(
        _connection(useHttps: true, port: 7443),
      );
      expect(resolved.url, 'https://example.com:7443');
    });

    test('plain HTTP retains dedicated 9131 endpoint', () {
      final resolved = BridgeEndpointResolver.resolve(_connection());
      expect(resolved.url, 'http://example.com:9131');
    });

    test('IPv6 HTTP derivation is bracketed and parseable', () {
      final resolved = BridgeEndpointResolver.resolve(
        _connection(host: '2001:db8::7'),
      );
      final uri = Uri.parse(resolved.url);
      expect(uri.host, '2001:db8::7');
      expect(uri.port, 9131);
      expect(resolved.url, 'http://[2001:db8::7]:9131');
    });
  });
}

SavedConnection _connection({
  String host = 'example.com',
  int port = 8642,
  bool useHttps = false,
  String? dashboardUrl,
}) => SavedConnection(
  id: 'c1',
  label: 'Test',
  host: host,
  port: port,
  useHttps: useHttps,
  dashboardUrl: dashboardUrl,
  apiKey: 'key',
);
