import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/screens/cron_detail_page.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/cron_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Rows as `GET /api/cron/jobs/{id}/runs` serves them: a script-only job's
// per-fire output doc (`_cron_output_run_row` in hermes_cli/web_routers/
// cron.py) next to a real agent run session.
final _runs = <Map<String, dynamic>>[
  {
    'id': 'cron_output:job1:20261004_101500',
    'title': 'Disk report',
    'preview': 'disk usage 41%',
    'source': 'cron_output',
    'started_at': 1790000200,
    'last_active': 1790000200,
    'ended_at': 1790000200,
    'message_count': 0,
    'is_active': false,
  },
  {
    'id': 'cron_job1_20261004_100000',
    'title': 'Agent run',
    'source': 'cron',
    'started_at': 1790000000,
    'ended_at': 1790000100,
    'message_count': 2,
    'is_active': false,
  },
];

void main() {
  testWidgets('script-only output rows are shown but never open a chat', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = DashboardClient(
      host: 'hermes.local',
      manualToken: 'token',
      httpClientOverride: MockClient((request) async {
        final path = request.url.path;
        if (path == '/api/cron/jobs/job1/runs') {
          return http.Response(jsonEncode({'runs': _runs}), 200);
        }
        if (path == '/api/cron/jobs/job1') {
          return http.Response(jsonEncode({'id': 'job1', 'name': 'Job'}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    addTearDown(client.close);
    final opened = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: CronJobDetailPage(
          initialJob: CronJob.fromJson({'id': 'job1', 'name': 'Job'}),
          repository: CronRepository(client),
          readOnly: false,
          connectionId: 'c1',
          profile: '',
          onOpenRun: (Session run) => opened.add(run.id),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final output = find.text('Disk report');
    expect(output, findsOneWidget);
    final taps = tester.widgetList<InkWell>(
      find.ancestor(of: output, matching: find.byType(InkWell)),
    );
    expect(
      taps.where((w) => w.onTap != null || w.onLongPress != null),
      isEmpty,
    );
    await tester.tap(output, warnIfMissed: false);
    await tester.pump();
    expect(opened, isEmpty);

    final s = Strings.of(tester.element(output));
    final agentRun = find.textContaining(s.crnRunCompleted);
    expect(agentRun, findsOneWidget);
    await tester.tap(agentRun);
    await tester.pump();
    expect(opened, ['cron_job1_20261004_100000']);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
