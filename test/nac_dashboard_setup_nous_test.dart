// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// Signing in to the Dashboard with the `nous` auth provider, against a fake
// that answers like hermes_cli/dashboard_auth/routes.py: the button is
// named after the provider, the native authorize URL names it (PKCE S256,
// state), a callback with a foreign state is refused and completes
// nothing, the right one is exchanged once and the session is handed back
// as the connection's token envelope.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _base = 'http://127.0.0.1:19119';

SavedConnection _conn() => SavedConnection(
  id: 'nous-owner',
  label: 'Nous Cloud',
  host: '127.0.0.1',
  port: 9131,
  apiKey: '',
  dashboardUrl: _base,
);

/// The Dashboard as the app sees it: discovery, the token exchange and the
/// identity read. The browser side is the test's own callback below.
MockClient _dashboard(
  List<http.Request> calls, {
  List<Map<String, Object>> providers = const [
    {
      'name': 'nous',
      'display_name': 'Nous Research',
      'supports_password': false,
    },
  ],
}) => MockClient((r) async {
  calls.add(r);
  switch (r.url.path) {
    case '/api/status':
      return http.Response(
        '{"auth_required":true,"auth_flows":["cookie","native_pkce"]}',
        200,
      );
    case '/api/auth/providers':
      return http.Response(jsonEncode({'providers': providers}), 200);
    case '/auth/native/token':
      final body = jsonDecode(r.body) as Map;
      expect(body.keys.toSet(), {'code', 'code_verifier'});
      expect(body['code'], 'synthetic-nous-code');
      return http.Response(
        jsonEncode({
          'access_token': 'synthetic-nous-access',
          'refresh_token': 'synthetic-nous-refresh',
          'token_type': 'Bearer',
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
          'provider': 'nous',
          'user_id': 'synthetic-user',
        }),
        200,
      );
    case '/api/auth/me':
      expect(r.headers['Authorization'], 'Bearer synthetic-nous-access');
      return http.Response(
        '{"provider":"nous","user_id":"synthetic-user"}',
        200,
      );
  }
  return http.Response('{"detail":"not found"}', 404);
});

/// What the system browser ends with: the loopback callback of the app.
Future<int> _callback(Uri authorize, {String? state}) async {
  final cb = Uri.parse(authorize.queryParameters['redirect_uri']!).replace(
    queryParameters: {
      'code': 'synthetic-nous-code',
      'state': state ?? authorize.queryParameters['state']!,
    },
  );
  final native = HttpClient();
  try {
    final response = await (await native.getUrl(cb)).close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    native.close(force: true);
  }
}

Widget _host(
  Future<bool> Function(Uri) openOAuthBrowser,
  void Function(DashboardCredsResult?) onResult, {
  bool browserFirst = false,
}) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Builder(
    builder: (context) => FilledButton(
      onPressed: () async {
        onResult(
          await Navigator.of(context).push<DashboardCredsResult>(
            MaterialPageRoute(
              builder: (_) => DashboardSetupScreen(
                browserFirst: browserFirst,
                connection: _conn(),
                authorityCurrent: () => true,
                openOAuthBrowser: openOAuthBrowser,
              ),
            ),
          ),
        );
      },
      child: const Text('Open'),
    ),
  ),
);

Future<void> _withRealLoopback(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final original = HttpOverrides.current;
  await tester.runAsync(() async {
    HttpOverrides.global = null;
    try {
      await body();
    } finally {
      HttpOverrides.global = original;
    }
  });
}

