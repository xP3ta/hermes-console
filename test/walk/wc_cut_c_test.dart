// SPDX-License-Identifier: GPL-3.0-only
// WC (CUT-C, D5): "I don't know the password" is reachable from the
// browser-first sign-in screen too, not only inside the password form.
// Synthetic fixtures only.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/recover_access_page.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _forgot = ValueKey('dashboard-forgot-password');
const _usePassword = ValueKey('dashboard-use-password-here');
const _submit = ValueKey('dashboard-login-submit');

Future<void> _pump(
  WidgetTester tester, {
  required bool browserFirst,
  bool authRequired = true,
  List<String> flows = const ['native_pkce'],
  List<Map<String, Object?>>? providers,
  String locale = 'en',
}) async {
  final client = MockClient((r) async {
    if (r.url.path == '/api/status') {
      return http.Response(
        jsonEncode({'auth_required': authRequired, 'auth_flows': flows}),
        200,
      );
    }
    return http.Response(
      jsonEncode({
        'providers':
            providers ??
            [
              {'name': 'basic', 'supports_password': true},
            ],
      }),
      200,
    );
  });
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: DashboardSetupScreen(
          browserFirst: browserFirst,
          connection: SavedConnection(
            id: 'wc',
            label: 'Fixture',
            host: '127.0.0.1',
            port: 9131,
            apiKey: '',
            dashboardUrl: 'http://127.0.0.1:19119',
          ),
          authorityCurrent: () => true,
          openOAuthBrowser: (url) async => false,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }, () => client);
}

void main() {
  testWidgets('browser first: the forgot-password row is visible and opens '
      'the help sheet', (tester) async {
    await _pump(tester, browserFirst: true);
    expect(find.byKey(_submit), findsNothing);
    expect(find.byKey(_forgot), findsOneWidget);
    expect(find.text("I don't know the password"), findsOneWidget);
    await tester.tap(find.byKey(_forgot));
    await tester.pumpAndSettle();
    expect(find.byType(RecoverAccessPage), findsOneWidget);
  });

  testWidgets('Spanish copy of the row', (tester) async {
    await _pump(tester, browserFirst: true, locale: 'es');
    expect(find.byKey(_forgot), findsOneWidget);
    expect(find.text('No sé la contraseña'), findsOneWidget);
  });

  testWidgets('the password form is open from the start, the row once', (
    tester,
  ) async {
    await _pump(tester, browserFirst: true);
    expect(find.byKey(const ValueKey('onb2-password-submit')), findsOneWidget);
    expect(find.byKey(_usePassword), findsNothing);
    expect(find.byKey(_forgot), findsOneWidget);
  });

  testWidgets('OAuth-only Dashboard (no password): no password help', (
    tester,
  ) async {
    await _pump(
      tester,
      browserFirst: true,
      providers: [
        {'name': 'nous', 'supports_password': false},
      ],
    );
    expect(find.byKey(_forgot), findsNothing);
  });

  testWidgets('Dashboard without auth: no password help', (tester) async {
    await _pump(tester, browserFirst: true, authRequired: false);
    expect(find.byKey(_forgot), findsNothing);
  });

  testWidgets('classic form (browserFirst off): unchanged, one row', (
    tester,
  ) async {
    await _pump(tester, browserFirst: false, flows: const []);
    expect(find.byKey(_submit), findsOneWidget);
    expect(find.byKey(_forgot), findsOneWidget);
  });
}
