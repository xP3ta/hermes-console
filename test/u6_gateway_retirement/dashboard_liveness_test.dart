import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;

import '../support/desktop_chat_socket.dart';

// Desktop: `/api/health` decides liveness and `/api/status` stands in only when
// the first is missing (electron/remote-liveness.ts:116-127,
// backend-health.ts:182-185).
final _connection = SavedConnection(
  id: 'u6',
  label: 'Home',
  host: 'localhost',
  port: 9131,
  apiKey: 'synthetic-key',
  dashboardAuthMode: AuthMode.sessionToken,
  dashboardUrl: 'http://localhost:19119',
);

HostCounter _server(int health) => HostCounter(
  handler: (r) async {
    if (r.url.port != 19119) throw StateError('refused');
    final (body, code) = switch (r.url.path) {
      '/api/health' => ({'version': '0.22.0'}, health),
      '/api/status' => ({'version': '0.22.1'}, 200),
      _ => (<String, Object>{}, 200),
    };
    return http.Response(jsonEncode(body), code);
  },
);

Future<DiagnosticsReport> _run(HostCounter hosts) async {
  final diagnostics = ConnectionDiagnostics(httpClient: hosts);
  addTearDown(diagnostics.close);
  return diagnostics.run(
    await Strings.delegate.load(const Locale('en')),
    _connection,
    const DashboardSecrets(sessionToken: 'synthetic-session'),
  );
}

bool _askedStatus(HostCounter hosts) =>
    hosts.requests.any((r) => r.endsWith(' /api/status'));

void main() {
  test(
    'a 500 from /api/health is not alive and never asks /api/status',
    () async {
      final hosts = _server(500);
      final m = (await _run(hosts)).matrix;
      expect(m.dashboardOnline, CapState.no, reason: '${hosts.requests}');
      expect(_askedStatus(hosts), isFalse, reason: '${hosts.requests}');
      expect(m.gatewayVersion, isNull);
    },
  );

  test('a 404 from /api/health falls back to /api/status', () async {
    final hosts = _server(404);
    final m = (await _run(hosts)).matrix;
    expect(m.dashboardOnline, CapState.yes);
    expect(m.gatewayVersion, '0.22.1');
    expect(_askedStatus(hosts), isTrue);
  });

  test('a healthy /api/health is the only liveness request', () async {
    final hosts = _server(200);
    final m = (await _run(hosts)).matrix;
    expect((m.dashboardOnline, m.gatewayVersion), (CapState.yes, '0.22.0'));
    expect(_askedStatus(hosts), isFalse);
    expect(hosts.byHost.keys, ['localhost:19119']);
  });
}
