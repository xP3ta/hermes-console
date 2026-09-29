import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// The Dashboard row must not claim "connected" when only its public
/// `/api/status` answers while the saved login is rejected: chat and Bot
/// Mode sockets need that login, so the row has to say what is wrong.
void main() {
  Future<void> pumpPanel(
    WidgetTester tester, {
    required bool reachable,
    required DashboardAuthCheck auth,
    List<String>? authCalls,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          Strings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: InstanceStatusPanel(
              connection: _remote(),
              bridgeManager: null,
              reachable: (_) async => reachable,
              dashboardAuth: (conn) async {
                authCalls?.add(conn.id);
                return auth;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder dashboardDetail(String text) => find.descendant(
    of: find.byKey(const ValueKey('instance-status-row-dashboard')),
    matching: find.text(text),
  );

  testWidgets('rejected login is shown instead of "connected"', (tester) async {
    await pumpPanel(
      tester,
      reachable: true,
      auth: DashboardAuthCheck.invalidCredentials,
    );
    expect(dashboardDetail('wrong password'), findsOneWidget);
    expect(dashboardDetail('connected'), findsNothing);
  });

  testWidgets('login that needs credentials says so', (tester) async {
    await pumpPanel(
      tester,
      reachable: true,
      auth: DashboardAuthCheck.loginRequired,
    );
    expect(dashboardDetail('login required'), findsOneWidget);
    expect(dashboardDetail('connected'), findsNothing);
  });

  testWidgets('accepted login keeps "connected"', (tester) async {
    await pumpPanel(tester, reachable: true, auth: DashboardAuthCheck.ok);
    expect(dashboardDetail('connected'), findsOneWidget);
  });

  testWidgets('unknown auth result does not downgrade a reachable row', (
    tester,
  ) async {
    await pumpPanel(tester, reachable: true, auth: DashboardAuthCheck.unknown);
    expect(dashboardDetail('connected'), findsOneWidget);
  });

  testWidgets('unreachable Dashboard stays offline and skips the login', (
    tester,
  ) async {
    final calls = <String>[];
    await pumpPanel(
      tester,
      reachable: false,
      auth: DashboardAuthCheck.invalidCredentials,
      authCalls: calls,
    );
    expect(dashboardDetail('offline'), findsOneWidget);
    expect(calls, isEmpty);
  });
}

SavedConnection _remote() => SavedConnection(
  id: 'remote',
  label: 'Remote',
  host: 'example.com',
  port: 443,
  useHttps: true,
  apiKey: '',
);
