// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'support/official_http_audit.dart';
import 'package:http/http.dart' as http;

void main() {
  test('official Cron retains the shared identifier allowlist exactly', () {
    expect(cronJobIdPattern, r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$');
    expect(validateCronJobId('  synthetic-job_1.2  '), 'synthetic-job_1.2');
    expect(validateCronProfile(' default '), isNull);
    expect(validateCronProfile(' synthetic-owner '), 'synthetic-owner');
  });
  for (final value in [
    '../job',
    '-option',
    'job/child',
    'job?token=canary',
    '',
    List.filled(129, 'a').join(),
  ]) {
    test(
      'official Cron rejects unsafe identifier $value before dispatch',
      () async {
        final audit = OfficialHttpAudit();
        final client = DashboardClient(
          host: 'fixture.invalid',
          useHttps: true,
          manualToken: 'synthetic-canary',
          httpClientOverride: audit.client((_) => http.Response('{}', 200)),
        );
        addTearDown(client.close);
        await expectLater(
          client.deleteCronJob(value),
          throwsA(isA<ArgumentError>()),
        );
        expect(audit.requests, isEmpty);
      },
    );
  }
  test('official Cron rejects an unsafe owner before dispatch', () async {
    final audit = OfficialHttpAudit();
    final client = DashboardClient(
      host: 'fixture.invalid',
      useHttps: true,
      manualToken: 'synthetic-canary',
      httpClientOverride: audit.client((_) => http.Response('{}', 200)),
    );
    addTearDown(client.close);
    await expectLater(
      client.deleteCronJob('synthetic-job', profile: '../owner'),
      throwsA(isA<ArgumentError>()),
    );
    expect(audit.requests, isEmpty);
  });
}
