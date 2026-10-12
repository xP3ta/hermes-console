// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/utils/api_error.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';
import 'package:http/http.dart' as http;

import 'support/official_http_audit.dart';

void main() {
  for (final status in [400, 401, 403, 404, 500]) {
    test(
      'official HTTP $status preserves cause without body/token disclosure',
      () async {
        const canary = 'synthetic-secret-canary';
        final audit = OfficialHttpAudit();
        final client = DashboardClient(
          host: 'fixture.invalid',
          useHttps: true,
          manualToken: canary,
          httpClientOverride: audit.client((request) {
            expect(request.headers['X-Hermes-Session-Token'], canary);
            expect(request.url.path, '/api/model/info');
            expect(request.url.queryParameters['profile'], 'synthetic-owner');
            return http.Response('{"detail":"$canary"}', status);
          }),
        );
        addTearDown(client.close);
        Object? failure;
        try {
          await client.apiGet('model/info?profile=synthetic-owner');
        } catch (error) {
          failure = error;
        }
        expect(failure, isA<DashboardHttpException>());
        final error = failure! as DashboardHttpException;
        expect(error.statusCode, status);
        expect(
          error.body,
          contains(canary),
          reason: 'Failure details remain available to the owning client',
        );
        expect(error.toString(), isNot(contains(canary)));
        for (final strings in [StringsEn(), StringsEs()]) {
          final text = localizedApiError(strings, error);
          expect(text, isNot(contains(canary)));
          expect(text, isNot(contains('Mobile Bridge')));
          expect(
            text,
            isNot('HTTP $status'),
            reason: 'Localized official failure, not raw diagnostics',
          );
        }
        expect(
          audit.requests,
          List.filled(status == 401 ? 2 : 1, 'GET /api/model/info'),
          reason: 'Only the canonical same-credential 401 retry is allowed',
        );
        expect(audit.calls, isEmpty);
      },
    );
  }
  for (final failure in <Object>[
    TimeoutException('synthetic-secret-canary'),
    const SocketException('synthetic-secret-canary'),
    http.ClientException('synthetic-secret-canary'),
  ]) {
    test(
      'official transport ${failure.runtimeType} localizes without secret text',
      () {
        for (final strings in [StringsEn(), StringsEs()]) {
          expect(
            localizedApiError(strings, failure),
            isNot(contains('synthetic-secret-canary')),
          );
          expect(
            localizedApiError(strings, failure),
            isNot(contains('Mobile Bridge')),
          );
        }
      },
    );
  }
  test('HTTP audit positive control records forbidden dispatch', () async {
    final audit = OfficialHttpAudit();
    final client = audit.client((_) => http.Response('{}', 403));
    addTearDown(client.close);
    await client.get(Uri.parse('https://fixture.invalid/bridge/provision'));
    expect(audit.calls, ['GET /bridge/provision']);
  });
}
