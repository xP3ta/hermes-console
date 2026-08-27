import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Desktop event contract keeps a 60 second polling backstop', () {
    expect(cronBackstopRefreshInterval, const Duration(seconds: 60));
    expect(
      isCronRefreshEvent(
        const TuiGatewayEvent(type: 'cron.changed', sessionId: '', payload: {}),
      ),
      isTrue,
    );
    expect(
      isCronRefreshEvent(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      ),
      isTrue,
    );
    expect(
      isCronRefreshEvent(
        const TuiGatewayEvent(
          type: 'message.delta',
          sessionId: '',
          payload: {},
        ),
      ),
      isFalse,
    );
  });

  test('cleanup conserva el gate compartido de App Lock', () {
    final source = File('lib/core/screens/cron_screen.dart').readAsStringSync();
    expect(source, contains('authorizeHistoryCleanup('));
  });

  testWidgets('manual editor uses backend catalogs and Desktop payload', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, dynamic>? createdBody;
    final client = DashboardClient(
      host: 'hermes.local',
      manualToken: 'token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
          return http.Response('[]', 200);
        }
        if (request.url.path == '/api/cron/delivery-targets') {
          return http.Response(
            jsonEncode({
              'targets': [
                {'id': 'local', 'name': 'Local', 'home_target_set': true},
                {'id': 'telegram', 'name': 'Telegram', 'home_target_set': true},
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/model/options') {
          return http.Response(
            jsonEncode({
              'providers': [
                {
                  'slug': 'nous',
                  'name': 'Nous',
                  'authenticated': true,
                  'models': ['Hermes-4'],
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/cron/blueprints') {
          return http.Response(
            jsonEncode({
              'blueprints': [
                {
                  'key': 'brief',
                  'title': 'Morning brief',
                  'description': 'A ready-made brief',
                  'fields': [],
                },
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path == '/api/cron/jobs') {
          createdBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'created',
              'prompt': createdBody!['prompt'],
              'schedule': createdBody!['schedule'],
              'deliver': createdBody!['deliver'],
              'enabled': true,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: CronScreen(
          connection: SavedConnection(
            id: 'cron-parity',
            label: 'QA',
            host: 'hermes.local',
            port: 8642,
            apiKey: 'gateway-key',
            useHttps: true,
          ),
          clientOverride: client,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'New task'));
    await tester.pumpAndSettle();

    expect(find.text('Start from'), findsOneWidget);
    expect(find.text('Save on the server only'), findsOneWidget);
    expect(find.text('Server default'), findsOneWidget);
    expect(find.text('Direct command (no AI)'), findsNothing);

    final promptField = find.descendant(
      of: find.byKey(const ValueKey('cron-prompt-field')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(promptField, 'Summarize the day');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(createdBody, isNotNull);
    expect(createdBody!['prompt'], 'Summarize the day');
    expect(createdBody!['schedule'], '0 9 * * *');
    expect(createdBody!['deliver'], 'local');
    expect(createdBody!.containsKey('name'), isFalse);
    expect(createdBody!.containsKey('no_agent'), isFalse);
    expect(createdBody!.containsKey('model'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile all widens only GET and hides every mutation control', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final requestedProfiles = <String?>[];
    final client = DashboardClient(
      host: 'hermes.local',
      manualToken: 'token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
          final profile = request.url.queryParameters['profile'];
          requestedProfiles.add(profile);
          return http.Response(
            jsonEncode([
              {
                'id': profile == 'all' ? 'all-job' : 'active-job',
                'name': profile == 'all' ? 'Other profile job' : 'Active job',
                'profile': profile == 'all' ? 'research' : 'default',
                'schedule': '0 9 * * *',
                'enabled': true,
              },
            ]),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: CronScreen(
          connection: SavedConnection(
            id: 'cron-profile-scope',
            label: 'QA',
            host: 'hermes.local',
            port: 8642,
            apiKey: 'gateway-key',
            useHttps: true,
          ),
          clientOverride: client,
          profileOverride: 'research',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(requestedProfiles.first, 'research');
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('cron-job-menu-active-job')),
      findsOneWidget,
    );

    await tester.tap(find.text('all'));
    await tester.pumpAndSettle();

    expect(requestedProfiles.last, 'all');
    expect(find.text('Other profile job'), findsOneWidget);
    expect(find.text('profile: research'), findsOneWidget);
    // HermesPill presents status labels in its canonical uppercase style.
    expect(find.text('READ ONLY'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(find.byKey(const ValueKey('cron-job-menu-all-job')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cron and session events refresh while unrelated events do not', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var reads = 0;
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final client = DashboardClient(
      host: 'hermes.local',
      manualToken: 'token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
          reads++;
          return http.Response(
            jsonEncode([
              {'id': 'job-$reads', 'name': 'Revision $reads', 'enabled': true},
            ]),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: CronScreen(
          connection: SavedConnection(
            id: 'cron-events',
            label: 'QA',
            host: 'hermes.local',
            port: 8642,
            apiKey: 'gateway-key',
            useHttps: true,
          ),
          clientOverride: client,
          eventStreamOverride: events.stream,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reads, 1);

    events.add(
      const TuiGatewayEvent(type: 'message.delta', sessionId: '', payload: {}),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(reads, 1);

    events.add(
      const TuiGatewayEvent(type: 'cron.changed', sessionId: '', payload: {}),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(reads, 2);
    expect(find.text('Revision 2'), findsOneWidget);

    events.add(
      const TuiGatewayEvent(
        type: 'sessions.changed',
        sessionId: '',
        payload: {},
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(reads, 3);
    expect(find.text('Revision 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cleanup confirms the count, cancel is inert and schedules stay intact',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var sessionReads = 0;
      var bulkDeletes = 0;
      var cronDeletes = 0;
      final invalidations = <HistoryCleanupInvalidation>[];
      final invalidationSubscription = historyCleanupInvalidations.events
          .where((event) => event.connectionId == 'cron-cleanup')
          .listen(invalidations.add);
      addTearDown(invalidationSubscription.cancel);
      final client = DashboardClient(
        host: 'hermes.local',
        manualToken: 'token',
        httpClientOverride: MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
            return http.Response('[]', 200);
          }
          if (request.method == 'GET' && request.url.path == '/api/sessions') {
            sessionReads++;
            final rows = sessionReads <= 3
                ? [
                    {
                      'id': 'cron_a_20260807_090000',
                      'source': 'cron',
                      'started_at': 1770000000,
                      'ended_at': 1770000010,
                      'last_active': 1770000010,
                      'is_active': false,
                    },
                    {
                      'id': 'cron_b_20260807_090100',
                      'source': 'cron',
                      'started_at': 1770000000,
                      'ended_at': 1770000010,
                      'last_active': 1770000010,
                      'is_active': false,
                    },
                  ]
                : const <Map<String, dynamic>>[];
            return http.Response(
              jsonEncode({'sessions': rows, 'total': rows.length}),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/api/sessions/bulk-delete') {
            bulkDeletes++;
            return http.Response(jsonEncode({'ok': true, 'deleted': 2}), 200);
          }
          if (request.method == 'DELETE' &&
              request.url.path.startsWith('/api/cron/jobs')) {
            cronDeletes++;
          }
          return http.Response('{}', 404);
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: CronScreen(
            connection: SavedConnection(
              id: 'cron-cleanup',
              label: 'QA',
              host: 'hermes.local',
              port: 8642,
              apiKey: 'gateway-key',
              useHttps: true,
            ),
            clientOverride: client,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('cron-cleanup-conversations')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Se borrarán 2 resultados'), findsOneWidget);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(bulkDeletes, 0);
      expect(invalidations, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey('cron-cleanup-conversations')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('cron-cleanup-confirm')));
      await tester.pumpAndSettle();

      expect(bulkDeletes, 1);
      expect(cronDeletes, 0);
      expect(find.text('Conversaciones de Cron borradas: 2.'), findsOneWidget);
      expect(invalidations.map((event) => event.scope), [
        HistoryCleanupScope.cronResults,
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cleanup bloquea el doble toque antes de verificar App Lock', (
    tester,
  ) async {
    final verification = Completer<bool>();
    var verificationCalls = 0;
    var sessionReads = 0;
    final client = DashboardClient(
      host: 'hermes.local',
      manualToken: 'token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
          return http.Response('[]', 200);
        }
        if (request.method == 'GET' && request.url.path == '/api/sessions') {
          sessionReads++;
          return http.Response('{"sessions": [], "total": 0}', 200);
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: CronScreen(
          connection: SavedConnection(
            id: 'cron-double-tap',
            label: 'QA',
            host: 'hermes.local',
            port: 8642,
            apiKey: 'gateway-key',
            useHttps: true,
          ),
          clientOverride: client,
          verifyHistoryCleanupForTesting: () {
            verificationCalls++;
            return verification.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final cleanup = find.byKey(const ValueKey('cron-cleanup-conversations'));
    await tester.tap(cleanup);
    await tester.tap(cleanup);
    verification.complete(false);
    await tester.pump();
    await tester.pump();

    expect(verificationCalls, 1);
    expect(sessionReads, 0);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cleanup is disabled for a read-only connection', (tester) async {
    final client = DashboardClient(
      host: 'hermes.local',
      manualToken: 'token',
      httpClientOverride: MockClient((request) async {
        if (request.url.path == '/api/cron/jobs') {
          return http.Response('[]', 200);
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: CronScreen(
          connection: SavedConnection(
            id: 'cron-cleanup-read-only',
            label: 'QA',
            host: 'hermes.local',
            port: 8642,
            apiKey: 'gateway-key',
            useHttps: true,
            readOnly: true,
          ),
          clientOverride: client,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final action = tester.widget<IconButton>(
      find.byKey(const ValueKey('cron-cleanup-conversations')),
    );
    expect(action.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
