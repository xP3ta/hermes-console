// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/cron_repository.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  test(
    'official socket matrix: eight operations, auth, all scope and explicit owner',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final seen = <Map<String, dynamic>>[];
        var rejectUpdate = false;
        final ownerJob = {
          'id': 'fixture-job',
          'profile': 'owner-b',
          'prompt': 'original',
          'schedule': '0 9 * * *',
          'enabled': true,
        };
        server.listen((request) async {
          final body = await utf8.decoder.bind(request).join();
          seen.add({
            'method': request.method,
            'path': request.uri.path,
            'profile': request.uri.queryParameters['profile'],
            'body': body.isEmpty ? null : jsonDecode(body),
            'token': request.headers.value('X-Hermes-Session-Token'),
          });
          request.response.headers.contentType = ContentType.json;
          Object response = ownerJob;
          if (request.headers.value('X-Hermes-Session-Token') !=
              'synthetic-fixture-token') {
            request.response.statusCode = 401;
            response = {'error': 'fixture authentication rejected'};
          } else if (request.uri.path == '/api/cron/jobs' &&
              request.method == 'GET') {
            response = [ownerJob];
          } else if (request.uri.path == '/api/cron/delivery-targets') {
            response = {
              'targets': [
                {'id': 'local', 'name': 'Local'},
                {'id': 'telegram', 'name': 'Telegram'},
              ],
            };
          } else if (request.method == 'PUT' && rejectUpdate) {
            request.response.statusCode = 400;
            response = {
              'error':
                  "context_from job 'missing' not found in profile 'owner-b'",
            };
          } else if (request.method == 'PUT') {
            final updates = (jsonDecode(body) as Map)['updates'] as Map;
            response = {...ownerJob, ...updates, 'schedule': '0 10 * * *'};
          } else if (request.method == 'DELETE') {
            response = {'ok': true, 'deleted': true};
          } else if (request.uri.path.endsWith('/pause')) {
            response = {...ownerJob, 'enabled': false, 'state': 'paused'};
          } else if (request.uri.path.endsWith('/resume')) {
            response = {...ownerJob, 'enabled': true, 'state': 'scheduled'};
          }
          request.response.write(jsonEncode(response));
          await request.response.close();
        });
        final client = DashboardClient(
          host: '127.0.0.1',
          port: server.port,
          manualToken: 'synthetic-fixture-token',
        );
        addTearDown(client.close);
        final repo = CronRepository(client, profile: 'screen-a');
        final active = await repo.listJobsForScope(CronProfileScope.active);
        final all = await repo.listJobsForScope(CronProfileScope.all);
        expect(active.jobs.single.targetProfile, 'owner-b');
        expect(all.jobs.single.sourceProfile, 'owner-b');
        final job = all.jobs.single;
        final targets = await repo.deliveryTargets();
        expect(targets.map((t) => t.id), ['local', 'telegram']);
        await repo.create(
          name: 'Fixture',
          prompt: 'original',
          schedule: '0 9 * * *',
          deliver: 'telegram',
          model: '',
          provider: '',
        );
        final updated = await repo.update(
          job,
          name: 'Changed',
          prompt: 'edited',
          schedule: '0 10 * * *',
          deliver: 'telegram',
          model: '',
          provider: '',
        );
        expect(updated.prompt, 'edited');
        expect(updated.scheduleExpression, '0 10 * * *');
        final paused = await repo.pauseOrResume(job);
        expect(paused.isPaused, isTrue);
        final resumed = await repo.pauseOrResume(paused);
        expect(resumed.isPaused, isFalse);
        await repo.trigger(job);
        await client.deleteCronJob(
          job.id,
          profile: CronRepository.ownerProfileOf(job),
        );
        expect(seen.map((r) => '${r['method']} ${r['path']}').toSet(), {
          'GET /api/cron/jobs',
          'GET /api/cron/delivery-targets',
          'POST /api/cron/jobs',
          'PUT /api/cron/jobs/fixture-job',
          'POST /api/cron/jobs/fixture-job/pause',
          'POST /api/cron/jobs/fixture-job/resume',
          'POST /api/cron/jobs/fixture-job/trigger',
          'DELETE /api/cron/jobs/fixture-job',
        });
        expect(seen[0]['profile'], 'screen-a');
        expect(seen[1]['profile'], 'all');
        expect(seen[3]['profile'], 'screen-a');
        for (final request in seen.skip(4)) {
          expect(request['profile'], 'owner-b');
        }
        expect(
          seen.every((r) => r['token'] == 'synthetic-fixture-token'),
          isTrue,
        );
        expect((seen[4]['body'] as Map).keys, ['updates']);
        rejectUpdate = true;
        await expectLater(
          repo.update(
            job,
            name: 'Rejected',
            prompt: 'invalid execution',
            schedule: '0 9 * * *',
            deliver: 'local',
            model: '',
            provider: '',
          ),
          throwsA(
            isA<DashboardHttpException>().having(
              (e) => e.statusCode,
              'status',
              400,
            ),
          ),
        );
        expect(job.prompt, 'original');
        expect(seen.last['profile'], 'owner-b');
        final before = seen.length;
        final unknown = CronJob.fromJson({
          'id': 'unknown',
          'prompt': 'No owner',
        });
        expect(
          () => repo.trigger(unknown),
          throwsA(isA<CronJobOwnerUnknownException>()),
        );
        expect(seen.length, before);
      }, _RealHttp());
    },
  );

  test('run now on a job that outlasts the wait is a run in progress, not '
      'a failure, and is asked once', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final triggers = <String>[];
      var jobRuns = const Duration(milliseconds: 900);
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/trigger')) {
          triggers.add('${request.method} ${request.uri}');
          // As the server does: the answer comes when the job has finished.
          await Future<void>.delayed(jobRuns);
        }
        request.response.write(
          jsonEncode({
            'id': 'fixture-slow',
            'profile': 'owner-b',
            'prompt': 'slow',
            'schedule': '0 9 * * *',
            'enabled': true,
            'last_run_at': '2026-01-01T00:00:00Z',
          }),
        );
        try {
          await request.response.close();
        } catch (_) {
          // The client stopped waiting.
        }
      });
      final client = DashboardClient(
        host: '127.0.0.1',
        port: server.port,
        manualToken: 'synthetic-fixture-token',
      );
      addTearDown(client.close);
      final repo = CronRepository(
        client,
        profile: 'screen-a',
        triggerWait: const Duration(milliseconds: 150),
      );
      final job = CronJob.fromJson({
        'id': 'fixture-slow',
        'profile': 'owner-b',
        'prompt': 'slow',
        'schedule': '0 9 * * *',
        'enabled': true,
      }).withSourceProfile('owner-b');

      await expectLater(
        repo.trigger(job),
        throwsA(
          isA<CronRunInProgress>().having((e) => e.jobId, 'job', 'fixture-slow'),
        ),
      );
      // The notification "Retry" uses the same route: started is success.
      await repo.triggerById('fixture-slow');
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      // One request each, never repeated on the timeout (a second one would
      // get the server's 409 "already running").
      expect(triggers, [
        'POST /api/cron/jobs/fixture-slow/trigger?profile=owner-b',
        'POST /api/cron/jobs/fixture-slow/trigger?profile=screen-a',
      ]);

      // A job that ends within the wait still returns its result.
      jobRuns = Duration.zero;
      final done = await repo.trigger(job);
      expect(done.id, 'fixture-slow');
      expect(triggers.length, 3);
    }, _RealHttp());
  });

  test('delivery targets and the blueprint catalog are read for the profile '
      'the routine is created in', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = <String>[];
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        seen.add('${request.method} ${request.uri}');
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'targets': [
              {'id': 'local', 'name': 'Local'},
            ],
            'blueprints': <Object>[],
          }),
        );
        await request.response.close();
      });
      final client = DashboardClient(
        host: '127.0.0.1',
        port: server.port,
        manualToken: 'synthetic-fixture-token',
      );
      addTearDown(client.close);

      final scoped = CronRepository(client, profile: 'writer bot');
      expect((await scoped.deliveryTargets()).single.id, 'local');
      await scoped.blueprints();
      final unscoped = CronRepository(client);
      await unscoped.deliveryTargets();
      await unscoped.blueprints();

      expect(seen, [
        'GET /api/cron/delivery-targets?profile=writer+bot',
        'GET /api/cron/blueprints?profile=writer+bot',
        // No profile chosen: the server's own, and the catalog of the
        // profile a blueprint is instantiated into ("default").
        'GET /api/cron/delivery-targets',
        'GET /api/cron/blueprints?profile=default',
      ]);
    }, _RealHttp());
  });
}
