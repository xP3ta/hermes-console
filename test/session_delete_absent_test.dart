import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A Dashboard whose snapshot says [exists]; counts the DELETEs it receives.
final class _Hermes {
  _Hermes({required this.exists});
  final bool exists;
  final deletes = <Uri>[];

  DashboardClient dashboard() => DashboardClient(
    host: '127.0.0.1',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((request) async {
      if (request.url.path == '/api/status') return http.Response('{}', 200);
      if (request.method == 'GET' &&
          request.url.path.endsWith('/mutation-snapshot')) {
        return http.Response(
          jsonEncode({
            'exists': exists,
            'runtime_revision': exists ? 3 : 0,
            'runtime_generation': exists ? 1 : null,
          }),
          200,
        );
      }
      if (request.method == 'DELETE') {
        deletes.add(request.url);
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('{}', 404);
    }),
  );
}

void main() {
  test('exists:false answers already_absent without sending DELETE', () async {
    final hermes = _Hermes(exists: false);
    final dashboard = hermes.dashboard();
    addTearDown(dashboard.close);
    final result = await deleteDashboardSession(dashboard, 'gone', null);
    expect(result['already_absent'], isTrue);
    expect(result['ok'], isTrue);
    expect(hermes.deletes, isEmpty);
  });

  test('exists:true still sends DELETE with expected_generation', () async {
    final hermes = _Hermes(exists: true);
    final dashboard = hermes.dashboard();
    addTearDown(dashboard.close);
    await deleteDashboardSession(dashboard, 's1', null);
    final query = hermes.deletes.single.queryParameters;
    expect(query['expected_revision'], '3');
    expect(query['expected_generation'], '1');
  });
}
