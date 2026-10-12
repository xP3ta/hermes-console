import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart'
    show HermesPrimaryButton;

void main() {
  testWidgets(
    'Dashboard late status after owner ABA is an explicit expired lease',
    (tester) async {
      var epoch = 0;
      final held = Completer<http.Response>();
      final client = MockClient((r) async => held.future);
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            theme: AppTheme.hermesRedDark,
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: DashboardSetupScreen(
              connection: SavedConnection(
                id: 'ABA',
                label: 'Existing',
                host: '127.0.0.1',
                port: 9131,
                apiKey: 'synthetic-never-sent',
                dashboardUrl: 'http://127.0.0.1:19119',
              ),
              authorityCurrent: () => epoch == 0,
            ),
          ),
        );
        await tester.pump();
        epoch++;
        epoch++;
        held.complete(http.Response('{"auth_required":false}', 200));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(find.byType(TextField), findsNothing);
        expect(
          find.byKey(const ValueKey('dashboard-login-error')),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
  );
  testWidgets(
    'Dashboard private HTTP requires consent before secret admission',
    (tester) async {
      final hits = <http.Request>[];
      final client = MockClient((r) async {
        hits.add(r);
        return http.Response(
          r.url.path == '/api/status'
              ? '{"auth_required":false}'
              : '{"profiles":[]}',
          200,
        );
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            theme: AppTheme.hermesRedDark,
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: DashboardSetupScreen(
              connection: SavedConnection(
                id: 'consent',
                label: 'Existing',
                host: '10.0.0.2',
                port: 9131,
                apiKey: 'synthetic-never-sent',
                dashboardUrl: 'http://10.0.0.2:19119',
              ),
              authorityCurrent: () => true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          'synthetic-consented-token',
        );
        expect(
          tester
              .widget<HermesPrimaryButton>(
                find.byKey(const ValueKey('dashboard-login-submit')),
              )
              .onTap,
          isNull,
        );
        expect(hits, hasLength(1));
        await tester.tap(find.byType(Checkbox));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('dashboard-login-submit')));
        await tester.pumpAndSettle();
        expect(hits.where((r) => r.url.path == '/api/profiles'), hasLength(1));
        expect(
          hits.last.headers['X-Hermes-Session-Token'],
          'synthetic-consented-token',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
  );

  for (final status in [
    '401',
    '403',
    '500',
    'timeout',
    'non-json',
    'missing-bool',
    'string-bool',
  ]) {
    testWidgets(
      'Dashboard public status unknown never admits a secret: $status',
      (tester) async {
        final hits = <http.Request>[];
        final client = MockClient((r) async {
          hits.add(r);
          if (status == 'timeout') throw TimeoutException('synthetic');
          return http.Response(
            status == 'non-json'
                ? '<html/>'
                : status == 'string-bool'
                ? '{"auth_required":"false"}'
                : '{}',
            int.tryParse(status) ?? 200,
          );
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('en'),
              theme: AppTheme.hermesRedDark,
              localizationsDelegates: Strings.localizationsDelegates,
              supportedLocales: Strings.supportedLocales,
              home: DashboardSetupScreen(
                connection: SavedConnection(
                  id: 'unknown',
                  label: 'Existing',
                  host: '127.0.0.1',
                  port: 9131,
                  apiKey: 'synthetic-never-sent',
                  dashboardUrl: 'http://127.0.0.1:19119',
                ),
                authorityCurrent: () => true,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(TextField), findsNothing);
          expect(
            find.byKey(const ValueKey('dashboard-login-submit')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('dashboard-login-error')),
            findsOneWidget,
          );
          expect(hits, hasLength(1));
          expect(hits.single.url.path, '/api/status');
          expect(
            hits.single.headers.keys.any(
              (k) => k.toLowerCase() == 'authorization',
            ),
            isFalse,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }, () => client);
      },
    );
  }

  for (final outcome in ['accepted', '401', '404', '500', 'timeout']) {
    for (final requiredAuth in [true, false]) {
      testWidgets(
        'Dashboard existing authority login selector: $requiredAuth $outcome',
        (tester) async {
          DashboardClient.resetSharedPasswordSessionsForTesting();
          SharedPreferences.setMockInitialValues({});
          final secure = <String, String>{};
          TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel(
                  'plugins.it_nomads.com/flutter_secure_storage',
                ),
                (call) async {
                  final args = (call.arguments as Map?) ?? {};
                  if (call.method == 'write') {
                    secure[args['key']] = args['value'];
                  }
                  if (call.method == 'read') return secure[args['key']];
                  if (call.method == 'readAll') return secure;
                  if (call.method == 'delete') secure.remove(args['key']);
                  return null;
                },
              );
          final prefs = await SharedPreferences.getInstance();
          final manager = await ConnectionManager.create(prefs);
          addTearDown(manager.dispose);
          final conn = SavedConnection(
            id: 'login-owner',
            label: 'Existing',
            host: '127.0.0.1',
            port: 9131,
            apiKey: 'synthetic-gateway-key',
            dashboardUrl: 'http://127.0.0.1:19119',
          );
          await manager.upsertConnection(conn);
          final requests = <http.Request>[];
          var bridgeCalls = 0;
          final client = MockClient((r) async {
            if (r.url.path == '/auth/password-login' ||
                r.url.path == '/api/auth/me' ||
                r.url.path == '/api/profiles') {
              if (outcome == 'timeout') {
                throw TimeoutException('synthetic timeout');
              }
              if (outcome != 'accepted') {
                requests.add(r);
                return http.Response('{}', int.parse(outcome));
              }
            }
            requests.add(r);
            expect(r.url.port, 19119);
            if (r.url.path == '/api/status') {
              expect(
                r.headers.keys.any((k) => k.toLowerCase() == 'authorization'),
                isFalse,
              );
              return http.Response(
                jsonEncode({'auth_required': requiredAuth}),
                200,
              );
            }
            if (r.url.path == '/api/auth/providers') {
              return http.Response(
                '{"providers":[{"name":"basic","display_name":"Existing password","supports_password":true}]}',
                200,
              );
            }
            if (r.url.path == '/auth/password-login') {
              expect(jsonDecode(r.body), {
                'provider': 'basic',
                'username': 'synthetic-user',
                'password': 'synthetic-password',
              });
              return http.Response(
                '{"ok":true}',
                200,
                headers: {
                  'set-cookie':
                      'hermes_session_at=synthetic-cookie; HttpOnly; Path=/',
                },
              );
            }
            if (r.url.path == '/api/auth/me' || r.url.path == '/api/profiles') {
              if (requiredAuth) {
                expect(r.headers['cookie'], contains('synthetic-cookie'));
              } else {
                expect(
                  r.headers['X-Hermes-Session-Token'],
                  'synthetic-session-token',
                );
              }
              return http.Response(
                requiredAuth
                    ? '{"user_id":"synthetic-user"}'
                    : '{"profiles":[{"name":"default"}]}',
                200,
              );
            }
            if (r.url.path == '/api/auth/ws-ticket') {
              return requiredAuth
                  ? http.Response(
                      jsonEncode({
                        'ticket': 'synthetic-ticket-${requests.length}',
                      }),
                      200,
                    )
                  : http.Response('{}', 404);
            }
            return http.Response('{}', 404);
          });
          tester.view.physicalSize = const Size(1000, 2400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await http.runWithClient(() async {
            await tester.pumpWidget(
              MaterialApp(
                locale: const Locale('en'),
                theme: AppTheme.hermesRedDark,
                localizationsDelegates: Strings.localizationsDelegates,
                supportedLocales: Strings.supportedLocales,
                home: InstanceEditScreen(connManager: manager, initial: conn),
              ),
            );
            await tester.pumpAndSettle();
            final action = find.byKey(
              const ValueKey('instance-dashboard-sign-in'),
            );
            await tester.ensureVisible(action);
            await tester.tap(action);
            await tester.pumpAndSettle();
            expect(find.byType(DashboardSetupScreen), findsOneWidget);
            expect(
              requests.where((r) => r.url.path == '/api/status'),
              hasLength(1),
            );
            expect(bridgeCalls, 0);
            final fields = find.descendant(
              of: find.byType(DashboardSetupScreen),
              matching: find.byType(TextField),
            );
            if (requiredAuth) {
              await tester.enterText(fields.at(0), 'synthetic-user');
              await tester.enterText(fields.at(1), 'synthetic-password');
            } else {
              await tester.enterText(fields.first, 'synthetic-session-token');
            }
            await tester.tap(
              find.byKey(const ValueKey('dashboard-login-submit')),
            );
            await tester.pumpAndSettle();
            if (outcome == 'accepted') {
              expect(find.byType(DashboardSetupScreen), findsNothing);
              expect(
                requests.where(
                  (r) =>
                      r.url.path ==
                      (requiredAuth ? '/api/auth/me' : '/api/profiles'),
                ),
                isNotEmpty,
              );
              final save = find.byKey(const ValueKey('instance-save')).last;
              await tester.ensureVisible(save);
              await tester.tap(save);
              await tester.pumpAndSettle();
              final saved = manager.getConnections().single;
              expect(
                saved.dashboardAuthMode,
                requiredAuth ? AuthMode.basicAuth : AuthMode.sessionToken,
              );
              final stored = await manager.getDashboardSecrets(saved.id);
              expect(
                requiredAuth ? stored.password : stored.sessionToken,
                requiredAuth ? 'synthetic-password' : 'synthetic-session-token',
              );
              final dashboard = DashboardClient.lazy(saved);
              final first = await dashboard.webSocketAuth();
              final second = await dashboard.webSocketAuth();
              expect(first.queryName, requiredAuth ? 'ticket' : 'token');
              if (requiredAuth) {
                expect(first.credential, isNot(second.credential));
              } else {
                expect(first.credential, 'synthetic-session-token');
              }
              dashboard.close();
              expect(
                secure.values.any((v) => v.contains('synthetic-ticket-')),
                isFalse,
              );
            } else {
              expect(
                find.byKey(const ValueKey('dashboard-login-error')),
                findsOneWidget,
              );
              expect(find.byType(DashboardSetupScreen), findsOneWidget);
            }
            expect(requests.where((r) => r.url.path == '/'), isEmpty);
            expect(
              requests.where((r) => r.url.path.startsWith('/bridge/')),
              isEmpty,
            );
            expect(
              manager.getConnections().single.apiKey,
              'synthetic-gateway-key',
            );
            expect(
              prefs.getKeys().any(
                (k) =>
                    '${prefs.get(k)}'.contains('synthetic-password') ||
                    '${prefs.get(k)}'.contains('synthetic-session-token'),
              ),
              isFalse,
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }, () => client);
        },
      );
    }
  }
}
