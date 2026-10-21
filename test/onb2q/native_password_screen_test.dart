// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/recover_access_page.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _pass = 'S3cret-pass-CANARY';

/// A Dashboard with the `basic` provider and the native flow.
MockClient _dashboard(
  List<String> log, {
  int loginStatus = 200,
  bool route = true,
}) {
  Map<String, String> q = {};
  return MockClient((r) async {
    log.add('${r.method} ${r.url.path}');
    switch ('${r.method} ${r.url.path}') {
      case 'GET /api/status':
        return http.Response(
          '{"auth_required":true,"auth_flows":["native_pkce"]}',
          200,
        );
      case 'GET /api/auth/providers':
        return http.Response(
          '{"providers":[{"name":"basic","supports_password":true}]}',
          200,
        );
      case 'GET /auth/native/authorize':
        q = r.url.queryParameters;
        return http.Response(
          '',
          route ? 302 : 404,
          headers: {'set-cookie': 'hermes_session_pkce=b1; Path=/; HttpOnly'},
        );
      case 'POST /auth/password-login':
        if (loginStatus != 200) return http.Response('{}', loginStatus);
        expect(r.headers['Cookie'], 'hermes_session_pkce=b1');
        final next = '${q['redirect_uri']}?code=c1&state=${q['state']}';
        return http.Response(jsonEncode({'ok': true, 'next': next}), 200);
      case 'POST /auth/native/token':
        return http.Response(
          jsonEncode({
            'access_token': 'a1',
            'refresh_token': 'r1',
            'token_type': 'Bearer',
            'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
            'provider': 'basic',
            'user_id': 'admin',
          }),
          200,
        );
    }
    return http.Response('{}', 404);
  });
}

Future<DashboardCredsResult?> _open(
  WidgetTester tester,
  MockClient client, {
  required void Function(DashboardCredsResult?) onResult,
  String url = 'http://127.0.0.1:9119',
}) async {
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async => onResult(
              await Navigator.of(context).push<DashboardCredsResult>(
                MaterialPageRoute(
                  builder: (_) => DashboardSetupScreen(
                    browserFirst: true,
                    connection: SavedConnection(
                      id: 'conn-1',
                      label: 'Home',
                      host: '127.0.0.1',
                      port: 9119,
                      apiKey: '',
                      dashboardUrl: url,
                    ),
                    authorityCurrent: () => true,
                  ),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }, () => client);
  return null;
}

Future<void> _type(WidgetTester tester, String user, String pass) async {
  await tester.enterText(find.byKey(const ValueKey('onb2-user')), user);
  await tester.enterText(find.byKey(const ValueKey('onb2-password')), pass);
}

Future<void> _submit(WidgetTester tester, MockClient client) async {
  await http.runWithClient(() async {
    await tester.tap(find.byKey(const ValueKey('onb2-password-submit')));
    await tester.pumpAndSettle();
  }, () => client);
}

void main() {
  testWidgets('user and password are the way in; the browser is the other', (
    tester,
  ) async {
    final log = <String>[];
    final client = _dashboard(log);
    DashboardCredsResult? result;
    await _open(tester, client, onResult: (r) => result = r);
    expect(find.byKey(const ValueKey('onb2-user')), findsOneWidget);
    expect(find.byKey(const ValueKey('onb2-password')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('dashboard-oauth-browser')),
      findsOneWidget,
    );
    // One «I don't know the password» entry, not two.
    expect(
      find.byKey(const ValueKey('dashboard-forgot-password')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('dashboard-use-password-here')),
      findsNothing,
    );
    TextField field() =>
        tester.widget<TextField>(find.byKey(const ValueKey('onb2-password')));
    expect(field().obscureText, isTrue);
    await tester.tap(find.byKey(const ValueKey('onb2-password-reveal')));
    await tester.pump();
    expect(field().obscureText, isFalse);

    await _type(tester, 'admin', _pass);
    await _submit(tester, client);
    expect(result, isNotNull);
    expect(result!.mode, AuthMode.sessionToken);
    expect(result!.sessionToken, startsWith(MobileOAuthSession.prefix));
    // R2: nothing of the password leaves the form but the request itself.
    expect(result!.password, isEmpty);
    expect(result!.username, isEmpty);
    expect(result!.sessionToken, isNot(contains(_pass)));
    expect(
      log.where((l) => l.startsWith('POST /auth/native/token')),
      hasLength(1),
    );
  });

  testWidgets('a wrong password says so and points to «I don\'t know it»', (
    tester,
  ) async {
    final client = _dashboard([], loginStatus: 401);
    DashboardCredsResult? result;
    await _open(tester, client, onResult: (r) => result = r);
    await _type(tester, 'admin', 'nope');
    await _submit(tester, client);
    expect(result, isNull);
    final s = Strings.of(tester.element(find.byType(DashboardSetupScreen)));
    expect(find.text(s.onb2WrongPassword), findsOneWidget);
    expect(
      find.byKey(const ValueKey('dashboard-forgot-password')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('onb2-password-submit')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dashboard-forgot-password')));
    await tester.pumpAndSettle();
    expect(find.byType(RecoverAccessPage), findsOneWidget);
  });

  testWidgets('too many attempts asks to wait', (tester) async {
    final client = _dashboard([], loginStatus: 429);
    await _open(tester, client, onResult: (_) {});
    await _type(tester, 'admin', _pass);
    await _submit(tester, client);
    final s = Strings.of(tester.element(find.byType(DashboardSetupScreen)));
    expect(find.text(s.onb2TooManyTries), findsOneWidget);
  });

  testWidgets('a server without the route falls back to the browser', (
    tester,
  ) async {
    final client = _dashboard([], loginStatus: 404);
    await _open(tester, client, onResult: (_) {});
    await _type(tester, 'admin', _pass);
    await _submit(tester, client);
    final s = Strings.of(tester.element(find.byType(DashboardSetupScreen)));
    expect(find.text(s.onb2PasswordUnsupported), findsOneWidget);
    expect(find.byKey(const ValueKey('onb2-password-submit')), findsNothing);
    expect(
      find.byKey(const ValueKey('dashboard-oauth-browser')),
      findsOneWidget,
    );
    // No second password path: no old basicAuth form that would store it.
    expect(
      find.byKey(const ValueKey('dashboard-use-password-here')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('dashboard-browser-handles-password')),
      findsNothing,
    );
  });
}
