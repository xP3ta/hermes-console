import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/gateway_manager_screen.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:http/http.dart' as http;

import '../support/connection_editor_actions.dart';
import '../support/desktop_chat_socket.dart';
import '../support/onboarding_fakes.dart';

// A Dashboard that asks for the login and accepts the synthetic owner.
HostCounter _dashboard() => HostCounter(
  handler: (r) async {
    const bodies = {
      '/api/status': '{"auth_required":true}',
      '/api/auth/providers':
          '{"providers":[{"name":"basic","supports_password":true}]}',
      '/api/auth/me': '{"username":"synthetic-owner"}',
      '/api/sessions': '{"sessions":[]}',
    };
    return http.Response(
      bodies[r.url.path] ?? '{}',
      200,
      headers: r.url.path == '/auth/password-login'
          ? {'set-cookie': 'hermes_session_at=synthetic; Path=/'}
          : {},
    );
  },
);

Widget _onboarding(ConnectionManager m, HostCounter hosts, [PairingLink? l]) =>
    onboardingHost(
      OnboardingScreen(
        connManager: m,
        onDone: () {},
        diagnostics: ConnectionDiagnostics(httpClient: hosts),
        initialLink: l,
      ),
    );
void main() {
  const keyOnly = PairingLink(
    host: 'fixture.invalid',
    port: 8642,
    token: 'synthetic-chat-key',
    useHttps: true,
    dashboardUrl: 'https://fixture.invalid:9119',
  );

  for (final (name, link) in [
    ('a full code connects with the three rows', fakeFullPairing),
    ('a code with only the Gateway key asks to sign in', keyOnly),
  ]) {
    testWidgets('$name and never calls the Gateway', (tester) async {
      final hosts = _dashboard();
      await http.runWithClient(() async {
        await tester.pumpWidget(
          _onboarding(await onboardingManager(), hosts, link),
        );
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'onboarding-confirm');
      }, () => hosts);
      final s = onboardingStrings(tester);
      final full = link == fakeFullPairing;
      expect(find.text(s.o2SuccessTitle), full ? findsOneWidget : findsNothing);
      expect(find.text(s.o2MissingStep), full ? findsNothing : findsOneWidget);
      expect(find.text(s.o2Unreachable), findsNothing);
      expect(hosts.byHost.keys, ['fixture.invalid:9119']);
    });
  }

  testWidgets('a new connection needs only an address and the login', (
    tester,
  ) async {
    final manager = await onboardingManager();
    final hosts = _dashboard();
    await http.runWithClient(() async {
      // The editor itself (Settings opens it; onboarding's manual door is
      // now the simple form).
      await tester.pumpWidget(
        onboardingHost(
          InstanceEditScreen(
            connManager: manager,
            verifyChatBeforeSave: true,
            diagnostics: ConnectionDiagnostics(httpClient: hosts),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final url = find.byKey(const ValueKey('instance-gateway-url'));
      await revealEditorControl(tester, url);
      await tester.enterText(url, 'https://fixture.invalid');
      await tapOnboarding(tester, 'instance-dashboard-sign-in');
      final fields = find.descendant(
        of: find.byType(DashboardSetupScreen),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), 'synthetic-owner');
      await tester.enterText(fields.at(1), 'synthetic-password');
      await tapOnboarding(tester, 'dashboard-login-submit');
      await tapOnboarding(tester, 'instance-save');
    }, () => hosts);
    expect(manager.getConnections().single.apiKey, '');
    expect(hosts.byHost.keys, ['fixture.invalid:443']);
  });

  testWidgets('1.2.15 connections are read, never rewritten', (tester) async {
    const shapes = [
      ('lan', 'hermes.local', 8642, false, null, 'http://hermes.local:9119'),
      (
        'proxy',
        'hermes.example.test',
        443,
        true,
        null,
        'https://hermes.example.test:443',
      ),
      (
        'x',
        'hermes.local',
        8642,
        false,
        'http://hermes.local:19119/',
        'http://hermes.local:19119',
      ),
    ];
    final saved = [
      for (final (id, host, port, tls, dash, _) in shapes)
        SavedConnection(
          id: id,
          label: id,
          host: host,
          port: port,
          useHttps: tls,
          apiKey: 'legacy-$id-key',
          dashboardUrl: dash,
        ),
    ];
    expect(
      [for (final c in saved) c.effectiveDashboardUrl],
      [for (final shape in shapes) shape.$6],
    );
    final manager = await onboardingManager();
    for (final conn in saved) {
      await manager.upsertConnection(conn);
    }
    Future<String> snapshot() async => jsonEncode({
      for (final k in manager.prefs.getKeys())
        if (!k.startsWith('capabilities_')) k: manager.prefs.get(k),
      ...await const FlutterSecureStorage().readAll(),
    });
    final before = await snapshot();
    final hosts = _dashboard();
    await http.runWithClient(() async {
      await tester.pumpWidget(
        onboardingHost(GatewayManagerScreen(connManager: manager)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('lan'));
      await tester.pumpAndSettle();
      await tapOnboarding(tester, 'instance-test');
      expect(await snapshot(), before);
      await tester.enterText(find.byKey(const ValueKey('instance-name')), 'N');
      await tapOnboarding(tester, 'instance-save');
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => hosts);
    final lan = manager.getConnections().firstWhere((c) => c.id == 'lan');
    expect(lan.label, 'N');
    expect(
      (lan.host, lan.port, lan.useHttps, lan.apiKey),
      ('hermes.local', 8642, false, 'legacy-lan-key'),
    );
    expect(hosts.byHost.keys.where((k) => k.endsWith(':8642')), isEmpty);
  });
}
