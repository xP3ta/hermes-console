// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// Settings › Server › Nous Portal account: the card with the state the
// server reports, the sign-in on the profile on screen, a disconnect that
// asks first, an older server told apart from a failure, and a read-only
// connection that sends nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/nous_account_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/models_server.dart';

ModelsServer _server({bool connected = false}) => ModelsServer()
  ..accounts = [
    {
      'id': 'nous',
      'name': 'Nous Portal',
      'flow': 'device_code',
      'disconnectable': true,
      'docs_url': 'https://portal.nousresearch.com',
      'status': {'logged_in': connected, 'has_refresh_token': connected},
    },
  ];

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: modelsConnectionId,
  label: 'Fixture',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'synthetic-connection-token',
  readOnly: readOnly,
  kind: InstanceKind.vps,
);

Future<List<Uri>> _pump(
  WidgetTester tester,
  DashboardClient client,
  ActiveProfileScope scope, {
  bool readOnly = false,
  double textScale = 1,
  Locale locale = const Locale('en'),
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(360, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final opened = <Uri>[];
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      theme: theme ?? AppTheme.hermesRedDark,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: NousAccountScreen(
        connection: _connection(readOnly: readOnly),
        profileScope: scope,
        dashboardClientForTesting: client,
        openUrlForTesting: (uri) async {
          opened.add(uri);
          return true;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

/// Taps and lets the route move without settling: the link page counts
/// down while it is open.
Future<void> _tapAndPump(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late ActiveProfileScope scope;
  setUp(() async => scope = await modelsScope());

  Finder key(String value) => find.byKey(ValueKey(value));

  testWidgets('not connected: connect runs on the profile and opens Nous', (
    tester,
  ) async {
    final server = _server();
    final opened = await _pump(tester, server.client(), scope);
    expect(find.text('Not connected'), findsOneWidget);
    await _tapAndPump(tester, key('nac-card-connect'));
    expect(
      server.of('POST', '/api/providers/oauth/nous/start').single.profile,
      'ana',
    );
    expect(find.text('HRMS-2026'), findsOneWidget);
    expect(opened.single.host, 'portal.nousresearch.com');
    server.settleOAuth(
      'synthetic-session-1',
      status: 'approved',
      email: 'owner@example.test',
    );
    await _tapAndPump(tester, key('nac-link-check'));
    expect(key('nac-link-approved'), findsOneWidget);
    await _tapAndPump(tester, key('nac-link-done'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connected'), findsWidgets);
    expect(find.textContaining('owner@example.test'), findsOneWidget);
  });

  testWidgets('disconnect asks first, then deletes on the profile', (
    tester,
  ) async {
    final server = _server(connected: true);
    await _pump(tester, server.client(), scope);
    await _tapAndPump(tester, key('nac-card-manage'));
    await tester.pumpAndSettle();
    await _tapAndPump(tester, key('models-account-disconnect-nous'));
    await tester.pumpAndSettle();
    expect(server.writes, isEmpty, reason: 'nothing removed unasked');
    await tester.tap(key('nac-disconnect-confirm'));
    await tester.pumpAndSettle();
    expect(
      server.of('DELETE', '/api/providers/oauth/nous').single.profile,
      'ana',
    );
    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('an older server without the route says so', (tester) async {
    final client = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'synthetic-fixture-token',
      httpClientOverride: MockClient(
        (_) async => http.Response('{"detail":"Not Found"}', 404),
      ),
    );
    await _pump(tester, client, scope);
    expect(find.text('Not available on this server'), findsOneWidget);
    expect(key('nac-card-connect'), findsNothing);
    expect(key('nac-screen-load-failed'), findsNothing);
  });

  testWidgets('read-only: the state shows, nothing is sent', (tester) async {
    final server = _server();
    await _pump(tester, server.client(), scope, readOnly: true);
    expect(find.text('Not connected'), findsOneWidget);
    await tester.tap(key('nac-card-connect'), warnIfMissed: false);
    await tester.pump();
    expect(server.writes, isEmpty);
  });

  final themes = <String, ThemeData>{
    'dark': AppTheme.hermesRedDark,
    'light': AppTheme.hermesRedLight,
    'midnight': AppTheme.fromId('midnight'),
  };
  for (final locale in Strings.supportedLocales) {
    for (final theme in themes.entries) {
      testWidgets('fits at 2x · ${locale.languageCode} · ${theme.key}', (
        tester,
      ) async {
        await _pump(
          tester,
          _server().client(),
          scope,
          textScale: 2,
          locale: locale,
          theme: theme.value,
        );
        expect(key('nac-card'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