void main() {
  setUp(DashboardClient.resetSharedPasswordSessionsForTesting);

  testWidgets('the Nous provider gets its own button, named after it', (
    tester,
  ) async {
    final calls = <http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(_host((_) async => true, (_) {}));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Continue with Nous'), findsOneWidget);
      expect(find.text('Sign in with system browser'), findsNothing);
      expect(
        find.byKey(const ValueKey('dashboard-oauth-browser')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => _dashboard(calls));
  });

  testWidgets('several providers: one button each, the password form apart', (
    tester,
  ) async {
    final calls = <http.Request>[];
    await http.runWithClient(
      () async {
        await tester.pumpWidget(_host((_) async => true, (_) {}));
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Continue with Nous'), findsOneWidget);
        expect(find.text('Continue with Company SSO'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('dashboard-oauth-browser-self_hosted')),
          findsOneWidget,
        );
        // `basic` keeps the password form; it is not a browser button here.
        expect(find.text('Continue with basic'), findsNothing);
        expect(
          find.byKey(const ValueKey('dashboard-login-submit')),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
      () => _dashboard(
        calls,
        providers: const [
          {
            'name': 'basic',
            'display_name': 'Password',
            'supports_password': true,
          },
          {
            'name': 'nous',
            'display_name': 'Nous Research',
            'supports_password': false,
          },
          {
            'name': 'self_hosted',
            'display_name': 'Company SSO',
            'supports_password': false,
          },
        ],
      ),
    );
  });

  testWidgets(
    'a foreign state is refused; the right callback signs in with nous',
    (tester) async {
      final calls = <http.Request>[];
      DashboardCredsResult? result;
      Uri? launched;
      await http.runWithClient(() async {
        await tester.pumpWidget(
          _host((url) async {
            launched = url;
            // The attacker's callback first: refused, nothing exchanged.
            expect(await _callback(url, state: 'foreign-state'), 400);
            expect(
              calls.any((r) => r.url.path == '/auth/native/token'),
              isFalse,
            );
            expect(await _callback(url), 200);
            return true;
          }, (r) => result = r),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await _withRealLoopback(tester, () async {
          await tester.tap(
            find.byKey(const ValueKey('dashboard-oauth-browser')),
          );
          for (
            var i = 0;
            i < 100 && calls.every((r) => r.url.path != '/api/auth/me');
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        for (var i = 0; i < 20 && result == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pumpAndSettle();
        }
        final query = launched!.queryParameters;
        expect(launched!.path, '/auth/native/authorize');
        expect(query['provider'], 'nous');
        expect(query['code_challenge_method'], 'S256');
        expect(
          query['code_challenge'],
          matches(RegExp(r'^[A-Za-z0-9_-]{43}$')),
        );
        expect(query['state'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(query.containsKey('code_verifier'), isFalse);
        expect(
          calls.where((r) => r.url.path == '/auth/native/token'),
          hasLength(1),
        );
        expect(find.byType(DashboardSetupScreen), findsNothing);
        expect(result!.mode, AuthMode.sessionToken);
        final session = MobileOAuthSession.decode(
          result!.sessionToken,
          'nous-owner',
          _base,
        )!;
        expect(session.provider, 'nous');
        expect(session.accessToken, 'synthetic-nous-access');
        // Without simple connect the broker refresh token is not retained.
        expect(session.refreshable, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => _dashboard(calls));
    },
  );

  testWidgets('simple connect keeps the rotating refresh token', (
    tester,
  ) async {
    final calls = <http.Request>[];
    DashboardCredsResult? result;
    await http.runWithClient(() async {
      await tester.pumpWidget(
        _host(
          (url) async {
            expect(await _callback(url), 200);
            return true;
          },
          (r) => result = r,
          browserFirst: true,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await _withRealLoopback(tester, () async {
        await tester.tap(find.byKey(const ValueKey('dashboard-oauth-browser')));
        for (
          var i = 0;
          i < 100 && calls.every((r) => r.url.path != '/api/auth/me');
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      for (var i = 0; i < 20 && result == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
      }
      final session = MobileOAuthSession.decode(
        result!.sessionToken,
        'nous-owner',
        _base,
      )!;
      expect(session.refreshable, isTrue);
      expect(session.provider, 'nous');
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => _dashboard(calls));
  });
}
