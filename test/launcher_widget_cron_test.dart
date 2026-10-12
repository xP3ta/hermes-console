import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/models/launcher_widget_cron.dart';
import 'package:hermes_android/core/services/launcher_widget_cron.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';

class _Store implements LauncherWidgetSectionStore {
  final values = <String, String>{};
  final redraws = <String>[];
  bool failWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('launcher unavailable');
    values[key] = value;
  }

  @override
  Future<void> redraw(String qualifiedAndroidName) async {
    redraws.add(qualifiedAndroidName);
  }
}

CronJob _job(
  String id, {
  String? name,
  Object? next,
  Object? last,
  String status = '',
  String? state,
  String? profile,
  bool enabled = true,
}) => CronJob.fromJson({
  'id': id,
  'name': name ?? 'Job $id',
  'next_run_at': ?next,
  'last_run_at': ?last,
  'last_status': status,
  'state': ?state,
  'profile': ?profile,
  'enabled': enabled,
});

const _t0 = 1760000000000; // a fixed "now"

void main() {
  group('times and results as the server sends them', () {
    test('ISO strings, epoch seconds and epoch milliseconds are one time', () {
      final iso = DateTime.utc(2026, 10, 12, 15).toIso8601String();
      final ms = DateTime.utc(2026, 10, 12, 15).millisecondsSinceEpoch;
      expect(launcherWidgetEpochMs(iso), ms);
      expect(launcherWidgetEpochMs(ms ~/ 1000), ms);
      expect(launcherWidgetEpochMs(ms / 1000), ms);
      expect(launcherWidgetEpochMs(ms), ms);
      expect(launcherWidgetEpochMs('${ms ~/ 1000}'), ms);
      for (final nothing in [null, '', '  ', 'soon', 0, -5, double.nan]) {
        expect(launcherWidgetEpochMs(nothing), isNull, reason: '$nothing');
      }
    });

    test('a failed last run is failed however the server words it', () {
      for (final status in ['error', 'failed', 'failure', 'delivery_failed']) {
        expect(
          launcherWidgetCronResult(_job('a', status: status)),
          LauncherWidgetCronResult.failed,
          reason: status,
        );
      }
      expect(
        launcherWidgetCronResult(_job('a', status: 'ok', state: 'error')),
        LauncherWidgetCronResult.failed,
      );
      expect(
        launcherWidgetCronResult(_job('a', status: 'ok')),
        LauncherWidgetCronResult.ok,
      );
      expect(
        launcherWidgetCronResult(_job('a', state: 'running')),
        LauncherWidgetCronResult.running,
      );
      // Never ran: no result, not a success.
      expect(
        launcherWidgetCronResult(_job('a')),
        LauncherWidgetCronResult.none,
      );
    });

    test('a job carries its name, its times and a link the app accepts', () {
      final job = launcherWidgetCronJob(
        'conn-1',
        _job(
          'job-7',
          name: '[bot:forja] Salida RRHH',
          next: _t0 ~/ 1000 + 3600,
          last: _t0 ~/ 1000 - 86400,
          status: 'ok',
          profile: 'forja',
        ),
      );
      // The technical "[bot:…]" prefix never reaches a home screen.
      expect(job.name, 'Salida RRHH');
      expect(job.profile, 'forja');
      expect(job.nextRunAtMs, _t0 + 3600000);
      expect(job.lastRunAtMs, _t0 - 86400000);
      expect(job.last, LauncherWidgetCronResult.ok);
      final open = NotificationOpen.tryParse(job.openPayload)!;
      expect(open.connId, 'conn-1');
      expect(open.jobId, 'job-7');
      expect(open.profile, 'forja');
      expect(open.sessionId, isEmpty);

      // The default store needs no profile in its link.
      final plain = launcherWidgetCronJob('conn-1', _job('j', profile: ''));
      expect(plain.profile, 'default');
      expect(NotificationOpen.tryParse(plain.openPayload)!.profile, isNull);

      // A paused job has no next run to announce.
      final paused = launcherWidgetCronJob(
        'conn-1',
        _job('p', next: _t0 ~/ 1000 + 60, state: 'paused'),
      );
      expect(paused.paused, isTrue);
      expect(paused.nextRunAtMs, isNull);

      // An id the app would not accept back gets no link (a tap opens the app).
      final odd = launcherWidgetCronJob('conn-1', _job('bad id/..'));
      expect(odd.openPayload, isNull);
    });
  });

  group('the stored section', () {
    LauncherWidgetCronJob job(
      String id, {
      int? next,
      String profile = 'default',
      LauncherWidgetCronResult last = LauncherWidgetCronResult.ok,
    }) => LauncherWidgetCronJob(
      id: id,
      name: 'Job $id',
      profile: profile,
      nextRunAtMs: next,
      last: last,
    );

    test('it survives a round trip and is versioned', () {
      final snapshot = LauncherWidgetCronSnapshot(
        connectionId: 'conn-1',
        updatedAtMs: _t0,
        jobs: [
          LauncherWidgetCronJob(
            id: 'a',
            name: 'Salida RRHH',
            profile: 'default',
            nextRunAtMs: _t0 + 1000,
            lastRunAtMs: _t0 - 1000,
            last: LauncherWidgetCronResult.failed,
            openPayload: '{"conn":"conn-1","jid":"a","surface":"normal"}',
          ),
          const LauncherWidgetCronJob(
            id: 'b',
            name: 'En pausa',
            profile: 'forja',
            paused: true,
          ),
        ],
      );
      final decoded = LauncherWidgetCronSnapshot.tryDecode(snapshot.encode())!;
      expect(decoded.connectionId, 'conn-1');
      expect(decoded.updatedAtMs, _t0);
      expect(decoded.content, snapshot.content);
      expect(decoded.jobs.first.last, LauncherWidgetCronResult.failed);
      expect(decoded.jobs.last.paused, isTrue);
      expect(decoded.jobs.last.nextRunAtMs, isNull);
      expect(decoded.failedCount, 1);
      expect(jsonDecode(snapshot.encode())['schema_version'], 1);
      expect(LauncherWidgetCronSnapshot.storageKey, 'hermes_widget_cron_v1');
    });

    test('anything that is not this schema reads as nothing, never throws', () {
      for (final raw in <Object?>[
        null,
        '',
        'not json',
        '[]',
        '{"schema_version":2,"conn_id":"c","jobs":[]}',
        '{"schema_version":1,"jobs":[]}',
        42,
      ]) {
        expect(
          LauncherWidgetCronSnapshot.tryDecode(raw),
          isNull,
          reason: '$raw',
        );
      }
      // Unknown fields and broken jobs are skipped; the rest is kept.
      final tolerant = LauncherWidgetCronSnapshot.tryDecode(
        jsonEncode({
          'schema_version': 1,
          'conn_id': 'c',
          'updated_at_ms': _t0,
          'later_field': {'x': 1},
          'jobs': [
            {'id': 'ok', 'name': 'Bien', 'last': 'a-new-word', 'extra': true},
            {'id': 'no-name'},
            'nonsense',
          ],
        }),
      )!;
      expect(tolerant.jobs.map((j) => j.id), ['ok']);
      expect(tolerant.jobs.single.last, LauncherWidgetCronResult.none);
    });

    test('jobs are listed by next run, the ones without one last', () {
      final ordered = LauncherWidgetCronSnapshot.ordered([
        job('paused'),
        job('late', next: _t0 + 9000),
        job('soon', next: _t0 + 1000),
        job('mid', next: _t0 + 5000),
      ]);
      expect(ordered.map((j) => j.id), ['soon', 'mid', 'late', 'paused']);
    });

    test('a failed job is never the one that does not fit', () {
      final many = [
        for (var i = 0; i < LauncherWidgetCronSnapshot.maxJobs + 6; i++)
          job('j$i', next: _t0 + i * 1000),
        job('broken', last: LauncherWidgetCronResult.failed),
      ];
      final kept = LauncherWidgetCronSnapshot.ordered(many);
      expect(kept, hasLength(LauncherWidgetCronSnapshot.maxJobs));
      expect(kept.map((j) => j.id), contains('broken'));
    });

    test('one profile\'s listing only replaces that profile\'s jobs', () {
      final all = LauncherWidgetCronSnapshot.merged(
        previous: null,
        connectionId: 'conn-1',
        nowMs: _t0,
        listed: [
          job('d1', next: _t0 + 1000),
          job('f1', next: _t0 + 2000, profile: 'forja'),
        ],
        profile: null,
      );
      expect(all.jobs.map((j) => j.id), ['d1', 'f1']);

      // The Cron screen of the default profile, later: Forja's job stays.
      final one = LauncherWidgetCronSnapshot.merged(
        previous: all,
        connectionId: 'conn-1',
        nowMs: _t0 + 60000,
        listed: [job('d2', next: _t0 + 500)],
        profile: 'default',
      );
      expect(one.jobs.map((j) => j.id), ['d2', 'f1']);
      expect(one.updatedAtMs, _t0 + 60000);

      // A listing of every profile is the whole truth.
      final whole = LauncherWidgetCronSnapshot.merged(
        previous: one,
        connectionId: 'conn-1',
        nowMs: _t0 + 120000,
        listed: [job('d2', next: _t0 + 500)],
        profile: null,
      );
      expect(whole.jobs.map((j) => j.id), ['d2']);

      // Jobs of another connection are never carried over.
      final other = LauncherWidgetCronSnapshot.merged(
        previous: all,
        connectionId: 'conn-2',
        nowMs: _t0,
        listed: [job('x', next: _t0 + 1)],
        profile: 'default',
      );
      expect(other.connectionId, 'conn-2');
      expect(other.jobs.map((j) => j.id), ['x']);
    });
  });

  group('publishing', () {
    late _Store store;
    late int now;
    String? preferred;

    LauncherWidgetCronPublisher publisher() => LauncherWidgetCronPublisher(
      store: store,
      nowMs: () => now,
      preferredConnection: () async => preferred,
    );

    setUp(() {
      store = _Store();
      now = _t0;
      preferred = null;
    });

    LauncherWidgetCronSnapshot? stored() =>
        LauncherWidgetCronSnapshot.tryDecode(
          store.values[LauncherWidgetCronSnapshot.storageKey],
        );

    test('a listing is written once and its widget asked to redraw', () async {
      final p = publisher();
      await p.offer(
        connectionId: 'conn-1',
        jobs: [_job('a', next: _t0 ~/ 1000 + 60, status: 'ok')],
        profile: null,
      );
      expect(stored()!.jobs.single.id, 'a');
      expect(stored()!.updatedAtMs, _t0);
      expect(store.redraws, [launcherWidgetCronProvider]);
      expect(
        launcherWidgetCronProvider,
        'com.hermesagent.hermes_android.HermesCronWidgetProvider',
      );
    });

    test(
      'the same jobs are not rewritten, only re-stamped every 5 min',
      () async {
        final p = publisher();
        final jobs = [_job('a', next: _t0 ~/ 1000 + 60, status: 'ok')];
        await p.offer(connectionId: 'conn-1', jobs: jobs, profile: null);
        // The listener reads the jobs every minute: no redraw per read.
        for (var minute = 1; minute < 5; minute++) {
          now = _t0 + minute * 60000;
          await p.offer(connectionId: 'conn-1', jobs: jobs, profile: null);
        }
        expect(store.redraws, hasLength(1));
        expect(stored()!.updatedAtMs, _t0);
        // …but the widget must keep knowing its data is current.
        now = _t0 + 5 * 60000;
        await p.offer(connectionId: 'conn-1', jobs: jobs, profile: null);
        expect(store.redraws, hasLength(2));
        expect(stored()!.updatedAtMs, now);
        // A real change goes out at once.
        now += 1000;
        await p.offer(
          connectionId: 'conn-1',
          jobs: [_job('a', next: _t0 ~/ 1000 + 60, status: 'error')],
          profile: null,
        );
        expect(store.redraws, hasLength(3));
        expect(stored()!.failedCount, 1);
      },
    );

    test('the widget stays on the connection in use', () async {
      final p = publisher();
      preferred = 'conn-1';
      await p.offer(
        connectionId: 'conn-1',
        jobs: [_job('mine')],
        profile: null,
      );
      // The listener also reads the jobs of every other saved connection.
      await p.offer(
        connectionId: 'conn-2',
        jobs: [_job('other')],
        profile: null,
      );
      expect(stored()!.connectionId, 'conn-1');
      expect(stored()!.jobs.single.id, 'mine');
      // Once the owner works on the other one, it takes over.
      preferred = 'conn-2';
      now += 1000;
      await p.offer(
        connectionId: 'conn-2',
        jobs: [_job('other')],
        profile: null,
      );
      expect(stored()!.connectionId, 'conn-2');
      expect(stored()!.jobs.single.id, 'other');
    });

    test('a launcher that cannot be written never breaks the caller', () async {
      final p = publisher();
      store.failWrites = true;
      await p.offer(connectionId: 'conn-1', jobs: [_job('a')], profile: null);
      expect(stored(), isNull);
      // …and the next listing still goes through.
      store.failWrites = false;
      await p.offer(connectionId: 'conn-1', jobs: [_job('a')], profile: null);
      expect(stored()!.jobs.single.id, 'a');
    });
  });

  group('the listener\'s own cron read also feeds the widget', () {
    test('the response is passed through and its jobs offered', () async {
      final store = _Store();
      final publisher = LauncherWidgetCronPublisher(
        store: store,
        nowMs: () => _t0,
        preferredConnection: () async => null,
      );
      final calls = <String>[];
      final response = <String, dynamic>{
        'jobs': [
          {
            'id': 'a',
            'name': 'Copia de seguridad',
            'next_run_at': _t0 ~/ 1000 + 60,
            'last_status': 'error',
            'profile': 'default',
          },
          'not a job',
        ],
      };
      final tapped = launcherWidgetCronTap('conn-1', (endpoint) async {
        calls.add(endpoint);
        return response;
      }, publisher: publisher);

      final result = await tapped('cron/jobs?profile=all');
      // Exactly the call the listener made, and exactly its answer.
      expect(calls, ['cron/jobs?profile=all']);
      expect(identical(result, response), isTrue);
      await publisher.flush();
      final stored = LauncherWidgetCronSnapshot.tryDecode(
        store.values[LauncherWidgetCronSnapshot.storageKey],
      )!;
      expect(stored.jobs.single.name, 'Copia de seguridad');
      expect(stored.failedCount, 1);

      // Any other endpoint is none of the widget's business.
      store.values.clear();
      await tapped('profiles/sessions?source=cron');
      await publisher.flush();
      expect(store.values, isEmpty);
    });

    test(
      'an error of the read is the listener\'s to handle, as before',
      () async {
        final tapped = launcherWidgetCronTap(
          'conn-1',
          (endpoint) async => throw StateError('offline'),
          publisher: LauncherWidgetCronPublisher(
            store: _Store(),
            preferredConnection: () async => null,
          ),
        );
        await expectLater(tapped('cron/jobs'), throwsStateError);
      },
    );

    test('it adds no request, timer or wake-up of its own', () {
      final service = File(
        'lib/core/services/launcher_widget_cron.dart',
      ).readAsStringSync();
      for (final forbidden in [
        'Timer(',
        'Timer.periodic',
        'package:http',
        'FlutterForegroundTask',
        'Workmanager',
      ]) {
        expect(service, isNot(contains(forbidden)), reason: forbidden);
      }
      // One read in, the same read out.
      expect('apiGet(endpoint)'.allMatches(service), hasLength(1));
      final listener = File(
        'lib/core/services/notifications/background_listener.dart',
      ).readAsStringSync();
      // The only change to the listener: its existing cron read is tapped.
      expect(
        listener,
        contains(
          'executions = await BackgroundCronWatch.loadExecutions(\n'
          '          launcherWidgetCronTap(connection.id, dashboard.apiGet),\n'
          '        );',
        ),
      );
      expect('launcherWidgetCronTap'.allMatches(listener), hasLength(1));
    });
  });
}
