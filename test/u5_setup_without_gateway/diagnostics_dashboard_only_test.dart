import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/desktop_chat_socket.dart';

// Desktop: `/api/health`, then `/api/status` (remote-liveness.ts:116-127);
// version from `/api/health` (status.py:116-127). The Gateway port refuses.
final _connection = SavedConnection(
  id: 'u5',
  label: 'Home',
  host: 'localhost',
  port: 9131,
  apiKey: '',
  dashboardAuthMode: AuthMode.sessionToken,
  dashboardUrl: 'http://localhost:19119',
);

HostCounter _server({int health = 200, int sessions = 200, bool up = true}) =>
    HostCounter(
      handler: (r) async {
        if (!up || r.url.port != 19119) throw StateError('refused');
        final (body, code) = switch (r.url.path) {
          '/api/health' => ({'version': '0.22.0'}, health),
          '/api/status' => ({'version': '0.22.1'}, 200),
          '/api/sessions' => ({'sessions': []}, sessions),
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

void main() {
  test('run() reads the whole matrix from the Dashboard alone', () async {
    final hosts = _server();
    final m = (await _run(hosts)).matrix;
    expect([
      m.dashboardOnline,
      m.dashboardAuthValid,
      m.sessionsRead,
      m.skillsRead,
      m.toolsetsRead,
    ], everyElement(CapState.yes));
    expect(m.gatewayVersion, '0.22.0');
    expect(hosts.byHost.keys, ['localhost:19119'], reason: '${hosts.requests}');
    expect(m.serverSourced, isEmpty);
    expect([
      m.gatewayOnline,
      m.gatewayAuthValid,
      m.chatSupported,
      m.pluginsSupported,
    ], everyElement(CapState.unknown));
  });

  test('failures are told apart: fallback, offline and login needed', () async {
    var m = (await _run(_server(health: 404))).matrix;
    expect((m.dashboardOnline, m.gatewayVersion), (CapState.yes, '0.22.1'));
    m = (await _run(_server(up: false))).matrix;
    expect((m.dashboardOnline, m.gatewayVersion), (CapState.no, null));
    final report = await _run(_server(sessions: 401));
    final sessions = report.dashboard.firstWhere((p) => p.name == 'sessions');
    expect(sessions.status, ProbeStatus.authInvalid);
    expect(report.matrix.dashboardOnline, CapState.yes);
    expect(report.matrix.sessionsRead, isNot(CapState.yes));
  });

  test('Kanban tracked create holds with the Gateway dead', () async {
    SharedPreferences.setMockInitialValues({});
    final report = await _run(_server());
    (await SharedPreferences.getInstance()).setString(
      'capabilities_u5',
      jsonEncode(report.matrix.toJson()),
    );
    expect(
      await ConnectionManager.isKanbanTrackedCreateSupported('u5'),
      isTrue,
    );
  });
}
