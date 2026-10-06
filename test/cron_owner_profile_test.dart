// Cron actions must target the profile that owns the job, not the profile
// the screen happens to show. Regression: a bot job living in profile
// `radar-bot` was listed in the default-profile Automations view
// (`GET /api/cron/jobs` with no profile lists every profile), and Delete went
// to the default profile, found nothing and was reported as success.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/cron_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _radarJobId = 'a1b2c3d4e5f6';
const _radarJobName = '[bot:radar-bot] Hourly issue and PR triage';
const _radarTitle = 'Hourly issue and PR triage';

Map<String, dynamic> _radarJob({bool annotated = true, bool paused = false}) =>
    {
      'id': _radarJobId,
      'name': _radarJobName,
      'prompt': 'Triage issues and PRs',
      'schedule': {'kind': 'cron', 'expr': '30 18 * * 1-5'},
      'enabled': !paused,
      if (paused) 'state': 'paused',
      if (annotated) 'profile': 'radar-bot',
    };

DashboardClient _client(
  Future<http.Response> Function(http.Request request) handler,
) => DashboardClient(
  host: 'hermes.local',
  port: 9119,
  manualToken: 'dashboard-token',
  httpClientOverride: MockClient(handler),
);

void main() {
  group('CronRepository targets the owner profile', () {
    test('a job listed from the default screen keeps its server profile '
        'and every action sends it', () async {
      final requests = <http.Request>[];
      final client = _client((request) async {
        requests.add(request);
        if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
          return http.Response(jsonEncode([_radarJob()]), 200);
        }
        // Mutation responses from older servers carry no `profile`; this one
        // has no bot prefix either, so only the recorded owner can route
        // the next action.
        return http.Response(
          jsonEncode({..._radarJob(annotated: false), 'name': 'Triage'}),
          200,
        );
      });
      addTearDown(client.close);
      final repo = CronRepository(client);

      final listed = (await repo.listJobsForScope(
        CronProfileScope.active,
      )).jobs.single;
      expect(listed.sourceProfile, 'radar-bot');
      expect(listed.targetProfile, 'radar-bot');

      final paused = await repo.pauseOrResume(listed);
      final triggered = await repo.trigger(paused);
      final edited = await repo.update(
        triggered,
        name: _radarJobName,
        prompt: 'Triage issues and PRs',
        schedule: '0 * * * *',
        deliver: 'local',
        model: '',
        provider: '',
      );
      await repo.getJob(listed.id, profile: listed.targetProfile);

      final actions = requests.skip(1).toList();
      expect(actions.map((r) => r.url.path), [
        '/api/cron/jobs/$_radarJobId/pause',
        '/api/cron/jobs/$_radarJobId/trigger',
        '/api/cron/jobs/$_radarJobId',
        '/api/cron/jobs/$_radarJobId',
      ]);
      for (final request in actions) {
        expect(
          request.url.queryParameters['profile'],
          'radar-bot',
          reason: '${request.method} ${request.url}',
        );
      }
      // The owner survives an unannotated mutation response.
      expect(edited.targetProfile, 'radar-bot');
    });

    test('a bot routine edited from another profile keeps its owner '
        'prefix', () async {
      final requests = <http.Request>[];
      final client = _client((request) async {
        requests.add(request);
        return http.Response(jsonEncode(_radarJob()), 200);
      });
      addTearDown(client.close);
      final repo = CronRepository(client, profile: 'builder', botRoutines: true);
      await repo.update(
        CronJob.fromJson(_radarJob()),
        name: 'Renamed',
        prompt: 'x',
        schedule: '0 * * * *',
        deliver: 'local',
        model: '',
        provider: '',
      );
      final updates = (jsonDecode(requests.single.body) as Map)['updates'];
      expect(updates['name'], '[bot:radar-bot] Renamed');
      expect(requests.single.url.queryParameters['profile'], 'radar-bot');
    });

    test('a named profile listing records that profile', () async {
      final client = _client((request) async {
        return http.Response(
          jsonEncode([
            {'id': 'plain', 'name': 'Plain job', 'prompt': 'x'},
          ]),
          200,
        );
      });
      addTearDown(client.close);
      final job = (await CronRepository(
        client,
        profile: 'work',
      ).listJobsForScope(CronProfileScope.active)).jobs.single;
      expect(job.sourceProfile, 'work');
      expect(job.targetProfile, 'work');
    });

    test('a bot-prefixed job in a merged list without a recorded profile '
        'targets the bot owner', () async {
      final requests = <http.Request>[];
      final client = _client((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode([_radarJob(annotated: false)]),
            200,
          );
        }
        return http.Response(jsonEncode(_radarJob(annotated: false)), 200);
      });
      addTearDown(client.close);
      final repo = CronRepository(client);
      final job = (await repo.listJobsForScope(
        CronProfileScope.all,
      )).jobs.single;
      expect(job.sourceProfile, isNull);
      expect(job.targetProfile, 'radar-bot');

      await repo.pauseOrResume(job);
      expect(requests.last.url.queryParameters['profile'], 'radar-bot');
    });

    test('a merged job with no recorded profile and no bot owner is never '
        'sent to a default profile', () async {
      final requests = <http.Request>[];
      final client = _client((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode([
            {'id': 'orphan', 'name': 'Orphan', 'prompt': 'x'},
          ]),
          200,
        );
      });
      addTearDown(client.close);
      final repo = CronRepository(client, profile: 'work');
      final job = (await repo.listJobsForScope(
        CronProfileScope.all,
      )).jobs.single;
      expect(job.targetProfile, isNull);
      requests.clear();

      await expectLater(
        repo.pauseOrResume(job),
        throwsA(isA<CronJobOwnerUnknownException>()),
      );
      await expectLater(
        repo.trigger(job),
        throwsA(isA<CronJobOwnerUnknownException>()),
      );
      expect(requests, isEmpty);
    });

    test('404 on pause, trigger and edit is a typed not-found error naming '
        'the profile', () async {
      final client = _client((request) async {
        if (request.method == 'GET') {
          return http.Response(jsonEncode([_radarJob()]), 200);
        }
        return http.Response(jsonEncode({'detail': 'Job not found'}), 404);
      });
      addTearDown(client.close);
      final repo = CronRepository(client);
      final job = (await repo.listJobsForScope(
        CronProfileScope.active,
      )).jobs.single;

      Matcher notFound() => throwsA(
        isA<CronJobNotFoundException>().having(
          (e) => e.profile,
          'profile',
          'radar-bot',
        ),
      );
      await expectLater(repo.pauseOrResume(job), notFound());
      await expectLater(repo.trigger(job), notFound());
      await expectLater(
        repo.update(
          job,
          name: _radarJobName,
          prompt: 'x',
          schedule: '0 * * * *',
          deliver: 'local',
          model: '',
          provider: '',
        ),
        notFound(),
      );
    });
  });

  group('DashboardClient.deleteCronJob 404', () {
    test('is not reported as success', () async {
      final client = _client(
        (_) async => http.Response(jsonEncode({'detail': 'Job not found'}), 404),
      );
      addTearDown(client.close);
      await expectLater(
        client.deleteCronJob(_radarJobId, profile: 'radar-bot'),
        throwsA(
          isA<CronJobNotFoundException>().having(
            (e) => e.profile,
            'profile',
            'radar-bot',
          ),
        ),
      );
      await expectLater(
        client.deleteCronJob(_radarJobId),
        throwsA(
          isA<CronJobNotFoundException>().having(
            (e) => e.profile,
            'profile',
            'default',
          ),
        ),
      );
    });
  });

  group('CronScreen on the default profile', () {
    Future<void> pumpScreen(WidgetTester tester, DashboardClient client) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: CronScreen(
            connection: SavedConnection(
              id: 'demo',
              label: 'Demo',
              host: 'hermes.local',
              port: 8642,
              apiKey: 'k',
              useHttps: true,
            ),
            clientOverride: client,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_radarTitle), findsOneWidget);
    }

    Future<void> chooseMenu(WidgetTester tester, String label) async {
      await tester.tap(find.byKey(const ValueKey('cron-job-menu-$_radarJobId')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    testWidgets('delete sends the owner profile, not the screen profile', (
      tester,
    ) async {
      final deletes = <Uri>[];
      var listed = true;
      final client = _client((request) async {
        if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
          return http.Response(jsonEncode(listed ? [_radarJob()] : []), 200);
        }
        if (request.method == 'DELETE') {
          deletes.add(request.url);
          listed = false;
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        return http.Response('not found', 404);
      });
      await pumpScreen(tester, client);

      await chooseMenu(tester, 'Delete');
      await tester.tap(find.byKey(const ValueKey('cron-delete-confirm')));
      await tester.pumpAndSettle();

      expect(deletes, hasLength(1));
      expect(deletes.single.path, '/api/cron/jobs/$_radarJobId');
      expect(deletes.single.queryParameters, {'profile': 'radar-bot'});
      expect(find.text('Deleted "$_radarTitle"'), findsOneWidget);
      expect(find.text(_radarTitle), findsNothing);
    });

    testWidgets('delete 404 shows not-found in the owner profile, refreshes '
        'and never reports success', (tester) async {
      var gets = 0;
      final client = _client((request) async {
        if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
          gets++;
          return http.Response(jsonEncode([_radarJob()]), 200);
        }
        if (request.method == 'DELETE') {
          return http.Response(jsonEncode({'detail': 'Job not found'}), 404);
        }
        return http.Response('not found', 404);
      });
      await pumpScreen(tester, client);
      final getsBefore = gets;

      await chooseMenu(tester, 'Delete');
      await tester.tap(find.byKey(const ValueKey('cron-delete-confirm')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('not found in profile radar-bot'),
        findsOneWidget,
      );
      expect(find.textContaining('Deleted'), findsNothing);
      expect(gets, greaterThan(getsBefore));
      // Still listed by the server, so it stays listed.
      expect(find.text(_radarTitle), findsOneWidget);
    });

    testWidgets('delete 404 drops the row only when the refresh no longer '
        'lists it', (tester) async {
      var listed = true;
      final client = _client((request) async {
        if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
          return http.Response(jsonEncode(listed ? [_radarJob()] : []), 200);
        }
        if (request.method == 'DELETE') {
          listed = false;
          return http.Response(jsonEncode({'detail': 'Job not found'}), 404);
        }
        return http.Response('not found', 404);
      });
      await pumpScreen(tester, client);

      await chooseMenu(tester, 'Delete');
      await tester.tap(find.byKey(const ValueKey('cron-delete-confirm')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('not found in profile radar-bot'),
        findsOneWidget,
      );
      expect(find.textContaining('Deleted'), findsNothing);
      expect(find.text(_radarTitle), findsNothing);
    });

    testWidgets('edit from the detail page reads and writes the owner '
        'profile', (tester) async {
      final requests = <http.Request>[];
      var job = _radarJob(annotated: false);
      final client = _client((request) async {
        requests.add(request);
        final path = request.url.path;
        if (request.method == 'GET' && path == '/api/cron/jobs') {
          return http.Response(jsonEncode([_radarJob()]), 200);
        }
        if (request.method == 'GET' && path == '/api/cron/jobs/$_radarJobId') {
          // Unannotated: the owner must survive the detail refresh.
          return http.Response(jsonEncode(job), 200);
        }
        if (path == '/api/cron/jobs/$_radarJobId/runs') {
          return http.Response(jsonEncode({'runs': []}), 200);
        }
        if (request.method == 'PUT') {
          final updates =
              (jsonDecode(request.body) as Map)['updates'] as Map;
          job = {...job, 'schedule': updates['schedule']};
          return http.Response(jsonEncode(job), 200);
        }
        return http.Response('{}', 404);
      });
      await pumpScreen(tester, client);

      await tester.tap(find.text(_radarTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cron-detail-schedule')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-day-6')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('schedule-apply')));
      await tester.pumpAndSettle();

      final scoped = requests
          .where((r) => r.url.path.startsWith('/api/cron/jobs/$_radarJobId'))
          .toList();
      expect(scoped.where((r) => r.method == 'PUT'), hasLength(1));
      expect(scoped.where((r) => r.method == 'GET'), isNotEmpty);
      for (final request in scoped) {
        expect(
          request.url.queryParameters['profile'],
          'radar-bot',
          reason: '${request.method} ${request.url}',
        );
      }
    });

    for (final action in const [
      ('Pause', 'pause', 'Task paused'),
      ('Run now', 'trigger', 'Run requested'),
    ]) {
      final (label, path, success) = action;
      testWidgets('$path sends the owner profile', (tester) async {
        final posts = <Uri>[];
        final client = _client((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/api/cron/jobs') {
            return http.Response(jsonEncode([_radarJob()]), 200);
          }
          if (request.method == 'POST') {
            posts.add(request.url);
            return http.Response(jsonEncode(_radarJob()), 200);
          }
          return http.Response('not found', 404);
        });
        await pumpScreen(tester, client);

        await chooseMenu(tester, label);

        expect(posts.single.path, '/api/cron/jobs/$_radarJobId/$path');
        expect(posts.single.queryParameters, {'profile': 'radar-bot'});
        expect(find.text(success), findsOneWidget);
      });

      testWidgets('$path 404 shows not-found and refreshes', (tester) async {
        var gets = 0;
        final client = _client((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/api/cron/jobs') {
            gets++;
            return http.Response(jsonEncode([_radarJob()]), 200);
          }
          if (request.method == 'POST') {
            return http.Response(jsonEncode({'detail': 'Job not found'}), 404);
          }
          return http.Response('not found', 404);
        });
        await pumpScreen(tester, client);
        final getsBefore = gets;

        await chooseMenu(tester, label);

        expect(
          find.textContaining('not found in profile radar-bot'),
          findsOneWidget,
        );
        expect(find.text(success), findsNothing);
        expect(gets, greaterThan(getsBefore));
      });
    }
  });
}
