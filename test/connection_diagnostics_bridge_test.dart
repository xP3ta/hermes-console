import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

SavedConnection _publicConn({String? dashboardUrl}) => SavedConnection(
  id: 'public',
  label: 'public cleartext',
  host: 'gateway.example.com',
  port: 8642,
  apiKey: 'must-not-leave-the-device',
  dashboardUrl: dashboardUrl,
);

void main() {
  group('ConnectionDiagnostics transport boundary', () {
    test('bloquea dashboard HTTP público antes de tocar la red', () async {
      var hits = 0;
      final diag = ConnectionDiagnostics(
        httpClient: MockClient((_) async {
          hits++;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        diag.probeDashboard(
          _publicConn(dashboardUrl: 'http://dashboard.example.com:9119'),
          const DashboardSecrets(),
        ),
        throwsArgumentError,
      );
      expect(hits, 0);
    });
  });
}
