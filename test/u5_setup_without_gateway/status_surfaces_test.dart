import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/gateway_manager_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:http/http.dart' as http;

import '../support/desktop_chat_socket.dart';
import '../support/onboarding_fakes.dart';

// Like Desktop, the manager and the panel read only the Dashboard.
final _connection = SavedConnection(
  id: 'u5',
  label: 'Home',
  host: 'localhost',
  port: 8642,
  apiKey: '',
  dashboardAuthMode: AuthMode.sessionToken,
  dashboardUrl: 'http://localhost:9119',
);

HostCounter _dashboard({int sessions = 200}) => HostCounter(
  handler: (r) async {
    if (r.url.port != 9119) throw StateError('connection refused');
    return r.url.path == '/api/sessions'
        ? http.Response('{"sessions":[]}', sessions)
        : http.Response('{"status":"ok"}', 200);
  },
);

Future<void> _pumpManager(WidgetTester tester, HostCounter hosts) async {
  final manager = await onboardingManager();
  await manager.upsertConnection(_connection);
  await manager.setDashboardSecrets('u5', sessionToken: 'synthetic-session');
  await http.runWithClient(() async {
    await tester.pumpWidget(
      onboardingHost(
        GatewayManagerScreen(connManager: manager),
        language: 'en',
      ),
    );
    await tester.pump(const Duration(seconds: 1));
  }, () => hosts);
  expect(hosts.byHost['localhost:8642'], isNull, reason: hosts.requests.join());
}

void main() {
  testWidgets(
    'the status panel has no Gateway row and never asks the Gateway',
    (tester) async {
      final hosts = _dashboard();
      await http.runWithClient(() async {
        await tester.pumpWidget(
          onboardingHost(
            InstanceStatusPanel(
              connection: _connection,
              dashboardAuth: (_) async => DashboardAuthCheck.ok,
            ),
            language: 'en',
          ),
        );
        await tester.pumpAndSettle();
      }, () => hosts);
      expect(find.text('Gateway'), findsNothing);
      expect(hosts.byHost.keys, [
        'localhost:9119',
      ], reason: hosts.requests.join());
    },
  );

  for (final (sessions, expected) in [
    (200, 'Chat connected'),
    (401, 'login required'),
  ]) {
    testWidgets('the manager reads the Dashboard: sessions $sessions', (
      tester,
    ) async {
      await _pumpManager(tester, _dashboard(sessions: sessions));
      expect(find.textContaining(expected), findsWidgets);
      expect(find.textContaining('offline'), findsNothing);
    });
  }
}
