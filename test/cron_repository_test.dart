import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/cron_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('bot routine create and rename retain owning profile and canonical delivery', () async {
    final requests = <http.Request>[];
    final client = DashboardClient(host: 'hermes.local', manualToken: 'token', httpClientOverride: MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode({'id': 'routine', 'name': 'ok'}), 200);
    }));
    addTearDown(client.close);
    final repo = CronRepository(client, profile: 'builder', botRoutines: true);
    final job = await repo.create(name: 'Morning', prompt: 'Check', schedule: 'every 1h', deliver: 'bot-chat', model: '', provider: '');
    await repo.update(job, name: 'Evening', prompt: 'Check', schedule: 'every 2h', deliver: 'bot-chat', model: '', provider: '');
    expect(requests.every((r) => r.url.queryParameters['profile'] == 'builder'), true);
    final created = jsonDecode(requests.first.body) as Map;
    final updated = (jsonDecode(requests.last.body) as Map)['updates'] as Map;
    expect(created['name'], '[bot:builder] Morning'); expect(created['deliver'], 'bot-chat');
    expect(updated['name'], '[bot:builder] Evening'); expect(updated['deliver'], 'bot-chat');
    expect(botRoutineName('builder', '[bot:builder] Existing', ''), '[bot:builder] Existing');
  });

  group('CronJob Desktop parity', () {
    test('explicit state wins and missing state falls back to enabled', () {
      expect(
        CronJob.fromJson({
          'id': 'running',
          'enabled': false,
          'state': 'running',
        }).state,
        CronJobState.running,
      );
      expect(
        CronJob.fromJson({'id': 'off', 'enabled': false}).state,
        CronJobState.disabled,
      );
      expect(
        CronJob.fromJson({'id': 'off', 'enabled': false}).isPaused,
        isTrue,
      );
      expect(
        CronJob.fromJson({'id': 'on', 'enabled': true}).state,
        CronJobState.scheduled,
      );
    });

    test('legacy disabled job resumes instead of pausing again', () async {
      final requests = <Uri>[];
      final client = DashboardClient(
        host: 'hermes.local',
        manualToken: 'token',
        httpClientOverride: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode({
              'id': 'legacy-off',
              'enabled': true,
              'state': 'scheduled',
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final repository = CronRepository(client, profile: 'default');
      final legacy = CronJob.fromJson({'id': 'legacy-off', 'enabled': false});

      await repository.pauseOrResume(legacy);

      expect(requests.single.path, '/api/cron/jobs/legacy-off/resume');
    });

    test(
      'preserves scheduler delivery failure as an operator-visible error',
      () {
        final job = CronJob.fromJson({
          'id': 'delivery-failure',
          'last_status': 'delivery_failed',
          'last_delivery_error': 'destination unavailable',
        });

        expect(job.lastStatus, 'delivery_failed');
        expect(job.lastError, 'destination unavailable');
      },
    );

    test('title follows name, prompt, script and id priority', () {
      expect(
        CronJob.fromJson({
          'id': 'a',
          'name': 'Named task',
          'prompt': 'Prompt',
        }).title,
        'Named task',
      );
      expect(
        CronJob.fromJson({'id': 'b', 'prompt': 'Prompt task'}).title,
        'Prompt task',
      );
      expect(
        CronJob.fromJson({
          'id': 'c',
          'no_agent': true,
          'script': 'backup.sh',
        }).isScriptOnly,
        isTrue,
      );
    });
  });

  test(
    'repository consumes dynamic targets, blueprints and run sessions',
    () async {
      final client = DashboardClient(
        host: 'hermes.local',
        manualToken: 'token',
        httpClientOverride: MockClient((request) async {
          switch (request.url.path) {
            case '/api/cron/delivery-targets':
              return http.Response(
                jsonEncode({
                  'targets': [
                    {'id': 'local', 'name': 'Local', 'home_target_set': true},
                    {
                      'id': 'telegram',
                      'name': 'Telegram',
                      'home_target_set': false,
                      'home_env_var': 'TELEGRAM_HOME_CHANNEL',
                    },
                  ],
                }),
                200,
              );
            case '/api/cron/blueprints':
              return http.Response(
                jsonEncode({
                  'blueprints': [
                    {
                      'key': 'morning-brief',
                      'title': 'Morning brief',
                      'description': 'Daily summary',
                      'fields': [
                        {
                          'name': 'time',
                          'type': 'time',
                          'label': 'Time',
                          'default': '09:00',
                          'options': [],
                          'optional': false,
                          'help': '',
                        },
                      ],
                    },
                  ],
                }),
                200,
              );
            case '/api/model/options':
              return http.Response(jsonEncode({'providers': []}), 200);
            case '/api/cron/jobs/job-1/runs':
              return http.Response(
                jsonEncode({
                  'runs': [
                    {
                      'id': 'cron_job-1_20260801_210000',
                      'title': 'Result',
                      'source': 'cron',
                      'message_count': 2,
                      'started_at': 1770000000,
                      'last_active': 1770000010,
                    },
                  ],
                }),
                200,
              );
            default:
              return http.Response('{}', 404);
          }
        }),
      );
      addTearDown(client.close);
      final repository = CronRepository(client, profile: 'default');

      final resources = await repository.editorResources();
      expect(resources.deliveryTargets.map((target) => target.id), [
        'local',
        'telegram',
      ]);
      expect(resources.deliveryTargets.last.homeTargetSet, isFalse);
      expect(resources.blueprints.single.key, 'morning-brief');
      expect(resources.blueprints.single.initialValues()['time'], '09:00');

      final runs = await repository.listRuns('job-1');
      expect(runs.available, isTrue);
      expect(runs.sessions.single.id, 'cron_job-1_20260801_210000');
      expect(runs.sessions.single.displayTitle, 'Result');
    },
  );

  test(
    'all profile scope is read-only query state, not mutation state',
    () async {
      final requests = <Uri>[];
      final client = DashboardClient(
        host: 'hermes.local',
        manualToken: 'token',
        httpClientOverride: MockClient((request) async {
          requests.add(request.url);
          if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
            return http.Response(
              jsonEncode([
                {
                  'id': 'all-job',
                  'name': 'All profiles',
                  'profile': 'research',
                  'enabled': true,
                },
              ]),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/api/cron/jobs/all-job/pause') {
            return http.Response(
              jsonEncode({
                'id': 'all-job',
                'name': 'All profiles',
                'profile': 'research',
                'state': 'paused',
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );
      addTearDown(client.close);
      final repository = CronRepository(client, profile: 'work profile');

      final listing = await repository.listJobsForScope(CronProfileScope.all);
      expect(listing.usedLegacyActiveFallback, isFalse);
      expect(listing.jobs.single.profile, 'research');
      expect(requests.single.queryParameters['profile'], 'all');

      await repository.pauseOrResume(listing.jobs.single);
      expect(requests.last.queryParameters['profile'], 'work profile');
      expect(requests.last.queryParameters['profile'], isNot('all'));
    },
  );

  test(
    'all profile scope falls back to the active profile on legacy servers',
    () async {
      final requestedProfiles = <String?>[];
      final client = DashboardClient(
        host: 'hermes.local',
        manualToken: 'token',
        httpClientOverride: MockClient((request) async {
          if (request.method != 'GET' || request.url.path != '/api/cron/jobs') {
            return http.Response('{}', 404);
          }
          final profile = request.url.queryParameters['profile'];
          requestedProfiles.add(profile);
          if (profile == 'all') return http.Response('{}', 422);
          return http.Response(
            jsonEncode([
              {'id': 'legacy-job', 'profile': profile, 'enabled': true},
            ]),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final repository = CronRepository(client, profile: 'default');

      final listing = await repository.listJobsForScope(CronProfileScope.all);

      expect(requestedProfiles, ['all', 'default']);
      expect(listing.usedLegacyActiveFallback, isTrue);
      expect(listing.jobs.single.id, 'legacy-job');
    },
  );
}
