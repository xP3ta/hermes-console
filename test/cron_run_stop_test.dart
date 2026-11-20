// Stop for a cron job's live run, as Desktop does it
// (apps/desktop/src/app/cron/use-cron-run-stop.ts): POST /cancel in the
// job's profile, "Stopping…" until the job list shows that attempt
// finished, and the list read again while a run started here is live.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/screens/cron_detail_page.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/cron_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/quiet_feedback.dart';

const _reason = 'cancelled on request (Stop)';

/// Desktop `LIVE_RUN_POLL_MS`: how often a live run is read again.
const _livePoll = Duration(milliseconds: 1500);

Map<String, dynamic> _execution(String id, String status, {String? error}) =>
    {
      'id': id,
      'job_id': 'job1',
      'status': status,
      'claimed_at': '2026-11-19T10:00:00+00:00',
      'error': ?error,
    };

/// The job list as the server serves it (cron/jobs.py `list_jobs`): the
/// newest attempt and the live one ride along with each job.
class _Server {
  final requests = <http.Request>[];
  Map<String, dynamic>? latest;
  Map<String, dynamic>? live;
  Map<String, dynamic> cancelReply = const {
    'success': true,
    'cancelled': true,
    'execution_id': 'exec-1',
    'job_id': 'job1',
  };
  int cancelStatus = 200;

  /// What the trigger route does before it answers: claim the run.
  void Function()? onTrigger;
  Duration triggerTakes = Duration.zero;

  void running(String id) {
    latest = _execution(id, 'running');
    live = _execution(id, 'running');
  }

  void ended(String id, String status, {String? error}) {
    latest = _execution(id, status, error: error);
    live = null;
  }

  Map<String, dynamic> job() => {
    'id': 'job1',
    'name': 'Nightly digest',
    'prompt': 'Summarise the day',
    'schedule': {'kind': 'cron', 'expr': '0 21 * * *', 'display': '0 21 * * *'},
    'enabled': true,
    'state': 'scheduled',
    'deliver': 'local',
    'profile': 'radar-bot',
    'latest_execution': latest,
    'live_execution': live,
  };

  /// The job read alone (cron/jobs.py `get_job`): no ledger.
  Map<String, dynamic> single() =>
      job()..remove('latest_execution')..remove('live_execution');

  List<String> calls(String method, String path) => [
    for (final r in requests)
      if (r.method == method && r.url.path == path)
        '${r.method} ${r.url.path}'
            '${r.url.hasQuery ? '?${r.url.query}' : ''}',
  ];

  int get listReads => calls('GET', '/api/cron/jobs').length;

  DashboardClient client() => DashboardClient(
    host: 'hermes.local',
    manualToken: 'token',
    httpClientOverride: MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (request.method == 'GET' && path == '/api/cron/jobs') {
        return http.Response(jsonEncode([job()]), 200);
      }
      if (request.method == 'GET' && path == '/api/cron/jobs/job1') {
        return http.Response(jsonEncode(single()), 200);
      }
      if (path == '/api/cron/jobs/job1/runs') {
        return http.Response(jsonEncode({'runs': []}), 200);
      }
      if (request.method == 'POST' && path == '/api/cron/jobs/job1/cancel') {
        return http.Response(jsonEncode(cancelReply), cancelStatus);
      }
      if (request.method == 'POST' && path == '/api/cron/jobs/job1/trigger') {
        onTrigger?.call();
        await Future<void>.delayed(triggerTakes);
        return http.Response(jsonEncode(single()), 200);
      }
      if (path == '/api/model/options' || path == '/api/cron/blueprints') {
        return http.Response('{}', 200);
      }
      return http.Response('{}', 404);
    }),
  );
}

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: home,
);

