import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

SavedConnection _connection() => SavedConnection(
  id: 'cron-spec-046',
  label: 'QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'gateway-key',
  useHttps: true,
);

Map<String, dynamic> _job() => {
  'id': 'nightly-report',
  'name': 'Nightly report',
  'schedule': '0 2 * * *',
  'prompt': 'Summarize the workspace',
  'enabled': true,
  'last_status': 'success',
  'delivery': 'origin',
  'model': 'model-a',
  'provider': 'provider-a',
  'context': 'workspace',
  'workdir': '/srv/project',
};

Widget _host(DashboardClient client, {String? initialJobId}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: CronScreen(
    connection: _connection(),
    clientOverride: client,
    initialJobId: initialJobId,
  ),
);

void main() {
  testWidgets('linked cron opens the same core metadata as Desktop', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = DashboardClient(
      host: 'hermes.local',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient((request) async {
        if (request.url.path == '/api/cron/jobs') {
          return http.Response(jsonEncode([_job()]), 200);
        }
        if (request.url.path == '/api/cron/jobs/nightly-report') {
          return http.Response(jsonEncode(_job()), 200);
        }
        if (request.url.path == '/api/cron/jobs/nightly-report/runs') {
          return http.Response(jsonEncode({'runs': []}), 200);
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(_host(client, initialJobId: 'nightly-report'));
    await tester.pumpAndSettle();

    expect(find.text('Nightly report'), findsWidgets);
    expect(find.text('Destination'), findsOneWidget);
    expect(find.text('Chat it was created in'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('model-a'), findsOneWidget);
    expect(find.textContaining('provider-a'), findsNothing);
    expect(find.text('workspace'), findsNothing);
    expect(find.textContaining('/srv/project'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cron uses Desktop fallback polling and refreshes on foreground',
    (tester) async {
      var reads = 0;
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        manualToken: 'dashboard-token',
        httpClientOverride: MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
            reads += 1;
            return http.Response(jsonEncode([_job()]), 200);
          }
          return http.Response('{}', 404);
        }),
      );

      await tester.pumpWidget(_host(client));
      await tester.pumpAndSettle();
      expect(reads, 1);

      await tester.pump(cronBackstopRefreshInterval);
      expect(reads, 2);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(reads, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cron backstop sleeps in background and restarts from the resume refresh',
    (tester) async {
      var reads = 0;
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        manualToken: 'dashboard-token',
        httpClientOverride: MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
            reads += 1;
            return http.Response(jsonEncode([_job()]), 200);
          }
          return http.Response('{}', 404);
        }),
      );

      await tester.pumpWidget(_host(client));
      await tester.pumpAndSettle();
      expect(reads, 1);

      await tester.pump(const Duration(seconds: 30));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 50));
      expect(reads, 1, reason: 'no refresh while the app is in background');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(reads, 2, reason: 'resume refreshes at once');

      // The old background-phase tick (t=120 s) must not add a redundant read
      // 40 s after the resume refresh; the next backstop is a full interval.
      await tester.pump(const Duration(seconds: 45));
      expect(reads, 2);
      await tester.pump(const Duration(seconds: 20));
      expect(reads, 3);
      expect(tester.takeException(), isNull);
    },
  );
}
