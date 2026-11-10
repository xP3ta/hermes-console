import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/test_api_client.dart';

/// qrc: Home, the session list and the drawer each own a client of the same
/// connection and all re-probe on one resume. A status probe still in flight
/// serves them all; a result is never reused.
void main() {
  test('status probes in flight for one server share the request', () async {
    var statusRequests = 0;
    final gate = Completer<void>();
    final httpClient = MockClient((request) async {
      if (request.url.path == '/api/status') {
        statusRequests += 1;
        await gate.future;
        return http.Response('{}', 200);
      }
      return http.Response('{}', 404);
    });
    final home = testApiClient(
      baseUrl: 'http://127.0.0.1:9311',
      httpClient: httpClient,
    );
    final list = testApiClient(
      baseUrl: 'http://127.0.0.1:9311',
      httpClient: httpClient,
    );
    addTearDown(home.close);
    addTearDown(list.close);

    final homeProbe = home.healthReachable();
    final listProbe = list.healthCheck();
    await Future<void>.delayed(Duration.zero);
    expect(statusRequests, 1, reason: 'the second probe rides the first');
    gate.complete();
    expect(await homeProbe, isTrue);
    expect(await listProbe, isTrue);

    expect(await home.healthReachable(), isTrue);
    expect(statusRequests, 2, reason: 'a finished probe is never reused');
  });

  test('different servers never share a probe', () async {
    final seen = <String>[];
    final gate = Completer<void>();
    final httpClient = MockClient((request) async {
      if (request.url.path == '/api/status') {
        seen.add(request.url.host);
        await gate.future;
      }
      return http.Response('{}', 200);
    });
    final a = testApiClient(
      baseUrl: 'http://127.0.0.1:9312',
      httpClient: httpClient,
    );
    final b = testApiClient(
      baseUrl: 'http://127.0.0.2:9312',
      httpClient: httpClient,
    );
    addTearDown(a.close);
    addTearDown(b.close);
    final probes = [a.healthReachable(), b.healthReachable()];
    await Future<void>.delayed(Duration.zero);
    expect(seen, ['127.0.0.1', '127.0.0.2']);
    gate.complete();
    await Future.wait(probes);
  });

  test('one gateway with two Dashboards never shares a probe', () async {
    final seen = <int>[];
    final gate = Completer<void>();
    final httpClient = MockClient((request) async {
      if (request.url.path == '/api/status') {
        seen.add(request.url.port);
        await gate.future;
        return http.Response('{}', 200);
      }
      return http.Response('{}', 404);
    });
    // Same gateway URL and key (an edited connection, or two connections
    // on one gateway), each with its own Dashboard.
    final a = testApiClient(
      baseUrl: 'http://127.0.0.1:9313',
      dashboardBaseUrl: 'http://127.0.0.1:9119',
      httpClient: httpClient,
    );
    final b = testApiClient(
      baseUrl: 'http://127.0.0.1:9313',
      dashboardBaseUrl: 'http://127.0.0.1:9120',
      httpClient: httpClient,
    );
    addTearDown(a.close);
    addTearDown(b.close);
    final probes = [a.healthReachable(), b.healthReachable()];
    await Future<void>.delayed(Duration.zero);
    expect(seen, [9119, 9120], reason: 'each Dashboard is asked itself');
    gate.complete();
    expect(await Future.wait(probes), [true, true]);
  });
}
