// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final editing in [false, true]) {
    for (final status in [200, 400, 401, 404, 500, -1]) {
      testWidgets(
        'official ${editing ? 'edit' : 'create'} $status retains rejected draft and retires raw menu',
        (tester) async {
          tester.view.physicalSize = const Size(900, 1600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final requests = <http.Request>[];
          final client = DashboardClient(
            host: 'fixture.invalid',
            useHttps: true,
            manualToken: 'synthetic-fixture-token',
            httpClientOverride: MockClient((request) async {
              requests.add(request);
              if (request.url.path == '/api/profiles') {
                return http.Response('[]', 200);
              }
              if (request.method == 'GET' &&
                  request.url.path == '/api/cron/jobs') {
                return http.Response(
                  jsonEncode(
                    editing
                        ? [
                            {
                              'id': 'existing',
                              'profile': 'owner-b',
                              'name': 'Fixture task',
                              'prompt': 'Original',
                              'schedule': '0 9 * * *',
                              'enabled': true,
                            },
                          ]
                        : [],
                  ),
                  200,
                );
              }
              if (request.url.path == '/api/cron/delivery-targets') {
                return http.Response(
                  '{"targets":[{"id":"local","name":"Local"},{"id":"telegram","name":"Telegram"}]}',
                  200,
                );
              }
              if (request.url.path == '/api/model/options') {
                return http.Response('{"providers":[]}', 200);
              }
              if (request.url.path == '/api/cron/blueprints') {
                return http.Response('{"blueprints":[]}', 200);
              }
              if (request.method == (editing ? 'PUT' : 'POST') &&
                  request.url.path ==
                      (editing
                          ? '/api/cron/jobs/existing'
                          : '/api/cron/jobs')) {
                if (status == -1) throw TimeoutException('fixture timeout');
                return http.Response(
                  jsonEncode(
                    status == 200
                        ? {
                            'id': 'created',
                            'prompt': 'Keep this draft',
                            'schedule': '0 9 * * *',
                            'enabled': true,
                          }
                        : {
                            'error':
                                'fixture server rejected execution context',
                          },
                  ),
                  status,
                );
              }
              fail(
                'Unexpected transport ${request.method} ${request.url.path}',
              );
            }),
          );
          addTearDown(client.close);
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: Strings.localizationsDelegates,
              supportedLocales: Strings.supportedLocales,
              theme: AppTheme.fromId('dark'),
              home: CronScreen(
                connection: SavedConnection(
                  id: 'fixture',
                  label: 'Fixture',
                  host: 'fixture.invalid',
                  port: 8642,
                  apiKey: 'synthetic-fixture-key',
                ),
                profileOverride: 'research',
                clientOverride: client,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('cron-screen-more')), findsNothing);
          if (editing) {
            await tester.tap(
              find.byKey(const ValueKey('cron-job-menu-existing')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('Edit').last);
          } else {
            await tester.tap(find.widgetWithText(FilledButton, 'New task'));
          }
          await tester.pumpAndSettle();
          final prompt = find.descendant(
            of: find.byKey(const ValueKey('cron-prompt-field')),
            matching: find.byType(EditableText),
          );
          await tester.enterText(prompt, 'Keep this draft');
          await tester.pump();
          if (status == 200) {
            await tester.ensureVisible(
              find.byKey(const ValueKey('cron-delivery-row')),
            );
            await tester.tap(find.byKey(const ValueKey('cron-delivery-row')));
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey('cron-delivery-telegram')),
            );
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byKey(const ValueKey('cron-editor-submit')));
          await tester.pumpAndSettle();
          final writes = requests
              .where((r) => r.method == (editing ? 'PUT' : 'POST'))
              .toList();
          expect(writes, hasLength(status == 401 ? 2 : 1));
          expect(
            writes.first.url.path,
            editing ? '/api/cron/jobs/existing' : '/api/cron/jobs',
          );
          expect(
            writes.first.url.queryParameters['profile'],
            editing ? 'owner-b' : 'research',
          );
          final body = jsonDecode(writes.first.body) as Map;
          if (status == 200) {
            expect((editing ? body['updates'] : body)['deliver'], 'telegram');
          }
          expect(
            (editing ? body['updates'] : body)['prompt'],
            'Keep this draft',
          );
          if (status != 200) {
            expect(prompt, findsOneWidget);
            expect(
              tester.widget<EditableText>(prompt).controller.text,
              'Keep this draft',
            );
            await tester.scrollUntilVisible(
              find.byKey(const ValueKey('cron-editor-error')),
              200,
              scrollable: find.byType(Scrollable).last,
            );
            // R4: the server's own body is never shown (any status); the
            // editor keeps the draft and a localized error.
            final serverDetail = find.textContaining(
              'fixture server rejected execution context',
            );
            if (status == -1) {
              expect(
                find.textContaining('The server did not respond in time.'),
                findsWidgets,
              );
            } else if (editing && status == 404) {
              expect(find.textContaining('owner-b'), findsWidgets);
            } else {
              expect(serverDetail, findsNothing);
              expect(
                find.byKey(const ValueKey('cron-editor-error')),
                findsOneWidget,
              );
            }
            expect(
              find.byKey(const ValueKey('cron-job-created')),
              findsNothing,
            );
          } else {
            expect(prompt, findsNothing);
          }
          expect(
            requests.every(
              (r) =>
                  r.url.path.startsWith('/api/cron/') ||
                  r.url.path == '/api/model/options' ||
                  r.url.path == '/api/profiles',
            ),
            isTrue,
            reason: requests.map((r) => r.url.path).join(', '),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
  for (final action in ['create', 'delete']) {
    testWidgets(
      '$action rejects authority revoked while editor or confirmation is open',
      (tester) async {
        tester.view.physicalSize = const Size(900, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SavedConnection connection(bool readOnly) => SavedConnection(
          id: 'authority-fixture',
          label: 'Fixture',
          host: 'fixture.invalid',
          port: 8642,
          apiKey: 'synthetic-fixture-key',
          useHttps: true,
          readOnly: readOnly,
        );
        final current = ValueNotifier(connection(false));
        addTearDown(current.dispose);
        final requests = <http.Request>[];
        final client = DashboardClient(
          host: 'fixture.invalid',
          useHttps: true,
          manualToken: 'synthetic-fixture-token',
          httpClientOverride: MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/api/cron/jobs' &&
                request.method == 'GET') {
              return http.Response(
                jsonEncode([
                  {
                    'id': 'existing',
                    'name': 'Fixture task',
                    'profile': 'owner-b',
                    'prompt': 'Original',
                    'schedule': '0 9 * * *',
                    'enabled': true,
                  },
                ]),
                200,
              );
            }
            if (request.url.path == '/api/profiles') {
              return http.Response('[]', 200);
            }
            if (request.url.path == '/api/cron/delivery-targets') {
              return http.Response('{"targets":[]}', 200);
            }
            if (request.url.path == '/api/model/options') {
              return http.Response('{"providers":[]}', 200);
            }
            if (request.url.path == '/api/cron/blueprints') {
              return http.Response('{"blueprints":[]}', 200);
            }
            return http.Response('{"id":"created","deleted":true}', 200);
          }),
        );
        addTearDown(client.close);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            theme: AppTheme.fromId('dark'),
            home: ValueListenableBuilder<SavedConnection>(
              valueListenable: current,
              builder: (_, conn, _) => CronScreen(
                connection: conn,
                clientOverride: client,
                profileOverride: 'research',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (action == 'create') {
          await tester.tap(find.byKey(const ValueKey('cron-create')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.descendant(
              of: find.byKey(const ValueKey('cron-prompt-field')),
              matching: find.byType(EditableText),
            ),
            'Retain revoked draft',
          );
          await tester.pump();
        } else {
          await tester.tap(
            find.byKey(const ValueKey('cron-job-menu-existing')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Delete').last);
          await tester.pumpAndSettle();
        }
        current.value = connection(true);
        await tester.pump();
        await tester.tap(
          find.byKey(
            ValueKey(
              action == 'create' ? 'cron-editor-submit' : 'cron-delete-confirm',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(requests.where((r) => r.method != 'GET'), isEmpty);
        if (action == 'create') {
          final prompt = find.descendant(
            of: find.byKey(const ValueKey('cron-prompt-field')),
            matching: find.byType(EditableText),
          );
          expect(
            tester.widget<EditableText>(prompt).controller.text,
            'Retain revoked draft',
          );
        } else {
          expect(find.text('Fixture task'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