Future<void> _pumpDetail(WidgetTester tester, _Server server) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final client = server.client();
  addTearDown(client.close);
  await tester.pumpWidget(
    _app(
      CronJobDetailPage(
        initialJob: CronJob.fromJson(server.job()),
        repository: CronRepository(client, profile: 'radar-bot'),
        readOnly: false,
        connectionId: 'c1',
        profile: 'radar-bot',
        onOpenRun: (Session _) {},
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

final _stop = find.byKey(const ValueKey('cron-detail-stop'));
final _runNow = find.byKey(const ValueKey('cron-detail-run'));
final _lastCancelled = find.byKey(const ValueKey('cron-detail-last-cancelled'));

HermesActionButton _stopButton(WidgetTester tester) =>
    tester.widget<HermesActionButton>(_stop);

Finder _status(String label) => find.descendant(
  of: find.byKey(const ValueKey('cron-detail-status')),
  matching: find.textContaining(label, findRichText: true),
);

void main() {
  testWidgets('Stop cancels the live run in its profile and says Stopping… '
      'until the list shows that attempt cancelled', (tester) async {
    final server = _Server()..running('exec-1');
    await _pumpDetail(tester, server);

    expect(_status('Running'), findsOneWidget);
    expect(_stop, findsOneWidget);
    expect(_runNow, findsNothing);
    expect(_stopButton(tester).label, 'Stop');

    await tester.tap(_stop);
    await tester.pump();
    await tester.pump();
    expect(server.calls('POST', '/api/cron/jobs/job1/cancel'), [
      'POST /api/cron/jobs/job1/cancel?profile=radar-bot',
    ]);
    // The run books its cancel at its next check: still running for now.
    expect(_stopButton(tester).label, 'Stopping…');
    expect(_stopButton(tester).onPressed, isNull);
    await tester.pump(_livePoll);
    await tester.pump();
    expect(_stopButton(tester).label, 'Stopping…');
    tester.takeAnnouncements();

    server.ended('exec-1', 'cancelled', error: _reason);
    await tester.pump(_livePoll);
    await tester.pump();
    await tester.pump();

    expect(_stop, findsNothing);
    expect(_runNow, findsOneWidget);
    expect(_status('Running'), findsNothing);
    expect(
      find.descendant(
        of: _lastCancelled,
        matching: find.textContaining(_reason),
      ),
      findsOneWidget,
    );
    expectRoutineFeedback(tester, 'Run cancelled');
    // Only one cancel was ever sent, and the fast reads stop with the run.
    expect(server.calls('POST', '/api/cron/jobs/job1/cancel'), hasLength(1));
    await tester.pump();
    final reads = server.listReads;
    await tester.pump(_livePoll * 4);
    expect(server.listReads, reads);
  });

  testWidgets('a run that ends on its own first is reported as finished, and '
      'a newer run does not keep the Stop pending', (tester) async {
    final server = _Server()..running('exec-1');
    await _pumpDetail(tester, server);

    await tester.tap(_stop);
    await tester.pump();
    server.ended('exec-1', 'completed');
    await tester.pump(_livePoll);
    await tester.pump();
    await tester.pump();
    expect(_stop, findsNothing);
    expect(_lastCancelled, findsNothing);
    expectRoutineFeedback(tester, 'Run finished before it could stop');

    // A second run starts; a Stop of it ends when a third has replaced it:
    // the targeted attempt is gone, so the Stop settles and the newer run
    // can be stopped again.
    server.running('exec-2');
    server.cancelReply = {'cancelled': true, 'execution_id': 'exec-2'};
    await tester.pump(cronDetailRefreshInterval);
    await tester.pump();
    await tester.pump();
    expect(_stopButton(tester).label, 'Stop');
    await tester.tap(_stop);
    await tester.pump();
    server.running('exec-3');
    await tester.pump(_livePoll);
    await tester.pump();
    await tester.pump();
    expectRoutineFeedback(tester, 'Run cancelled');
    expect(_stopButton(tester).label, 'Stop');
    expect(_stopButton(tester).onPressed, isNotNull);
  });

  testWidgets('nothing in flight and a refused cancel each end the Stop',
      (tester) async {
    final server = _Server()..running('exec-1');
    await _pumpDetail(tester, server);

    // The run ended between the last read and the tap.
    server.cancelReply = {'cancelled': false, 'execution_id': null};
    server.ended('exec-1', 'completed');
    await tester.tap(_stop);
    await tester.pump();
    await tester.pump();
    expectRoutineFeedback(tester, 'No run in flight');
    await tester.pump();
    expect(_stop, findsNothing);
    expect(_runNow, findsOneWidget);

    server.running('exec-2');
    server.cancelStatus = 500;
    await tester.pump(cronDetailRefreshInterval);
    await tester.pump();
    await tester.pump();
    await tester.tap(_stop);
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(HermesNoticeCard),
        matching: find.textContaining('Could not stop the run'),
      ),
      findsOneWidget,
    );
    expect(_stopButton(tester).label, 'Stop');
    expect(_stopButton(tester).onPressed, isNotNull);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('Run now that outlasts the wait shows the job running, reads '
      'the list until it ends, and Stop goes to the job profile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final server = _Server()..triggerTakes = const Duration(minutes: 5);
    // The trigger route claims the run before it starts it.
    server.onTrigger = () => server.running('exec-1');
    await tester.pumpWidget(
      _app(
        CronScreen(
          connection: SavedConnection(
            id: 'cron-stop',
            label: 'QA',
            host: 'hermes.local',
            port: 8642,
            apiKey: 'k',
            useHttps: true,
          ),
          clientOverride: server.client(),
          profileOverride: 'radar-bot',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('cron-job-job1'));
    Finder rowStatus(String label) => find.descendant(
      of: row,
      matching: find.textContaining(label, findRichText: true),
    );
    expect(rowStatus('Running'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('cron-job-menu-job1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run now'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    await tester.pump();
    expect(server.calls('POST', '/api/cron/jobs/job1/trigger'), hasLength(1));
    expect(rowStatus('Running'), findsOneWidget);

    // Read again while the run is live.
    var reads = server.listReads;
    await tester.pump(_livePoll);
    await tester.pump();
    expect(server.listReads, greaterThan(reads));
    reads = server.listReads;
    await tester.pump(_livePoll);
    await tester.pump();
    expect(server.listReads, greaterThan(reads));

    await tester.tap(find.byKey(const ValueKey('cron-job-menu-job1')));
    await tester.pumpAndSettle();
    expect(find.text('Run now'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('cron-job-stop-job1')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(server.calls('POST', '/api/cron/jobs/job1/cancel'), [
      'POST /api/cron/jobs/job1/cancel?profile=radar-bot',
    ]);
    tester.takeAnnouncements();

    server.ended('exec-1', 'cancelled', error: _reason);
    await tester.pump(_livePoll);
    await tester.pump();
    await tester.pump();
    expect(rowStatus('Running'), findsNothing);
    expectRoutineFeedback(tester, 'Run cancelled');

    // Settled: no more fast reads.
    reads = server.listReads;
    await tester.pump(_livePoll * 4);
    expect(server.listReads, reads);
    expect(server.calls('POST', '/api/cron/jobs/job1/trigger'), hasLength(1));
    await tester.pump(const Duration(minutes: 5));
  });
}
