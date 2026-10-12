// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets(
    'actual Dashboard route returns staged native authority after system-browser callback',
    (tester) async {
      final calls = <http.Request>[];
      DashboardCredsResult? result;
      Uri? launched;
      final client = MockClient((r) async {
        calls.add(r);
        if (r.url.path == '/api/status') {
          return http.Response(
            '{"auth_required":true,"auth_flows":["native_pkce"]}',
            200,
          );
        }
        if (r.url.path == '/api/auth/providers') {
          return http.Response(
            '{"providers":[{"name":"portal","supports_password":false}]}',
            200,
          );
        }
        if (r.url.path == '/auth/native/token') {
          final body = jsonDecode(r.body) as Map;
          expect(body['code'], 'synthetic-route-code');
          expect(
            body['code_verifier'],
            matches(RegExp(r'^[A-Za-z0-9_-]{43}$')),
          );
          return http.Response(
            jsonEncode({
              'access_token': 'synthetic-route-access',
              'token_type': 'Bearer',
              'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
              'provider': 'portal',
              'user_id': 'synthetic-user',
            }),
            200,
          );
        }
        expect(r.url.path, '/api/auth/me');
        expect(r.headers['Authorization'], 'Bearer synthetic-route-access');
        return http.Response(
          '{"provider":"portal","user_id":"synthetic-user"}',
          200,
        );
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  result = await Navigator.of(context)
                      .push<DashboardCredsResult>(
                        MaterialPageRoute(
                          builder: (_) => DashboardSetupScreen(
                            connection: SavedConnection(
                              id: 'route-owner',
                              label: 'Existing',
                              host: '127.0.0.1',
                              port: 9131,
                              apiKey: '',
                              dashboardUrl: 'http://127.0.0.1:19119',
                            ),
                            authorityCurrent: () => true,
                            openOAuthBrowser: (url) async {
                              launched = url;
                              final cb =
                                  Uri.parse(
                                    url.queryParameters['redirect_uri']!,
                                  ).replace(
                                    queryParameters: {
                                      'code': 'synthetic-route-code',
                                      'state': url.queryParameters['state']!,
                                    },
                                  );
                              final native = HttpClient();
                              try {
                                final response = await (await native.getUrl(
                                  cb,
                                )).close();
                                expect(response.statusCode, 200);
                                await response.drain<void>();
                              } finally {
                                native.close(force: true);
                              }
                              return true;
                            },
                          ),
                        ),
                      );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final originalOverrides = HttpOverrides.current;
        await tester.runAsync(() async {
          HttpOverrides.global = null;
          try {
            await tester.tap(
              find.byKey(const ValueKey('dashboard-oauth-browser')),
            );
            for (
              var i = 0;
              i < 50 && calls.every((r) => r.url.path != '/api/auth/me');
              i++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          } finally {
            HttpOverrides.global = originalOverrides;
          }
        });
        for (var i = 0; i < 20 && result == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pumpAndSettle();
        }
        expect(launched!.path, '/auth/native/authorize');
        expect(launched!.queryParameters['code_challenge_method'], 'S256');
        expect(find.byType(DashboardSetupScreen), findsNothing);
        expect(result!.mode, AuthMode.sessionToken);
        final staged = MobileOAuthSession.decode(
          result!.sessionToken,
          'route-owner',
          'http://127.0.0.1:19119',
        );
        expect(staged!.accessToken, 'synthetic-route-access');
        expect(
          calls.where((r) => r.url.path == '/auth/native/token'),
          hasLength(1),
        );
        expect(calls.where((r) => r.url.path.startsWith('/bridge/')), isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
  );
  testWidgets(
    'advertised native broker offers system browser instead of unavailable',
    (tester) async {
      final client = MockClient(
        (r) async => http.Response(
          r.url.path == '/api/status'
              ? '{"auth_required":true,"auth_flows":["native_pkce"]}'
              : '{"providers":[{"name":"portal","supports_password":false,"supports_session":true}]}',
          200,
        ),
      );
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: DashboardSetupScreen(
              connection: SavedConnection(
                id: 'owner',
                label: 'Existing',
                host: '127.0.0.1',
                port: 8642,
                apiKey: '',
                dashboardUrl: 'http://127.0.0.1:19119',
              ),
              authorityCurrent: () => true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('dashboard-oauth-browser')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('dashboard-oauth-unavailable')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
  );
}
