// The launch order of doctor and the audit is per server endpoint and
// profile, not per saved connection: two saved connections that reach the same
// Dashboard share it.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/server_diagnostics_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

SavedConnection _conn(
  String id, {
  String host = 'hermes.example.test',
  int port = 8642,
  String? dashboardUrl = 'http://hermes.example.test:9119',
  String apiKey = '',
  String label = 'x',
}) => SavedConnection(
  id: id,
  label: label,
  host: host,
  port: port,
  apiKey: apiKey,
  dashboardUrl: dashboardUrl,
);

void main() {
  test('two saved connections to the same Dashboard share a scope', () {
    expect(
      diagnosticsLaunchScope(_conn('conn-a', label: 'A'), 'work'),
      diagnosticsLaunchScope(
        _conn('conn-b', label: 'B', apiKey: 'another-key'),
        'work',
      ),
    );
  });

  test('host case and a trailing slash do not matter', () {
    expect(
      diagnosticsLaunchScope(_conn('a'), ''),
      diagnosticsLaunchScope(
        _conn('b', dashboardUrl: 'http://HERMES.example.test:9119/'),
        '',
      ),
    );
  });

  test('a default port written or not is the same endpoint', () {
    expect(
      diagnosticsLaunchScope(
        _conn('a', dashboardUrl: 'https://hermes.example.test'),
        '',
      ),
      diagnosticsLaunchScope(
        _conn('b', dashboardUrl: 'https://hermes.example.test:443'),
        '',
      ),
    );
  });

  test('another host, port, scheme or profile is another scope', () {
    final base = diagnosticsLaunchScope(_conn('a'), 'work');
    for (final other in [
      diagnosticsLaunchScope(
        _conn('a', dashboardUrl: 'http://other.example.test:9119'),
        'work',
      ),
      diagnosticsLaunchScope(
        _conn('a', dashboardUrl: 'http://hermes.example.test:9120'),
        'work',
      ),
      diagnosticsLaunchScope(
        _conn('a', dashboardUrl: 'https://hermes.example.test:9119'),
        'work',
      ),
      diagnosticsLaunchScope(_conn('a'), 'other'),
      diagnosticsLaunchScope(_conn('a'), ''),
    ]) {
      expect(other, isNot(base));
    }
  });

  test('the default profile is the same however it is written', () {
    expect(
      diagnosticsLaunchScope(_conn('a'), ''),
      diagnosticsLaunchScope(_conn('a'), 'default'),
    );
  });

  test('credentials and query parts of the URL never reach the scope', () {
    final scope = diagnosticsLaunchScope(
      _conn(
        'a',
        dashboardUrl:
            'http://user:pa55word@hermes.example.test:9119/?token=sekrit#frag',
      ),
      'work',
    );
    expect(scope, isNot(contains('pa55word')));
    expect(scope, isNot(contains('sekrit')));
    expect(scope, isNot(contains('user')));
    expect(scope, contains('hermes.example.test'));
  });

  test('without a Dashboard URL the gateway host stands in', () {
    expect(
      diagnosticsLaunchScope(_conn('a', dashboardUrl: null), ''),
      diagnosticsLaunchScope(_conn('b', dashboardUrl: null), ''),
    );
    expect(
      diagnosticsLaunchScope(_conn('a', dashboardUrl: null), ''),
      isNot(
        diagnosticsLaunchScope(
          _conn('a', dashboardUrl: null, host: 'other.example.test'),
          '',
        ),
      ),
    );
  });
}
