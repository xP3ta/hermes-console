import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  for (final failure in [null, 401, 404, 500, 'timeout']) {
    test('complete diagnostics official only: $failure', () async {
      final connection = SavedConnection(
        id: 'official',
        label: 'Existing',
        host: '127.0.0.1',
        port: 9131,
        apiKey: 'synthetic-key',
        dashboardAuthMode: AuthMode.sessionToken,
        dashboardUrl: 'http://127.0.0.1:19119',
      );
      const secrets = DashboardSecrets(
        sessionToken: 'synthetic-dashboard-session',
      );
      final before = connection.toMap();
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path.startsWith('/bridge/')) {
          return http.Response('{}', 404);
        }
        if (request.url.path == '/health') {
          return http.Response('{"status":"ok","version":"fixture"}', 200);
        }
        if (request.url.path == '/api/status') {
          return http.Response('{"status":"ok"}', 200);
        }
        if (request.url.port == 9131) {
          expect(request.headers['Authorization'], 'Bearer synthetic-key');
        } else {
          expect(request.url.port, 19119);
          expect(
            request.headers['X-Hermes-Session-Token'],
            'synthetic-dashboard-session',
          );
        }
        if (failure == 'timeout') throw TimeoutException('synthetic timeout');
        if (failure is int) return http.Response('{}', failure);
        if (request.url.path == '/v1/capabilities') {
          return http.Response(
            '{"object":"hermes.api_server.capabilities","features":{"runs":true},"endpoints":{}}',
            200,
          );
        }
        return http.Response('{}', 200);
      });
      final diagnostics = ConnectionDiagnostics(httpClient: client);
      addTearDown(diagnostics.close);
      final report = await http.runWithClient(
        () async => diagnostics.run(
          await Strings.delegate.load(const Locale('en')),
          connection,
          secrets,
        ),
        () => client,
      );
      expect(requests.where((r) => r.url.path.startsWith('/bridge/')), isEmpty);
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      // Two surfaces, and the copied text names no third one.
      expect(
        report.toCopyText(await Strings.delegate.load(const Locale('en'))),
        isNot(contains('bridge')),
      );
      expect(connection.toMap(), before);
      expect(secrets.sessionToken, 'synthetic-dashboard-session');
      if (failure == null) {
        expect(report.gateway.every((r) => r.status == ProbeStatus.ok), isTrue);
        expect(
          report.dashboard.every((r) => r.status == ProbeStatus.ok),
          isTrue,
        );
        expect(report.matrix.gatewayAuthValid, CapState.yes);
        expect(report.matrix.dashboardAuthValid, CapState.yes);
      } else {
        final status = failure == 401
            ? ProbeStatus.authInvalid
            : failure == 404
            ? ProbeStatus.notFound
            : failure == 'timeout'
            ? ProbeStatus.timeout
            : ProbeStatus.httpError;
        expect(
          report.gateway.firstWhere((r) => r.name == 'sessions').status,
          status,
        );
        expect(
          report.dashboard.firstWhere((r) => r.name == 'config').status,
          status,
        );
        expect(report.matrix.gatewayAuthValid, isNot(CapState.yes));
      }
    });
  }
}
